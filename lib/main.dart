import 'dart:async';
import 'dart:convert';
import 'dart:math'; // Needed for the math algorithm
import 'package:flutter/material.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:flutter_contacts/flutter_contacts.dart'; // NEW
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  await dotenv.load(fileName: ".env");
  runApp(const MaterialApp(home: AdelBrain()));
}

class AdelBrain extends StatefulWidget {
  const AdelBrain({super.key});

  @override
  State<AdelBrain> createState() => _AdelBrainState();
}

class _AdelBrainState extends State<AdelBrain> {
  // --- CONFIGURATION ---
  final String picoAccessKey = dotenv.env['picoAccessKey'] ?? '';
  final String wakeWordPath = "assets/porcupine/hey-adel_en_android_v4_0_0.ppn";
  final String voskModelAsset = "assets/vosk/model.zip";

  // --- STATE ---
  String statusLog = "Initializing...";
  String transcribedText = "";
  bool isListening = false;
  List<Contact> _phoneContacts = []; // Store contacts here
  
  // --- ENGINES ---
  PorcupineManager? _porcupine;
  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  Model? _voskModel;
  Recognizer? _voskRecognizer;
  SpeechService? _speechService;

  @override
  void initState() {
    super.initState();
    initSystem();
  }

  @override
  void dispose() {
    _porcupine?.delete();
    _speechService?.dispose();
    super.dispose();
  }

  Future<void> initSystem() async {
    try {
      // 1. Request ALL Permissions
      await [
        Permission.microphone, 
        Permission.phone,
        Permission.contacts // NEW
      ].request();

      // 2. Load Contacts into RAM
      setState(() => statusLog = "Reading Contacts...");
      if (await FlutterContacts.requestPermission()) {
        _phoneContacts = await FlutterContacts.getContacts(withProperties: true);
        print("Loaded ${_phoneContacts.length} contacts.");
      }

      // 3. Load Vosk
      setState(() => statusLog = "Unpacking Brain...");
      final modelPath = await ModelLoader().loadFromAssets(voskModelAsset);
      _voskModel = await _vosk.createModel(modelPath);
      
      _voskRecognizer = await _vosk.createRecognizer(
        model: _voskModel!,
        sampleRate: 16000,
      );

      // 4. Load Porcupine
      setState(() => statusLog = "Loading Ears...");
      _porcupine = await PorcupineManager.fromKeywordPaths(
        picoAccessKey,
        [wakeWordPath],
        _onWakeWordDetected,
        sensitivities: [0.7], 
      );

      await _startWakeWordLoop();

    } catch (e) {
      setState(() => statusLog = "Fatal Error: $e");
    }
  }

  // --- WATCHDOG LOOP ---
  Future<void> _startWakeWordLoop() async {
    if (_speechService != null) {
      await _speechService!.stop();
      await _speechService!.dispose(); 
      _speechService = null;
    }
    _voskRecognizer?.reset();

    if (!mounted) return;

    setState(() {
      isListening = false;
      statusLog = "Waiting for 'Hey Adel'...";
    });
    
    try {
      await _porcupine?.start();
    } catch (e) {
      await Future.delayed(const Duration(seconds: 1));
      _startWakeWordLoop();
    }
  }

  // --- ACTIVE LISTENER ---
  Future<void> _onWakeWordDetected(int index) async {
    await _porcupine?.stop();

    setState(() {
      isListening = true;
      statusLog = "Listening...";
      transcribedText = ""; 
    });

    try {
      if (_voskRecognizer != null) {
        _speechService = await _vosk.initSpeechService(_voskRecognizer!);
        
        _speechService?.onPartial().listen((event) {
           Map<String, dynamic> data = jsonDecode(event);
           String partial = data['partial'] ?? "";
           if (partial.isNotEmpty && isListening) {
             setState(() => transcribedText = partial);
           }
        });

        _speechService?.onResult().listen((event) {
          Map<String, dynamic> data = jsonDecode(event);
          String text = data['text'] ?? "";
          if (text.isNotEmpty && isListening) {
             setState(() => transcribedText = text);
             _processCommand(text);
          }
        });

        await _speechService?.start();
      }
    } catch (e) {
      _startWakeWordLoop();
    }
  }

