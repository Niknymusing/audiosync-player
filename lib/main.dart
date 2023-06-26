import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

enum AudioState {
  waiting,
  syncing,
  playing,
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;
  AudioState _audioState = AudioState.waiting;
  String _serverMessage = '';
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance!.addObserver(this);
    initPreferences();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // This will be called when the app is resumed (brought to the foreground)
      // after being in the background.
      connectToServer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance!.removeObserver(this);
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }


  void initPreferences() async {
      _prefs = await SharedPreferences.getInstance();
      _filePath = _prefs?.getString('filePath') ?? '';
      _isDownloaded = _filePath.isNotEmpty;

      if (!_isDownloaded) {
        downloadAudioFile();
      } else {
        print("File already downloaded and saved at $_filePath");
        loadAudioFile();
      }
      connectToServer();

      // Sending `ack` message each time the app is opened
      if (channel != null && channel!.sink != null) {
        channel!.sink.add(jsonEncode({
          'message': 'Client connected',
          'audioDownloaded': _isDownloaded,
        }));
      }
  }

  void connectToServer() {
    try {
      String url = 'ws://54.204.67.173:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
          print('Received message: $message');
          Map<String, dynamic> audioData = json.decode(message);

          if (audioData.containsKey('ping')) {
            channel!.sink.add(jsonEncode({'pong': 'pong'}));
            print('Sent pong to the server');
          } else if (audioData.containsKey('start') && audioData.containsKey('end') && audioData.containsKey('playbackTimeOffset')) {
            print('Decoded message: $audioData');
            double playbackTimeOffset = audioData['playbackTimeOffset'].toDouble();
            _playAudioFrom(audioData['start'], audioData['end'], playbackTimeOffset);

            // Adding `audioDownloaded` state to the `ack` message
            channel!.sink.add(jsonEncode({'ack': 'Received timestamp', 'audioDownloaded': _isDownloaded}));
            print('Sent acknowledgment to the server');
          } else if (audioData.containsKey('message')) {
            setState(() {
              _serverMessage = audioData['message'];
            });
            print('Received server message: $_serverMessage');
          }
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';

    try {
      await dio.download('https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav', filePath);

      _prefs?.setString('filePath', filePath);

      setState(() {
        _filePath = filePath;
        _isDownloading = false;
        _isDownloaded = true;
        print("File downloaded and saved at $_filePath");

        channel!.sink.add(jsonEncode({'downloadAck': 'Download complete'}));

        loadAudioFile();
      });
    } catch (e) {
      print("Error downloading file: $e");
      setState(() {
        _isDownloading = false;
      });
    }
  }

  Future<void> loadAudioFile() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      print("Audio file loaded into the audio player");
    } catch (e) {
      print("Failed to load the audio file into the audio player: $e");

      setState(() {
        _isDownloaded = false;
        _filePath = '';
      });
    }
  }

  void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
    if (_isDownloaded) {
      final startPos = Duration(milliseconds: (start * 1000).toInt());
      final endPos = Duration(milliseconds: (end * 1000).toInt());
      var offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

      if (startPos == endPos && offset == Duration.zero) {
        setState(() {
          _audioState = AudioState.waiting;
        });
        return;
      }

      if (offset < Duration.zero) {
        print("Received negative playbackTimeOffset, defaulting to zero");
        offset = Duration.zero;
      }

      setState(() {
        _audioState = AudioState.syncing;
      });

      if (offset == Duration.zero) {
        _playAudio(startPos, endPos);
      } else {
        await Future.delayed(offset, () => _playAudio(startPos, endPos));
      }
    }
  }

  void _playAudio(Duration startPos, Duration endPos) async {
    try {
      await audioPlayer.setClip(start: startPos, end: endPos);

      setState(() {
        _audioState = AudioState.playing;
      });

      await audioPlayer.play();
      print("Audio played from $startPos to $endPos");
    } catch (e) {
      print("Error playing audio: $e");
    }

    channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
  }

  @override
  Widget build(BuildContext context) {
    String message = '';

    switch (_audioState) {
      case AudioState.waiting:
        message = 'Waiting for audio';
        break;
      case AudioState.syncing:
        message = 'Audio message received, wait while syncing...';
        break;
      case AudioState.playing:
        message = 'Audio is playing now';
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(message),
            SizedBox(height: 10),
            Text(_serverMessage),
          ],
        ),
      ),
    );
  }
}

/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

