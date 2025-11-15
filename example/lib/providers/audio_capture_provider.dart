import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:audio_capture/audio_capture.dart';
import 'package:audio_capture/mic/mic_audio_capture.dart' hide DecibelData;
import 'package:audio_capture/system/system_audio_capture.dart';

class AudioCaptureProvider with ChangeNotifier {
  final MicAudioCapture _micCapture = MicAudioCapture();
  final SystemAudioCapture _systemCapture = SystemAudioCapture();

  // Mic state
  bool _micActive = false;
  String? _micDeviceName;
  StreamSubscription<MicStatus>? _micStatusSubscription;
  StreamSubscription<Uint8List>? _micAudioSubscription; // Keep reference to trigger onListen
  StreamSubscription<DecibelData>? _micDecibelSubscription;
  double _micDecibel = -120.0;
  String? _micError;

  // System state
  bool _systemActive = false;
  StreamSubscription<Map<String, dynamic>>? _systemStatusSubscription;
  StreamSubscription<Uint8List>? _systemAudioSubscription; // Keep reference to trigger onListen
  StreamSubscription<DecibelData>? _systemDecibelSubscription;
  double _systemDecibel = -120.0;
  String? _systemError;

  // Getters
  bool get micActive => _micActive;
  String? get micDeviceName => _micDeviceName;
  double get micDecibel => _micDecibel;
  String? get micError => _micError;
  bool get systemActive => _systemActive;
  double get systemDecibel => _systemDecibel;
  String? get systemError => _systemError;

  MicAudioCapture get micCapture => _micCapture;
  SystemAudioCapture get systemCapture => _systemCapture;

  Stream<Uint8List>? get micAudioStream => _micCapture.audioStream;
  Stream<Uint8List>? get systemAudioStream => _systemCapture.audioStream;

  AudioCaptureProvider() {
    _setupStatusListeners();
  }

  void _setupStatusListeners() {
    // Status streams will be set up when capture starts
  }

  Future<void> toggleMic({MicAudioConfig? config}) async {
    try {
      _micError = null;
      notifyListeners();

      if (_micActive) {
        await _micCapture.stopCapture();
        _micStatusSubscription?.cancel();
        _micStatusSubscription = null;
        _micAudioSubscription?.cancel();
        _micAudioSubscription = null;
        _micDecibelSubscription?.cancel();
        _micDecibelSubscription = null;
        _micActive = false;
        _micDeviceName = null;
        _micDecibel = -120.0;
        notifyListeners();
      } else {
        // Update config if provided
        if (config != null) {
          _micCapture.updateConfig(config);
        }

        // Setup status listener BEFORE starting capture
        _micStatusSubscription?.cancel();
        _micStatusSubscription = _micCapture.statusStream?.listen((status) {
          _micActive = status.isActive;
          _micDeviceName = status.deviceName;
          notifyListeners();
        });

        await _micCapture.startCapture();
        
        // Subscribe to audio stream AFTER starting capture
        // This ensures eventSink is set on native side so audio data can flow
        // The stream is created in startCapture(), so we can subscribe now
        // This subscription keeps the stream active - widgets will also subscribe
        _micAudioSubscription?.cancel();
        if (_micCapture.audioStream != null) {
          _micAudioSubscription = _micCapture.audioStream!.listen(
            (_) {
              // Data will be handled by actual listeners in widgets
              // This subscription just keeps the stream active
            },
            onError: (_) {
              // Errors will be handled by actual listeners
            },
            cancelOnError: false,
          );
        }
        
        // Subscribe to decibel stream
        _micDecibelSubscription?.cancel();
        final micDecibelStream = _micCapture.decibelStream;
        if (micDecibelStream != null) {
          _micDecibelSubscription = micDecibelStream.listen(
            (decibelData) {
              _micDecibel = decibelData.decibel;
              notifyListeners();
            },
            onError: (_) {
              // Errors will be handled silently
            },
            cancelOnError: false,
          );
        }
      }
    } catch (e) {
      _micError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> toggleSystem({SystemAudioConfig? config}) async {
    try {
      _systemError = null;
      notifyListeners();

      if (_systemActive) {
        await _systemCapture.stopCapture();
        _systemStatusSubscription?.cancel();
        _systemStatusSubscription = null;
        _systemAudioSubscription?.cancel();
        _systemAudioSubscription = null;
        _systemDecibelSubscription?.cancel();
        _systemDecibelSubscription = null;
        _systemActive = false;
        _systemDecibel = -120.0;
        notifyListeners();
      } else {
        // Update config if provided
        if (config != null) {
          _systemCapture.updateConfig(config);
        }

        // Setup status listener BEFORE starting capture
        _systemStatusSubscription?.cancel();
        _systemStatusSubscription = _systemCapture.statusStream?.listen((status) {
          _systemActive = status['isActive'] as bool? ?? false;
          notifyListeners();
        });

        await _systemCapture.startCapture();
        
        // Subscribe to audio stream AFTER starting capture
        // This ensures eventSink is set on native side so audio data can flow
        _systemAudioSubscription?.cancel();
        if (_systemCapture.audioStream != null) {
          _systemAudioSubscription = _systemCapture.audioStream!.listen(
            (_) {
              // Data will be handled by actual listeners in widgets
            },
            onError: (_) {
              // Errors will be handled by actual listeners
            },
            cancelOnError: false,
          );
        }
        
        // Subscribe to decibel stream
        _systemDecibelSubscription?.cancel();
        final systemDecibelStream = _systemCapture.decibelStream;
        if (systemDecibelStream != null) {
          _systemDecibelSubscription = systemDecibelStream.listen(
            (decibelData) {
              _systemDecibel = decibelData.decibel;
              notifyListeners();
            },
            onError: (_) {
              // Errors will be handled silently
            },
            cancelOnError: false,
          );
        }
      }
    } catch (e) {
      _systemError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  @override
  void dispose() {
    _micStatusSubscription?.cancel();
    _micAudioSubscription?.cancel();
    _micDecibelSubscription?.cancel();
    _systemStatusSubscription?.cancel();
    _systemAudioSubscription?.cancel();
    _systemDecibelSubscription?.cancel();
    _micCapture.dispose();
    _systemCapture.dispose();
    super.dispose();
  }
}