  // --- HELPER: LEVENSHTEIN DISTANCE (Fuzzy Matcher) ---
  // Returns how different two strings are (0 = identical)
  int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    List<int> v0 = List<int>.filled(t.length + 1, 0);
    List<int> v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < t.length + 1; i++) v0[i] = i;

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < t.length; j++) {
        int cost = (s[i] == t[j]) ? 0 : 1;
        v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
      }
      for (int j = 0; j < t.length + 1; j++) v0[j] = v1[j];
    }
    return v1[t.length];
  }

  // --- THE BRAIN ---
  void _processCommand(String command) async {
    setState(() => statusLog = "Processing: $command");
    command = command.toLowerCase();

    // 1. GOOGLE SEARCH
    if (command.startsWith("google")) {
      String query = command.replaceFirst("google", "").trim();
      if (query.isNotEmpty) {
        final Uri url = Uri.parse("https://www.google.com/search?q=${Uri.encodeComponent(query)}");
        if (await canLaunchUrl(url)) await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    }

    // 2. CALLING (Smart Contact Search)
    else if (command.contains("call")) {
      // Clean up the command (remove "call")
      String rawTarget = command.replaceFirst("call", "").trim();
      
      // A. IS IT A NUMBER?
      String numbers = rawTarget.replaceAll(RegExp(r'[^0-9]'), '');
      if (numbers.length > 2) {
         // It's a direct number dialing
         final Uri launchUri = Uri(scheme: 'tel', path: numbers);
         if (await canLaunchUrl(launchUri)) await launchUrl(launchUri);
      } 
      
      // B. IS IT A NAME? (Fuzzy Search)
      else if (_phoneContacts.isNotEmpty && rawTarget.isNotEmpty) {
        Contact? bestMatch;
        int lowestScore = 100; // Lower is better

        for (var contact in _phoneContacts) {
          String name = contact.displayName.toLowerCase();
          // Calculate difference between spoken word and contact name
          int score = _levenshtein(rawTarget, name);
          
          // Debugging log to see what it compares
          // print("Comparing '$rawTarget' with '$name' -> Score: $score");

          if (score < lowestScore) {
            lowestScore = score;
            bestMatch = contact;
          }
        }

        // THRESHOLD: If the score is low (good match), call them.
        // A score of 0, 1, or 2 is usually a safe match.
        if (bestMatch != null && lowestScore <= 3) {
           String? phone = bestMatch.phones.isNotEmpty ? bestMatch.phones.first.number : null;
           if (phone != null) {
             setState(() => transcribedText = "Calling ${bestMatch!.displayName}...");
             final Uri launchUri = Uri(scheme: 'tel', path: phone);
             if (await canLaunchUrl(launchUri)) await launchUrl(launchUri);
           } else {
             setState(() => transcribedText = "${bestMatch!.displayName} has no number.");
           }
        } else {
           setState(() => transcribedText = "Couldn't find '$rawTarget'");
        }
      }
    }
    
    // 3. APPS
    else if (command.contains("open youtube")) {
      await LaunchApp.openApp(androidPackageName: 'com.google.android.youtube', openStore: false);
    }
    else if (command.contains("open whatsapp") || command.contains("open what's up")) {
      await LaunchApp.openApp(androidPackageName: 'com.whatsapp', openStore: false);
    } 

    Future.delayed(const Duration(seconds: 2), () {
      _startWakeWordLoop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: isListening ? Colors.red.shade900 : Colors.blue.shade900,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isListening ? Icons.hearing : Icons.mic_none, size: 80, color: Colors.white),
            const SizedBox(height: 20),
            Text(statusLog, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                transcribedText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
