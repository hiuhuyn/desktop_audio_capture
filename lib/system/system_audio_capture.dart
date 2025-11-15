import 'dart:async';

import 'package:audio_capture/audio_capture.dart';
import 'package:flutter/services.dart';

export 'package:audio_capture/config/system_adudio_config.dart';
// DecibelData is exported from audio_capture.dart

enum _SystemAudioMethod {
  startCapture,
  stopCapture,
  requestPermissions,
}

class SystemAudioCapture extends AudioCapture {
  static const MethodChannel _channel = MethodChannel(
    'com.system_audio_transcriber/audio_capture',
  );
  static const EventChannel _audioStreamChannel = EventChannel(
    'com.system_audio_transcriber/audio_stream',
  );
  static const EventChannel _statusStreamChannel = EventChannel(
    'com.system_audio_transcriber/audio_status',
  );
  static const EventChannel _decibelStreamChannel = EventChannel(
    'com.system_audio_transcriber/audio_decibel',
  );

  Stream<Uint8List>? _audioStream;
  Stream<Map<String, dynamic>>? _statusStream;
  Stream<DecibelData>? _decibelStream;
  bool _isRecording = false;

  Stream<Uint8List>? get audioStream => _audioStream;
  
  /// Stream of system audio capture status updates
  /// Returns a map with:
  /// - `isActive`: bool - whether system audio capture is currently active
  Stream<Map<String, dynamic>>? get statusStream {
    // Create status stream if not already created
    _statusStream ??= _statusStreamChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      if (event is Map) {
        return Map<String, dynamic>.from(event);
      }
      return <String, dynamic>{'isActive': false};
    });
    return _statusStream;
  }

  /// Stream of system audio decibel (dB) readings
  /// Returns [DecibelData] containing:
  /// - `decibel`: double - decibel value (-120 to 0 dB)
  /// - `timestamp`: double - Unix timestamp
  Stream<DecibelData>? get decibelStream {
    if (!_isRecording) {
      return null;
    }
    // Create decibel stream if not already created
    _decibelStream ??= _decibelStreamChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      if (event is Map) {
        return DecibelData.fromMap(Map<String, dynamic>.from(event));
      }
      return DecibelData(decibel: -120.0, timestamp: DateTime.now().millisecondsSinceEpoch / 1000.0);
    });
    return _decibelStream;
  }

  SystemAudioConfig _config = SystemAudioConfig();

  SystemAudioCapture({SystemAudioConfig? config}) {
    _config = config ?? SystemAudioConfig();
  }

  void updateConfig(SystemAudioConfig config) {
    _config = config;
  }

  @override
  Future<void> initialize() async {}

  Future<void> startCapture({SystemAudioConfig? config}) async {
    if (_isRecording) {
      return;
    }

    if (config != null) {
      updateConfig(config);
    }

    try {
      await requestPermissions();

      final started = await _channel.invokeMethod<bool>(
        _SystemAudioMethod.startCapture.name,
        _config.toMap(),
      );

      if (started != true) {
        throw Exception('Failed to start system audio capture');
      }

      // Listen to audio stream
      _audioStream = _audioStreamChannel.receiveBroadcastStream().map((
        dynamic event,
      ) {
        if (event is Uint8List) {
          return event;
        } else if (event is List<int>) {
          return Uint8List.fromList(event);
        }
        throw Exception('Unexpected audio data type: ${event.runtimeType}');
      });

      // Status stream is created lazily via getter, no need to recreate here

      _isRecording = true;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> stopCapture() async {
    if (!_isRecording) return;

    try {
      final stopped = await _channel.invokeMethod<bool>(
        _SystemAudioMethod.stopCapture.name,
      );

      if (stopped != true) {
        throw Exception("Failed to stop system audio capture");
      }

      _isRecording = false;
      _audioStream = null;
      _statusStream = null;
      _decibelStream = null;
    } catch (e) {
      rethrow;
    }
  }

  @override
  bool get isRecording => _isRecording;

  Future<bool> requestPermissions() async {
    final hasPermission = await _channel.invokeMethod<bool>(
      _SystemAudioMethod.requestPermissions.name,
    );
    if (hasPermission != true) {
      throw Exception('Screen recording permission not granted');
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    await stopCapture();
  }
}