enum AudioState {
  waiting,
  syncing,
  playing,
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;
  AudioState _audioState = AudioState.waiting;
  String _serverMessage = '';

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        setState(() {
          _audioState = AudioState.waiting;
        });
      }
    });

    try {
      String url = 'ws://54.204.67.173:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);

        if (audioData.containsKey('ping')) {
          channel!.sink.add(jsonEncode({'pong': 'pong'}));
          print('Sent pong to the server');
        } else if (audioData.containsKey('start') && audioData.containsKey('end') && audioData.containsKey('playbackTimeOffset')) {
          print('Decoded message: $audioData');
          double playbackTimeOffset = audioData['playbackTimeOffset'].toDouble();
          _playAudioFrom(audioData['start'], audioData['end'], playbackTimeOffset);

          channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
          print('Sent acknowledgment to the server');
        } else if (audioData.containsKey('message')) {
          setState(() {
            _serverMessage = audioData['message'];
          });
          print('Received server message: $_serverMessage');
        }
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';

    try {
      await dio.download('https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav', filePath);

      setState(() {
        _filePath = filePath;
        _isDownloading = false;
        _isDownloaded = true;
        print("File downloaded and saved at $_filePath");

        channel!.sink.add(jsonEncode({'downloadAck': 'Download complete'}));

        loadAudioFile();
      });
    } catch (e) {
      print("Error downloading file: $e");
      setState(() {
        _isDownloading = false;
      });
    }
  }

  Future<void> loadAudioFile() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      print("Audio file loaded into the audio player");
    } catch (e) {
      print("Failed to load the audio file into the audio player: $e");

      setState(() {
        _isDownloaded = false;
        _filePath = '';
      });
    }
  }

  void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
    if (_isDownloaded) {
      final startPos = Duration(milliseconds: (start * 1000).toInt());
      final endPos = Duration(milliseconds: (end * 1000).toInt());
      var offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

      if (startPos == endPos && offset == Duration.zero) {
        setState(() {
          _audioState = AudioState.waiting;
        });
        return;
      }

      if (offset < Duration.zero) {
        print("Received negative playbackTimeOffset, defaulting to zero");
        offset = Duration.zero;
      }

      setState(() {
        _audioState = AudioState.syncing;
      });

      if (offset == Duration.zero) {
        _playAudio(startPos, endPos);
      } else {
        await Future.delayed(offset, () => _playAudio(startPos, endPos));
      }
    }
  }

  void _playAudio(Duration startPos, Duration endPos) async {
    try {
      await audioPlayer.setClip(start: startPos, end: endPos);

      setState(() {
        _audioState = AudioState.playing;
      });

      await audioPlayer.play();
      print("Audio played from $startPos to $endPos");
    } catch (e) {
      print("Error playing audio: $e");
    }

    channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String message = '';

    switch (_audioState) {
      case AudioState.waiting:
        message = 'Waiting for audio';
        break;
      case AudioState.syncing:
        message = 'Audio message received, wait while syncing...';
        break;
      case AudioState.playing:
        message = 'Audio is playing now';
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(message),
            SizedBox(height: 10),
            Text(_serverMessage),
          ],
        ),
      ),
    );
  }
}
*/


