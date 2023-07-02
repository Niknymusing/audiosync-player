## Project name:
## AudioSync-player
This app delivers the audio content for a sound-walk, to be heard via the users iPhone device. The audio broadcast can be controlled remotely by a live technician via the server script. 

## Description
The AudioSync Player is a Flutter application designed to sync and play audio files across multiple devices, ensuring that all devices play the same audio segment at the same time. It uses a Python WebSocket server to coordinate the playback time and a Flutter client to play the audio.

The Python server runs on AWS and handles the audio segment updates for all connected clients. It computes the playback offset time for each client based on its estimated round-trip time. The Flutter client app downloads an audio file to the users device, maintains a WebSocket connection with the server, and plays the requested audio segment at the right time. New time-stamps can be sent to the clients by inputing a numerical interval to the server terminal running the script, on the format a,b , where a,b, can be any number (with up to 3 decimals), then press enter and all clients will syncronously hear the audio content from time a to time b. The server operator can also send text messages to be displayed to all clients interface by inputing a new message on the form "new message" and pressing enter.

## Python WebSocket Server installation and usage instructions 

The server script can be run from e.g. an AWS EC2 instance. After setting up the server and 

<pre>
ssh -i /path/my-key-pair.pem ec2-user@my-instance-public-dns
</pre>

Clone the repository and navigate to the server directory.

Install the required Python packages using pip:

 <pre>
 cd /server/directory
 pip install websockets asyncio json threading time queue
 </pre>

Run the server script:

<pre>
 cd /server/directory
 python3 socketserver.py
</pre>


When a client connects to the server, a notification is shown in the server terminal, showing if the client has downloaded the audio file or not,
and also showing the ping latency between the connected client and the server, which is used to sync the playback time for the client:

 <pre>
Client 2 finished downloading the audio file
A new client 3 connected, waiting for client 3 to finish downloading the audio file
Received message {'message': 'Client connected'}
Received pong {'pong': 'pong'} Latency 0.16698575019836426
 </pre>

when enough clients connected and completed the download of the audio file, the server operator can send a time intervall to all clients by inputing comma-separated numerical values a,b and press enter:

<pre>
1,2
Parsed start=1.0 and end=2.0

Input start_time, end_time and press enter to update audio segment for all clients.
Or type a server message within quotes and press enter to send to all clients.

Enter input: Received ack {'ack': 'Received timestamp', 'audioDownloaded': True} Latency 0.22440719604492188
Received ack {'ack': 'Received timestamp'} Latency 3.3042361736297607
</pre>

The audiofile will then be played back on all connected clients devices, synced in time.

The server operator can also send a text message displayed to all connected clients, by inputing a messages in quotes in the server terminal and pressing enter: 

 <pre>
"server message to all connected clients"
Sending server message: server message to all connected clients
 </pre>


## Installation Instructions Flutter Client application

Flutter Client
Install Flutter SDK. You can download it from the official website: https://flutter.dev/docs/get-started/install

Clone the repository and navigate to the client directory.

Install the required Flutter packages using Flutter pub:

bash
Copy code
flutter pub get
Usage
Python WebSocket Server
Navigate to the server directory.

Run the server script:

bash
Copy code
python server.py

The server is now running and waiting for clients to connect.

Flutter Client
Navigate to the client directory.

Run the client app:

bash
Copy code
flutter run

The client app is now running and will connect to the server.

## Code Explanation

# Flutter Client
The Flutter app is organized around the HomePage widget, which maintains a WebSocketChannel connection to the server and an AudioPlayer to play the audio file.

Key methods in the HomePage widget include:

initPreferences: Initializes shared preferences and checks if the audio file has already been downloaded. If not, it starts the download.

connectToServer: Establishes a WebSocket connection to the server and sets up listeners for incoming messages.

downloadAudioFile: Downloads the audio file and saves it to local storage.

loadAudioFile: Loads the downloaded audio file into the audio player.

_playAudioFrom: Plays the audio from a given start position to an end position with a specified playback time offset.

# Python WebSocket Server
The server script uses the websockets library to handle WebSocket connections and the asyncio library to handle asynchronous tasks.

Key functions in the server script include:

send_message: Sends a message to each connected client.

handle_input: Handles user input from the console, allowing the user to enter new audio segments or server messages.

send_interval: Sends a new audio segment to each connected client.

check_intervals_queue: Checks the queue for new audio segments and sends them to the clients.

client_handler: Handles a connected client, including sending and receiving messages.
