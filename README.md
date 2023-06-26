## Project name:
## AudioSync-player
This app delivers the audio content for a sound-walk, to be heard via the users iPhone device. The audio broadcast can be controlled remotely by a live technician via the server script. 

## Description
The AudioSync Player is a Flutter application designed to sync and play audio files across multiple devices, ensuring that all devices play the same audio segment at the same time. It uses a Python WebSocket server to coordinate the playback time and a Flutter client to play the audio.

The Python server runs on AWS and handles the audio segment updates for all connected clients. It computes the playback offset for each client based on its estimated round-trip time. The Flutter client downloads an audio file, maintains a WebSocket connection with the server, and plays the requested audio segment at the right time. New time-stamps can be sent to the clients by inputing a numerical interval to the server terminal running the script, on the format a,b , where a,b, can be any number (with up to 3 decimals), then press enter and all clients will syncronously hear the audio content from time a to time b. The server operator can also send text messages to be displayed to all clients interface by inputing a new message on the form "new message" and pressing enter.

## Installation Instructions
Python WebSocket Server
Install Python 3.8 or above. You can download it from the official website: https://www.python.org/downloads/

Clone the repository and navigate to the server directory.

Install the required Python packages using pip:

pip install websockets asyncio json threading time queue

# Flutter Client

Install Flutter SDK. You can download it from the official website: https://flutter.dev/docs/get-started/install

Clone the repository and navigate to the client directory.

Install the required Flutter packages using Flutter pub:

flutter pub get

## Usage

# Python WebSocket Server

Navigate to the server directory.

Run the server script:

python3 socketserver.py

The server is now running and waiting for clients to connect.

## Flutter Client
To run the app locally in Xcode simulator, navigate to the client directory, and do:

flutter run

The client app is now running and will attempt to connect to the server.

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