/*
//PREV (WORKING) DEV VERSION
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

enum AudioState {
  waiting,
  syncing,
  playing,
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;
  AudioState _audioState = AudioState.waiting;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    // Add event listener for audioPlayer
    audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        setState(() {
          _audioState = AudioState.waiting;
        });
      }
    });

    try {
      String url = 'ws://10.0.0.16:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);

        if (audioData.containsKey('ping')) {
        // Respond with a pong message upon receiving ping
            channel!.sink.add(jsonEncode({'pong': 'pong'}));
            print('Sent pong to the server');
        } else if (audioData.containsKey('start') && audioData.containsKey('end') && audioData.containsKey('playbackTimeOffset')) {
              print('Decoded message: $audioData');
              double playbackTimeOffset = audioData['playbackTimeOffset'].toDouble();
              _playAudioFrom(audioData['start'], audioData['end'], playbackTimeOffset);

              // Acknowledge the receipt of the message
              channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
              print('Sent acknowledgment to the server');
          }
      });

    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    try {
        await dio.download(
            'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
            filePath);

        setState(() {
          _filePath = filePath;
          _isDownloading = false;
          _isDownloaded = true;
          print("File downloaded and saved at $_filePath");
          // Send a download acknowledgement to the server
          channel!.sink.add(jsonEncode({'downloadAck': 'Download complete'}));

          // Try loading the audio file into the audio player
          loadAudioFile();
        });
    } catch (e) {
        print("Error downloading file: $e");
        setState(() {
          _isDownloading = false;
          
        });
    }
}


  Future<void> loadAudioFile() async {
    try {
        await audioPlayer.setFilePath(_filePath);
        print("Audio file loaded into the audio player");
    } catch (e) {
        print("Failed to load the audio file into the audio player: $e");
        // Handle error, possibly by updating state and notifying user
        setState(() {
            _isDownloaded = false;
            _filePath = '';
        });
    }
}


void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
    if (_isDownloaded) {
        final startPos = Duration(milliseconds: (start * 1000).toInt());
        final endPos = Duration(milliseconds: (end * 1000).toInt());
        var offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

        // Handle the case when there's no actual audio to play
        if (startPos == endPos && offset == Duration.zero) {
            setState(() {
                _audioState = AudioState.waiting;
            });
            return;
        }

        // Handle negative playbackTimeOffset
        if (offset < Duration.zero) {
            print("Received negative playbackTimeOffset, defaulting to zero");
            offset = Duration.zero;
        }

        // Set the state to syncing and refresh the UI
        setState(() {
            _audioState = AudioState.syncing;
        });

        if (offset == Duration.zero) {
            // If offset is zero, immediately switch state to playing and play the audio
            _playAudio(startPos, endPos);
        } else {
            // If offset is not zero, wait for the offset time before playing
            await Future.delayed(offset, () => _playAudio(startPos, endPos));
        }
    }
}


void _playAudio(Duration startPos, Duration endPos) async {
    try {
        await audioPlayer.setClip(start: startPos, end: endPos);
        // Update state before play() is called
        setState(() {
            _audioState = AudioState.playing;
        });
        await audioPlayer.play();
        print("Audio played from $startPos to $endPos");
    } catch (e) {
        print("Error playing audio: $e");
    }

    // Send ack message to the server
    channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
}




  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
    // Cancel the subscription
    
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String message = '';
    switch (_audioState) {
      case AudioState.waiting:
        message = 'Waiting for audio';
        break;
      case AudioState.syncing:
        message = 'Audio message received, wait while syncing...';
        break;
      case AudioState.playing:
        message = 'Audio is playing now';
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: Text(message),
      ),
    );
  }
}
*/
/*
//PREV DEV VERSION
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

enum AudioState {
  waiting,
  syncing,
  playing,
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;
  AudioState _audioState = AudioState.waiting;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    // Add event listener for audioPlayer
    audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        setState(() {
          _audioState = AudioState.waiting;
        });
      }
    });

    try {
      String url = 'ws://10.0.0.16:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);

        if (audioData.containsKey('ping')) {
        // Respond with a pong message upon receiving ping
            channel!.sink.add(jsonEncode({'pong': 'pong'}));
            print('Sent pong to the server');
        } else if (audioData.containsKey('start') && audioData.containsKey('end') && audioData.containsKey('playbackTimeOffset')) {
              print('Decoded message: $audioData');
              double playbackTimeOffset = audioData['playbackTimeOffset'].toDouble();
              _playAudioFrom(audioData['start'], audioData['end'], playbackTimeOffset);

              // Acknowledge the receipt of the message
              channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
              print('Sent acknowledgment to the server');
          }
      });

    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    try {
        await dio.download(
            'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
            filePath);

        setState(() {
          _filePath = filePath;
          _isDownloading = false;
          _isDownloaded = true;
          print("File downloaded and saved at $_filePath");

          // Try loading the audio file into the audio player
          loadAudioFile();
        });
    } catch (e) {
        print("Error downloading file: $e");
        setState(() {
          _isDownloading = false;
          
        });
    }
}


  Future<void> loadAudioFile() async {
    try {
        await audioPlayer.setFilePath(_filePath);
        print("Audio file loaded into the audio player");
    } catch (e) {
        print("Failed to load the audio file into the audio player: $e");
        // Handle error, possibly by updating state and notifying user
        setState(() {
            _isDownloaded = false;
            _filePath = '';
        });
    }
}


void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
    if (_isDownloaded) {
        final startPos = Duration(milliseconds: (start * 1000).toInt());
        final endPos = Duration(milliseconds: (end * 1000).toInt());
        var offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

        // Handle the case when there's no actual audio to play
        if (startPos == endPos && offset == Duration.zero) {
            setState(() {
                _audioState = AudioState.waiting;
            });
            return;
        }

        // Handle negative playbackTimeOffset
        if (offset < Duration.zero) {
            print("Received negative playbackTimeOffset, defaulting to zero");
            offset = Duration.zero;
        }

        // Set the state to syncing and refresh the UI
        setState(() {
            _audioState = AudioState.syncing;
        });

        if (offset == Duration.zero) {
            // If offset is zero, immediately switch state to playing and play the audio
            _playAudio(startPos, endPos);
        } else {
            // If offset is not zero, wait for the offset time before playing
            await Future.delayed(offset, () => _playAudio(startPos, endPos));
        }
    }
}


void _playAudio(Duration startPos, Duration endPos) async {
    try {
        await audioPlayer.setClip(start: startPos, end: endPos);
        // Update state before play() is called
        setState(() {
            _audioState = AudioState.playing;
        });
        await audioPlayer.play();
        print("Audio played from $startPos to $endPos");
    } catch (e) {
        print("Error playing audio: $e");
    }

    // Send ack message to the server
    channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
}




  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
    // Cancel the subscription
    
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String message = '';
    switch (_audioState) {
      case AudioState.waiting:
        message = 'Waiting for audio';
        break;
      case AudioState.syncing:
        message = 'Audio message received, wait while syncing...';
        break;
      case AudioState.playing:
        message = 'Audio is playing now';
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: Text(message),
      ),
    );
  }
}
*/
/*
// THIS VERSION WORKS DECENTLY
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://10.0.0.16:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);
        print('Decoded message: $audioData');
        _playAudioFrom(audioData['start'], audioData['end'], audioData['playbackTimeOffset']);

        // Acknowledge the receipt of the message
        channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
        print('Sent acknowledgment to the server');
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
      print("File downloaded and saved at $_filePath");

      // Try loading the audio file into the audio player
      loadAudioFile();
    });
  }

  Future<void> loadAudioFile() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      print("Audio file loaded into the audio player");
    } catch (e) {
      print("Failed to load the audio file into the audio player: $e");
    }
  }

void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
  if (_isDownloaded) {
    final startPos = Duration(milliseconds: (start * 1000).toInt());
    final endPos = Duration(milliseconds: (end * 1000).toInt());
    final offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

    // Wait for the offset time before starting playback
    await Future.delayed(offset, () async {
      await audioPlayer.setClip(start: startPos, end: endPos);
      await audioPlayer.play();
      print("Audio played from $startPos to $endPos with offset $playbackTimeOffset");

      // Send ack message to the server
      channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
    });
  }
}


  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? Text('Downloading audio file.')
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/

/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AudioPlayer? _audioPlayer;
  late WebSocketChannel _channel;
  String _audioFilePath = '';
  String _fileUrl = 'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  
  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _downloadAudioFile();
    _connectToWebSocket();
  }

  Future<void> _downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';

    try {
      await dio.download(_fileUrl, filePath);
      setState(() {
        _audioFilePath = filePath;
        _isDownloading = false;
        _isDownloaded = true;
        print('File downloaded and saved at $_audioFilePath');
      });
    } catch (e) {
      print('Error downloading file: $e');
      setState(() {
        _isDownloading = false;
      });
    }
  }

  void _connectToWebSocket() {
    try {
      _channel = IOWebSocketChannel.connect('ws://10.0.0.16:5009');
      _channel.stream.listen(
        (event) {
          final Map<String, dynamic> data = json.decode(event);
          _handleWebSocketData(data);
        },
        onError: _handleError,
      );
      _channel.sink.add(json.encode({'ping': DateTime.now().millisecondsSinceEpoch}));
    } catch (e) {
      print('Cannot establish connection: $e');
    }
  }

  void _handleWebSocketData(Map<String, dynamic> data) {
    if (data.containsKey('start') && data.containsKey('end')) {
      final double start = data['start'];
      final double end = data['end'];
      _playSegment(start, end);
    }
    if (data.containsKey('pong')) {
      final int timestamp = data['pong'];
      final int latency = DateTime.now().millisecondsSinceEpoch - timestamp;
      print('Latency: $latency ms');
    }
  }

  void _handleError(Object error) {
    print('WebSocket encountered an error: $error');
  }

  void _playSegment(double start, double end) async {
    if (_isDownloaded && _audioPlayer != null) {
      await _audioPlayer!.setFilePath(_audioFilePath);
      await _audioPlayer!.setClip(
        start: Duration(milliseconds: (start * 1000).toInt()),
        end: Duration(milliseconds: (end * 1000).toInt()),
      );
      await _audioPlayer!.play();
    }
  }

  @override
  void dispose() {
    _audioPlayer?.dispose();
    _channel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/

/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://10.0.0.16:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a ping to the server upon connection
      channel!.sink.add(jsonEncode({'ping': DateTime.now().millisecondsSinceEpoch}));

      channel!.stream.listen((message) {
        Map<String, dynamic> audioData = json.decode(message);

        if (audioData.containsKey('ping')) {
          final pingSent = audioData['ping'];
          final pongReceived = DateTime.now().millisecondsSinceEpoch;
          final latency = pongReceived - pingSent;
          print('Ping-Pong Latency: $latency ms');
          // Send pong message back to the server
          channel!.sink.add(jsonEncode({'pong': pongReceived}));
        } else if (audioData.containsKey('start') && audioData.containsKey('end') && audioData.containsKey('playbackTimeOffset')) {
          print('Decoded message: $audioData');
          double start = audioData['start'];
          double end = audioData['end'];
          double playbackTimeOffset = audioData['playbackTimeOffset'];
          _playAudioFrom(start, end, playbackTimeOffset);

          // Acknowledge the receipt of the message
          channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
          print('Sent acknowledgment to the server');
        } else {
          print('Unexpected message received: $audioData');
        }
      });

    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
      print("File downloaded and saved at $_filePath");

      // Try loading the audio file into the audio player
      loadAudioFile();
    });
  }

  Future<void> loadAudioFile() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      print("Audio file loaded into the audio player");
    } catch (e) {
      print("Failed to load the audio file into the audio player: $e");
    }
  }

  void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
    if (_isDownloaded) {
      final startPos = Duration(milliseconds: (start * 1000).toInt());
      final endPos = Duration(milliseconds: (end * 1000).toInt());
      final offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

      // Wait for the offset time before starting playback
      await Future.delayed(offset, () async {
        await audioPlayer.setClip(start: startPos, end: endPos);
        await audioPlayer.play();
        print("Audio played from $startPos to $endPos with offset $playbackTimeOffset");

        // Send ack message to the server
        channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
      });
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? Text('Downloading audio file.')
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/

/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://192.168.1.100:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a ping message to the server upon connection
      channel!.sink.add(jsonEncode({'ping': DateTime.now().millisecondsSinceEpoch}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);

        if (audioData.containsKey('pong')) {
          final pingSent = audioData['ping'];
          final pongReceived = DateTime.now().millisecondsSinceEpoch;
          final latency = pongReceived - pingSent;
          print('Ping-Pong Latency: $latency ms');
          // Send another ping
          channel!.sink.add(jsonEncode({'ping': DateTime.now().millisecondsSinceEpoch}));
        } else {
          print('Decoded message: $audioData');
          _playAudioFrom(audioData['start'], audioData['end'], audioData['playbackTimeOffset']);

          // Acknowledge the receipt of the message
          channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
          print('Sent acknowledgment to the server');
        }
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
      print("File downloaded and saved at $_filePath");

      // Try loading the audio file into the audio player
      loadAudioFile();
    });
  }

  Future<void> loadAudioFile() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      print("Audio file loaded into the audio player");
    } catch (e) {
      print("Failed to load the audio file into the audio player: $e");
    }
  }

  void _playAudioFrom(double start, double end, double playbackTimeOffset) async {
    if (_isDownloaded) {
      final startPos = Duration(milliseconds: (start * 1000).toInt());
      final endPos = Duration(milliseconds: (end * 1000).toInt());
      final offset = Duration(milliseconds: (playbackTimeOffset * 1000).toInt());

      // Wait for the offset time before starting playback
      await Future.delayed(offset, () async {
        await audioPlayer.setClip(start: startPos, end: endPos);
        await audioPlayer.play();
        print("Audio played from $startPos to $endPos with offset $playbackTimeOffset");

        // Send ack message to the server
        channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
      });
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/





/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://192.168.1.100:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);
        print('Decoded message: $audioData');
        _playAudioFrom(audioData['start'], audioData['end']);

        // Acknowledge the receipt of the message
        channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
        print('Sent acknowledgment to the server');
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
      print("File downloaded and saved at $_filePath");

      // Try loading the audio file into the audio player
      loadAudioFile();
    });
  }

  Future<void> loadAudioFile() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      print("Audio file loaded into the audio player");
    } catch (e) {
      print("Failed to load the audio file into the audio player: $e");
    }
  }

void _playAudioFrom(double start, double end) async {
    if (_isDownloaded) {
      final startPos = Duration(milliseconds: (start * 1000).toInt());
      final endPos = Duration(milliseconds: (end * 1000).toInt());
      await audioPlayer.setClip(start: startPos, end: endPos);
      await audioPlayer.play();
      print("Audio played from $start to $end");

      // Send ack message to the server
      channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
    }
  }


  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? Text('Downloading audio file.')
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }

}
*/


