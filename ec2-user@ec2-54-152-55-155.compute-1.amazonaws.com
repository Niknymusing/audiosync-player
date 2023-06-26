#CURRENT DEV VERSION
import asyncio
import websockets
import json
#import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 1.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}
client_counter = 0

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()

async def send_message(message):
    # Send message to each client
    for client in clients:
        await client.send(json.dumps({'message': message}))


def handle_input():
    while True:
        print("\nInput start_time, end_time and press enter to update audio segment for all clients.")
        print("Or type a server message within quotes and press enter to send to all clients.")
        
        inputs = input('\nEnter input: ')
        
        if inputs.startswith('"') and inputs.endswith('"'):
            # Input is a server message
            message = inputs[1:-1]  # strip off the quotes
            if len(message) > 80:
                print("Message is too long. It should be maximum 80 characters including spaces.")
            else:
                print(f"Sending server message: {message}")
                asyncio.run(send_message(message))
        else:
            # Input is a pair of timestamps
            try:
                inputs = inputs.split(',')
                if len(inputs) != 2:
                    raise ValueError("Inputs length is not 2.")
                
                # Check if the inputs can be converted to float before actually converting
                start, end = float(inputs[0]), float(inputs[1])
                
                print(f"Parsed start={start} and end={end}")
                intervals_queue.put((start, end))
            
            except ValueError as e:
                print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        send_time = time.time()
        clients[client]['send_time'] = send_time
        playbackTimeOffset = max(0, MaxTime - clients[client]['latency'])
        await client.send(json.dumps({'start': start, 'end': end, 'playbackTimeOffset': playbackTimeOffset}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    global client_counter
    client_counter += 1
    client_id = client_counter  # assign a unique id to the client
    
    # If all other clients have downloaded the file, print a message
    if all(client['downloaded'] for client in clients.values()):
        print(f"A new client {client_id} connected, waiting for client {client_id} to finish downloading the audio file")
    else:
        print(f'Client {client_id} connected')

    clients[websocket] = {'latency': 0, 'send_time': time.time(), 'id': client_id, 'downloaded': False}

    # send a ping message immediately after a client connects
    send_time = time.time()
    clients[websocket]['send_time'] = send_time
    await websocket.send(json.dumps({'ping': 'ping'}))

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'pong' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received pong', data, 'Latency', latency)
            elif 'ack' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received ack', data, 'Latency', latency)
            elif 'downloadAck' in data and websocket in clients:
                clients[websocket]['downloaded'] = True
                print(f"Client {clients[websocket]['id']} finished downloading the audio file")
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]

start_server = websockets.serve(client_handler, "0.0.0.0", 5009)

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()

"""""
#PREV (WORKING) DEV VERSION
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 1.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}
client_counter = 0

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            intervals_queue.put((start, end))
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        send_time = time.time()
        clients[client]['send_time'] = send_time
        playbackTimeOffset = max(0, MaxTime - clients[client]['latency'])
        await client.send(json.dumps({'start': start, 'end': end, 'playbackTimeOffset': playbackTimeOffset}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    global client_counter
    client_counter += 1
    client_id = client_counter  # assign a unique id to the client
    
    # If all other clients have downloaded the file, print a message
    if all(client['downloaded'] for client in clients.values()):
        print(f"A new client {client_id} connected, waiting for client {client_id} to finish downloading the audio file")
    else:
        print(f'Client {client_id} connected')

    clients[websocket] = {'latency': 0, 'send_time': time.time(), 'id': client_id, 'downloaded': False}

    # send a ping message immediately after a client connects
    send_time = time.time()
    clients[websocket]['send_time'] = send_time
    await websocket.send(json.dumps({'ping': 'ping'}))

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'pong' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received pong', data, 'Latency', latency)
            elif 'ack' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received ack', data, 'Latency', latency)
            elif 'downloadAck' in data and websocket in clients:
                clients[websocket]['downloaded'] = True
                print(f"Client {clients[websocket]['id']} finished downloading the audio file")
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]

start_server = websockets.serve(client_handler, "0.0.0.0", 5009)

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()
"""""

"""""
#PREV DEV VERSION:
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 1.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            intervals_queue.put((start, end))
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        send_time = time.time()
        clients[client]['send_time'] = send_time
        playbackTimeOffset = max(0, MaxTime - clients[client]['latency'])
        await client.send(json.dumps({'start': start, 'end': end, 'playbackTimeOffset': playbackTimeOffset}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    print('Client connected')
    clients[websocket] = {'latency': 0, 'send_time': time.time()}

    # send a ping message immediately after a client connects
    send_time = time.time()
    clients[websocket]['send_time'] = send_time
    await websocket.send(json.dumps({'ping': 'ping'}))

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'pong' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received pong', data, 'Latency', latency)
            elif 'ack' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received ack', data, 'Latency', latency)
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]



start_server = websockets.serve(client_handler, "0.0.0.0", 5009)

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()
"""""

"""""
#THIS VERSION WORKS DECENTLY
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 1.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            intervals_queue.put((start, end))
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        send_time = time.time()
        clients[client]['send_time'] = send_time
        playbackTimeOffset = MaxTime - clients[client]['latency']
        await client.send(json.dumps({'start': start, 'end': end, 'playbackTimeOffset': playbackTimeOffset}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    print('Client connected')
    clients[websocket] = {'latency': 0, 'send_time': time.time()}

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'ack' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received ack', data, 'Latency', latency)
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]


start_server = websockets.serve(client_handler, "0.0.0.0", 5009)

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()
"""

"""""
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 2.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()
PingPongRounds = 5

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            intervals_queue.put((start, end))
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        if 'ping_count' in clients[client] and clients[client]['ping_count'] < PingPongRounds:
            clients[client]['ping_count'] += 1
            clients[client]['ping_sent'] = time.time()
            await client.send(json.dumps({"ping": clients[client]['ping_sent']}))
        else:
            send_time = time.time()
            clients[client]['send_time'] = send_time
            latency = sum(clients[client].get('latencies', [])) / len(clients[client].get('latencies', [1]))
            playbackTimeOffset = MaxTime - latency/2
            await client.send(json.dumps({'start': start, 'end': end, 'playbackTimeOffset': playbackTimeOffset}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    print('Client connected')
    clients[websocket] = {'latencies': [], 'send_time': time.time(), 'ping_count': 0}

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'pong' in data and websocket in clients:
                send_time = clients[websocket]['ping_sent']
                receive_time = time.time()
                latency = receive_time - send_time
                clients[websocket]['latencies'].append(latency)
                print('Received pong', data, 'Latency', latency)
            elif 'ack' in data and websocket in clients:
                print('Received ack', data)
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]


start_server = websockets.serve(client_handler, "0.0.0.0", 5009) #10.0.0.16

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()
"""""

"""""
#THIS VERSION WORKS DECENTLY::
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 15.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()
PingPongRounds = 5

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            intervals_queue.put((start, end))
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        if 'ping_count' in clients[client] and clients[client]['ping_count'] < PingPongRounds:
            clients[client]['ping_count'] += 1
            clients[client]['ping_sent'] = time.time()
            await client.send(json.dumps({"ping": clients[client]['ping_sent']}))
        else:
            send_time = time.time()
            clients[client]['send_time'] = send_time
            latency = sum(clients[client]['latencies']) / len(clients[client]['latencies'])
            playbackTimeOffset = MaxTime - latency/2
            await client.send(json.dumps({'start': start, 'end': end, 'playbackTimeOffset': playbackTimeOffset}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    print('Client connected')
    clients[websocket] = {'latency': 0, 'send_time': time.time()}

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'pong' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                receive_time = time.time()
                latency = receive_time - send_time
                clients[websocket]['latency'] = latency
                print('Received pong', data, 'Latency', latency)
            elif 'ack' in data and websocket in clients:
                print('Received ack', data)
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]


start_server = websockets.serve(client_handler, "0.0.0.0", 5009)

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()
"""




"""""
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time
import queue

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100
MaxTime = 5.0  # Maximum time offset

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}

# Create a Queue for communication between the input thread and main event loop
intervals_queue = queue.Queue()

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            intervals_queue.put((start, end))
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        send_time = time.time()
        clients[client]['send_time'] = send_time
        await client.send(json.dumps({'start': start, 'end': end}))

async def check_intervals_queue():
    while True:
        # check the queue for new intervals
        while not intervals_queue.empty():
            start, end = intervals_queue.get()
            await send_interval(start, end)
        await asyncio.sleep(1)  # pause for a second before checking again

async def client_handler(websocket, path):
    print('Client connected')
    clients[websocket] = {'latency': 0, 'send_time': time.time()}

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'ack' in data and websocket in clients:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received ack', data, 'Latency', latency)
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]


start_server = websockets.serve(client_handler, "0.0.0.0", 5009)

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

loop = asyncio.get_event_loop()
loop.run_until_complete(asyncio.gather(start_server, check_intervals_queue()))
loop.run_forever()
"""



"""""
import asyncio
import websockets
import json
import soundfile as sf
import threading
import time

# Audio settings
audio_file = 'Soundwalk version 4 (1).wav'
sample_rate = 44100

# Load audio file
audio_data, _ = sf.read(audio_file)

# Clients and their associated latency data
clients = {}

def handle_input():
    while True:
        print("Input start_time, end_time and press enter to update audio segment for all clients:")
        try:
            inputs = input('Enter start and end timestamp separated by comma, and press enter to send timestamp to all clients: ').split(',')
            if len(inputs) != 2:
                raise ValueError("Inputs length is not 2.")
            
            # Check if the inputs can be converted to float before actually converting
            start, end = float(inputs[0]), float(inputs[1])
            
            print(f"Parsed start={start} and end={end}")
            asyncio.run_coroutine_threadsafe(send_interval(start, end), asyncio.get_event_loop())
            
        except ValueError as e:
            print(f"Invalid input. Please enter two numbers (integer or float) separated by a space. Error: {e}")

async def send_interval(start, end):
    # Send interval to each client
    for client in clients:
        send_time = time.time()
        clients[client]['send_time'] = send_time
        await client.send(json.dumps({'start': start, 'end': end}))
        print(f"Sent timestamps to client at {send_time}")  # Debug message

async def client_handler(websocket, path):
    print('Client connected')
    clients[websocket] = {'latency': 0, 'send_time': time.time()}

    try:
        async for message in websocket:
            data = json.loads(message)
            if 'ack' in data:
                send_time = clients[websocket]['send_time']
                latency = time.time() - send_time
                clients[websocket]['latency'] = latency
                print('Received ack', data, 'Latency', latency)
            else:
                print('Received message', data)
    except websockets.ConnectionClosed:
        print('Client disconnected')
    finally:
        if websocket in clients:
            del clients[websocket]

start_server = websockets.serve(client_handler, "0.0.0.0", 5009)  # Changed port to 5009

input_thread = threading.Thread(target=handle_input)
input_thread.daemon = True
input_thread.start()

asyncio.get_event_loop().run_until_complete(start_server)
asyncio.get_event_loop().run_forever()
"""