/*
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    try {
      String url = 'wss://192.168.1.100:5013/websocket/'; // replace with your server's IP and port
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  @override
  void dispose() {
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WebSocket Client'),
      ),
      body: Center(
        child: Text('See console for logs'),
      ),
    );
  }
}
*/


/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://192.168.1.100:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print('Received message: $message');
        Map<String, dynamic> audioData = json.decode(message);
        print('Decoded message: $audioData');
        _playAudioFrom(audioData['start'], audioData['end']);

        // Acknowledge the receipt of the message
        channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
        print('Sent acknowledgment to the server');
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
      print("File downloaded and saved at $_filePath");
    });
  }

  void _playAudioFrom(double start, double end) async {
    if (_isDownloaded) {
      final startPos = Duration(milliseconds: (start * 1000).toInt());
      final endPos = Duration(milliseconds: (end * 1000).toInt());
      await audioPlayer.setClip(start: startPos, end: endPos);
      await audioPlayer.play();

      // Send ack message to the server
      channel!.sink.add(jsonEncode({'ack': 'Received timestamp'}));
    }
  }


  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/


/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://192.168.1.100:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        try {
          print("Listening to the WebSocket stream...");
          print("Received raw message: $message"); // Debug print

          Map<String, dynamic> timestamps = jsonDecode(message);
          print("Decoded message: $timestamps");

          if(timestamps.containsKey('start') && timestamps.containsKey('end')) {
            print("Received interval message: start ${timestamps['start']}, end ${timestamps['end']}"); // New print statement
            _parseMessage(timestamps);
          } else {
            print("The message received from the server doesn't contain 'start' and 'end' fields.");
          }
          
          // Acknowledge the received message
          channel!.sink.add(jsonEncode({'ack': 'OK'}));
        } catch (e) {
          print("Error listening to WebSocket stream: $e");
        }
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
      print("File downloaded and saved at $_filePath");
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    if (message.containsKey('start') && message.containsKey('end')) {
      final start = (message['start'] as num).toDouble() * 1000;
      final end = (message['end'] as num).toDouble() * 1000;

      if (_isDownloaded) {
        print("Attempting audio playback from $start ms to $end ms"); // Debug print
        audioPlayer.setFilePath(_filePath, preload: true);
        audioPlayer.seek(Duration(milliseconds: start.toInt()));
        audioPlayer.setClip(
          start: Duration(milliseconds: start.toInt()),
          end: Duration(milliseconds: end.toInt()),
        );
        audioPlayer.play();
        print("Audio playback started");
      }
    } else if (message.containsKey('ack')) {
      final latency = message['ack'] as double;
      // Calculate the latency offset or perform any necessary action
      print('Received ack with latency: $latency');
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/


/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://192.168.1.100:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        try {
          print("Listening to the WebSocket stream...");
          print("Received new timestamps: $message"); // Debug print
          Map<String, dynamic> timestamps = jsonDecode(message);
          print("Received interval message: start ${timestamps['start']}, end ${timestamps['end']}"); // New print statement
          _parseMessage(timestamps);
          // Acknowledge the received message
          channel!.sink.add(jsonEncode({'ack': 'OK'}));
        } catch (e) {
          print("Error listening to WebSocket stream: $e");
        }
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    if (message.containsKey('start') && message.containsKey('end')) {
      final start = (message['start'] as num).toDouble() * 1000;
      final end = (message['end'] as num).toDouble() * 1000;

      if (_isDownloaded) {
        print("Attempting audio playback from $start ms to $end ms"); // Debug print
        audioPlayer.setFilePath(_filePath, preload: true);
        audioPlayer.seek(Duration(milliseconds: start.toInt()));
        audioPlayer.setClip(
          start: Duration(milliseconds: start.toInt()),
          end: Duration(milliseconds: end.toInt()),
        );
        audioPlayer.play();
      }
    } else if (message.containsKey('ack')) {
      final latency = message['ack'] as double;
      // Calculate the latency offset or perform any necessary action
      print('Received ack with latency: $latency');
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/


/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://192.168.1.100:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send a message to the server upon connection
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));
      

      channel!.stream.listen((message) {
        print("Listening to the WebSocket stream...");
        print("Received new timestamps: $message"); // Debug print
        Map<String, dynamic> timestamps = jsonDecode(message);
        print("Received interval message: start ${timestamps['start']}, end ${timestamps['end']}"); // New print statement
        _parseMessage(timestamps);
        // Acknowledge the received message
        channel!.sink.add(jsonEncode({'ack': 'OK'}));
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    if (message.containsKey('start') && message.containsKey('end')) {
      final start = (message['start'] as num).toDouble() * 1000;
      final end = (message['end'] as num).toDouble() * 1000;

      if (_isDownloaded) {
        print("Attempting audio playback from $start ms to $end ms"); // Debug print
        audioPlayer.setFilePath(_filePath, preload: true);
        audioPlayer.seek(Duration(milliseconds: start.toInt()));
        audioPlayer.setClip(
          start: Duration(milliseconds: start.toInt()),
          end: Duration(milliseconds: end.toInt()),
        );
        audioPlayer.play();
      }
    } else if (message.containsKey('ack')) {
      final latency = message['ack'] as double;
      // Calculate the latency offset or perform any necessary action
      print('Received ack with latency: $latency');
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}

*/


/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();

    try {
      String url = 'ws://localhost:5009';
      print("URL is: $url");
      channel = IOWebSocketChannel.connect(url);
      print("WebSocket connection established with server: $url");

      // Send initial log message to the server
      channel!.sink.add(jsonEncode({'message': 'Client connected'}));

      channel!.stream.listen((message) {
        print("Listening to the WebSocket stream...");
        print("Received new timestamps: $message"); // Debug print
        Map<String, dynamic> timestamps = jsonDecode(message);
        print("Received interval message: start ${timestamps['start']}, end ${timestamps['end']}"); // New print statement
        _parseMessage(timestamps);
        // Acknowledge the received message
        channel!.sink.add(jsonEncode({'ack': 'OK'}));
      });
    } catch (e) {
      print("Error connecting to WebSocket: $e");
    }
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download('https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav', filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    if (message.containsKey('start') && message.containsKey('end')) {
      final start = (message['start'] as num).toDouble() * 1000;
      final end = (message['end'] as num).toDouble() * 1000;

      if (_isDownloaded) {
        print("Attempting audio playback from $start ms to $end ms"); // Debug print
        audioPlayer.setFilePath(_filePath, preload: true);
        audioPlayer.seek(Duration(milliseconds: start.toInt()));
        audioPlayer.setClip(
          start: Duration(milliseconds: start.toInt()),
          end: Duration(milliseconds: end.toInt()),
        );
        audioPlayer.play();
      }
    } else if (message.containsKey('ack')) {
      final latency = message['ack'] as double;
      // Calculate the latency offset or perform any necessary action
      print('Received ack with latency: $latency');
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/





/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();
    
    String url = 'ws://localhost:5005';  
    print("URL is: $url");
    channel = IOWebSocketChannel.connect(url);

    channel!.stream.listen((message) {
      print("Received new timestamps: $message");  // Debug print
      Map<String, dynamic> timestamps = jsonDecode(message);
      _parseMessage(timestamps);
    });
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download('https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav', filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    final String messageType = message['type'] as String;
  
    if (messageType == 'ack') {
      final latency = message['latency'] as double;
      // Calculate the latency offset or perform any necessary action
      print('Received ack with latency: $latency');
    } else if (messageType == 'interval') {
      final start = message['start'] as int;
      final end = message['end'] as int;

      if (_isDownloaded) {
        print("Attempting audio playback from $start to $end");  // Debug print
        audioPlayer.setFilePath(_filePath, preload: true);
        audioPlayer.seek(Duration(seconds: start));
        audioPlayer.setClip(start: Duration(seconds: start), end: Duration(seconds: end));
        audioPlayer.play();
      }
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/


/*
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();
    channel = IOWebSocketChannel.connect('ws://localhost:5005');
    channel!.stream.listen((message) {
      print("Received new timestamps: $message");  // Debug print
      Map<String, dynamic> timestamps = jsonDecode(message);
      _parseMessage(timestamps);
    });
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download('https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav', filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    final start = message['start'] as int;
    final end = message['end'] as int;

    if (_isDownloaded) {
      print("Attempting audio playback from $start to $end");  // Debug print
      audioPlayer.setFilePath(_filePath, preload: true);
      audioPlayer.seek(Duration(seconds: start));
      audioPlayer.setClip(start: Duration(seconds: start), end: Duration(seconds: end));
      audioPlayer.play();
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/



/*
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();
    downloadAudioFile();
    channel = IOWebSocketChannel.connect('http://127.0.0.1:5005');
    channel!.stream.listen((message) {
      print("Received new timestamps: $message");  // Debug print
      Map<String, dynamic> timestamps = jsonDecode(message);
      _parseMessage(timestamps);
    });
  }

  Future<void> downloadAudioFile() async {
    setState(() {
      _isDownloading = true;
    });

    final dio = Dio();
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/audio.wav';
    await dio.download('https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav', filePath);

    setState(() {
      _filePath = filePath;
      _isDownloading = false;
      _isDownloaded = true;
    });
  }

  void _parseMessage(Map<String, dynamic> message) {
    final start = message['start'] as int;
    final end = message['end'] as int;

    if (_isDownloaded) {
      print("Attempting audio playback from $start to $end");  // Debug print
      audioPlayer.setFilePath(_filePath, preload: true);
      audioPlayer.seek(Duration(seconds: start));
      audioPlayer.setClip(start: Duration(seconds: start), end: Duration(seconds: end));
      audioPlayer.play();
    }
  }

  @override
  void dispose() {
    audioPlayer.dispose();
    channel!.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Player'),
      ),
      body: Center(
        child: _isDownloading
            ? CircularProgressIndicator()
            : Text(_isDownloaded ? 'Audio file downloaded' : 'Failed to download audio file'),
      ),
    );
  }
}
*/

/*

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();

    // Replace with your server's WebSocket URL
    channel = IOWebSocketChannel.connect('ws://192.168.1.100:5005');

    channel?.stream.listen((message) {
      // Handle incoming messages
      Map<String, double> interval = _parseMessage(message);
      if (interval.isNotEmpty) {
        _playAudio(interval['start']!, interval['end']!);
      }
    });
  }

  Map<String, double> _parseMessage(String message) {
    // Parse message as JSON
    Map<String, dynamic> json = jsonDecode(message);
    // Validate 'start' and 'end' keys in JSON message
    if (json.containsKey('start') && json.containsKey('end')) {
      return {
        'start': double.tryParse(json['start'].toString()) ?? 0.0,
        'end': double.tryParse(json['end'].toString()) ?? 0.0,
      };
    }
    // If 'start' and 'end' keys are not found, return an empty map
    return {};
  }

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<void> _downloadFile() async {
    Dio dio = Dio();
    try {
      var dir = await _localPath;
      await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        '$dir/Soundwalk+version+4.wav',
        onReceiveProgress: (rec, total) {
          print("Rec: $rec , Total: $total");

          setState(() {
            _isDownloading = true;
          });

          if (rec == total) {
            setState(() {
              _isDownloading = false;
              _isDownloaded = true;
              _filePath = '$dir/Soundwalk+version+4.wav';
            });
          }
        },
      );
    } catch (e) {
      print(e);
      // Show error message if file download fails
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Failed to download audio file: $e"),
      ));
    }
  }

  Future<void> _playAudio(double start, double end) async {
    try {
      if (audioPlayer.playing) {
        await audioPlayer.stop();
      }
      await audioPlayer.setFilePath(_filePath);
      await audioPlayer.seek(Duration(milliseconds: (start * 1000).round()));
      await audioPlayer.setClip(start: Duration(milliseconds: (start * 1000).round()), end: Duration(milliseconds: (end * 1000).round()));
      audioPlayer.play();
    } catch (e) {
      print(e);
      // Show error message if audio playback fails
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Failed to play audio: $e"),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Server App'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isDownloading)
              Text('Downloading audio file...')
            else if (_isDownloaded)
              Text('Audio file downloaded'),
            ElevatedButton(
              onPressed: _downloadFile,
              child: Text('Download'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Close WebSocket connection when disposing of the widget
    channel?.sink.close();
    super.dispose();
  }
}

*/


/*

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;
  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();

    // Replace with your server's WebSocket URL
    channel = IOWebSocketChannel.connect('ws://192.168.1.100:5005');

    channel?.stream.listen((message) {
      // Handle incoming messages
      Map<String, double> interval = _parseMessage(message);
      _playAudio(interval['start']!, interval['end']!);
    });
  }

  Map<String, double> _parseMessage(String message) {
    // Parse message as JSON
    Map<String, dynamic> json = jsonDecode(message);
    return {
      'start': double.tryParse(json['start'].toString()) ?? 0.0,
      'end': double.tryParse(json['end'].toString()) ?? 0.0,
    };
  }

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<void> _downloadFile() async {
    Dio dio = Dio();
    try {
      var dir = await _localPath;
      await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        '$dir/Soundwalk+version+4.wav',
        onReceiveProgress: (rec, total) {
          print("Rec: $rec , Total: $total");

          setState(() {
            _isDownloading = true;
          });

          if (rec == total) {
            setState(() {
              _isDownloading = false;
              _isDownloaded = true;
              _filePath = '$dir/Soundwalk+version+4.wav';
            });
          }
        },
      );
    } catch (e) {
      print(e);
    }
  }

  Future<void> _playAudio(double start, double end) async {
    try {
      if (audioPlayer.playing) {
        await audioPlayer.stop();
      }
      await audioPlayer.setFilePath(_filePath);
      await audioPlayer.seek(Duration(milliseconds: (start * 1000).round()));
      await audioPlayer.setClip(start: Duration(milliseconds: (start * 1000).round()), end: Duration(milliseconds: (end * 1000).round()));
      audioPlayer.play();
    } catch (e) {
      print(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Server App'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isDownloading)
              Text('Downloading audio file...')
            else if (_isDownloaded)
              Text('Audio file downloaded'),
            ElevatedButton(
              onPressed: _downloadFile,
              child: Text('Download'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Close WebSocket connection when disposing of the widget
    channel?.sink.close();
    super.dispose();
  }
}
*/

/*

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;

  // define the audio segments
  final List<List<double>> audioSegments = [
    [0.0, 3.0],
    [3.123, 6.0],
    [6.0, 10.0]
  ];

  WebSocketChannel? channel;

  @override
  void initState() {
    super.initState();

    // Replace with your server's WebSocket URL
    channel = IOWebSocketChannel.connect('ws://your_server_ip:5005');

    channel?.stream.listen((message) {
      // Handle incoming messages
      // Parse your message here
      List<double> segment = _parseMessage(message);
      _playAudio(segment[0], segment[1]);
    });
  }

  List<double> _parseMessage(String message) {
    // TODO: Parse your message here according to the format you set on the server
    // Returning a default value for now
    return [0.0, 0.0];
  }

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<void> _downloadFile() async {
    Dio dio = Dio();
    try {
      var dir = await _localPath;
      await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        '$dir/Soundwalk+version+4.wav',
        onReceiveProgress: (rec, total) {
          print("Rec: $rec , Total: $total");

          setState(() {
            _isDownloading = true;
          });

          if (rec == total) {
            setState(() {
              _isDownloading = false;
              _isDownloaded = true;
              _filePath = '$dir/Soundwalk+version+4.wav';
            });
          }
        },
      );
    } catch (e) {
      print(e);
    }
  }

  Future<void> _playAudio(double start, double end) async {
    try {
      if (audioPlayer.playing) {
        await audioPlayer.stop();
      }
      await audioPlayer.setFilePath(_filePath);
      await audioPlayer.seek(Duration(milliseconds: (start * 1000).round()));
      await audioPlayer.setClip(start: Duration(milliseconds: (start * 1000).round()), end: Duration(milliseconds: (end * 1000).round()));
      audioPlayer.play();
    } catch (e) {
      print(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Server App'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isDownloading)
              Text('Downloading audio file...')
            else if (_isDownloaded)
              Text('Audio file downloaded'),
            ElevatedButton(
              onPressed: _downloadFile,
              child: Text('Download'),
            ),
            ...audioSegments.map((segment) => ElevatedButton(
              onPressed: () => _playAudio(segment[0], segment[1]),
              child: Text('Play segment ${segment[0]} - ${segment[1]}'),
            )).toList(),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Close WebSocket connection when disposing of the widget
    channel?.sink.close();
    super.dispose();
  }
}

*/



/*
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;

  // define the audio segments
  final List<List<double>> audioSegments = [
    [0.0, 3.0],
    [3.123, 6.0],
    [6.0, 10.0]
  ];

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<void> _downloadFile() async {
    Dio dio = Dio();
    try {
      var dir = await _localPath;
      await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        '$dir/Soundwalk+version+4.wav',
        onReceiveProgress: (rec, total) {
          print("Rec: $rec , Total: $total");

          setState(() {
            _isDownloading = true;
          });

          if (rec == total) {
            setState(() {
              _isDownloading = false;
              _isDownloaded = true;
              _filePath = '$dir/Soundwalk+version+4.wav';
            });
          }
        },
      );
    } catch (e) {
      print(e);
    }
  }

  Future<void> _playAudio(double start, double end) async {
    try {
      if (audioPlayer.playing) {
        await audioPlayer.stop();
      }
      await audioPlayer.setFilePath(_filePath);
      await audioPlayer.seek(Duration(milliseconds: (start * 1000).round()));
      await audioPlayer.setClip(start: Duration(milliseconds: (start * 1000).round()), end: Duration(milliseconds: (end * 1000).round()));
      audioPlayer.play();
    } catch (e) {
      print(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Server App'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isDownloading)
              Text('Downloading audio file...')
            else if (_isDownloaded)
              Text('Audio file downloaded'),
            ElevatedButton(
              onPressed: _downloadFile,
              child: Text('Download'),
            ),
            ...audioSegments.map((segment) => ElevatedButton(
              onPressed: () => _playAudio(segment[0], segment[1]),
              child: Text('Play segment ${segment[0]} - ${segment[1]}'),
            )).toList(),
          ],
        ),
      ),
    );
  }
}
*/


/*
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final audioPlayer = AudioPlayer();
  String _filePath = '';
  bool _isDownloading = false;
  bool _isDownloaded = false;

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Future<void> _downloadFile() async {
    Dio dio = Dio();
    try {
      var dir = await _localPath;
      await dio.download(
        'https://niknydatabucket.s3.eu-central-1.amazonaws.com/Soundwalk+version+4.wav',
        '$dir/Soundwalk+version+4.wav',
        onReceiveProgress: (rec, total) {
          print("Rec: $rec , Total: $total");

          setState(() {
            _isDownloading = true;
          });

          if (rec == total) {
            setState(() {
              _isDownloading = false;
              _isDownloaded = true;
              _filePath = '$dir/Soundwalk+version+4.wav';
            });
          }
        },
      );
    } catch (e) {
      print(e);
    }
  }

  Future<void> _playAudio() async {
    try {
      await audioPlayer.setFilePath(_filePath);
      audioPlayer.play();
    } catch (e) {
      print(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Audio Server App'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_isDownloading)
              Text('Downloading audio file...')
            else if (_isDownloaded)
              Text('Audio file downloaded'),
            ElevatedButton(
              onPressed: _downloadFile,
              child: Text('Download'),
            ),
            ElevatedButton(
              onPressed: _playAudio,
              child: Text('Play'),
            ),
          ],
        ),
      ),
    );
  }
}

*/