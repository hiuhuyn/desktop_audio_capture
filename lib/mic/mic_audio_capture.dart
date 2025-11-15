import 'dart:async';

import 'package:audio_capture/audio_capture.dart';
import 'package:flutter/services.dart';
export 'package:audio_capture/config/mic_audio_config.dart';

enum _MicAudioMethod {
  isSupported,
  startCapture,
  stopCapture,
  requestPermissions,
}

class MicAudioCapture extends AudioCapture {
  static const MethodChannel _channel = MethodChannel(
    'com.mic_audio_transcriber/mic_capture',
  );
  static const EventChannel _audioStreamChannel = EventChannel(
    'com.mic_audio_transcriber/mic_stream',
  );

  Stream<Uint8List>? _audioStream;
  bool _isRecording = false;

  Stream<Uint8List>? get audioStream => _audioStream;

  MicAudioConfig _config = MicAudioConfig();

  MicAudioCapture({MicAudioConfig? config}) {
    _config = config ?? MicAudioConfig();
  }

  void updateConfig(MicAudioConfig config) {
    _config = config;
  }

  @override
  Future<void> initialize() async {}

  Future<void> startCapture({MicAudioConfig? config}) async {
    if (_isRecording) {
      return;
    }

    if (config != null) {
      updateConfig(config);
    }

    try {
      await requestPermissions();

      final started = await _channel.invokeMethod<bool>(
        _MicAudioMethod.startCapture.name,
        _config.toMap(),
      );

      if (started != true) {
        throw Exception('Failed to start microphone capture');
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

      _isRecording = true;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> stopCapture() async {
    if (!_isRecording) return;

    try {
      final stoped = await _channel.invokeMethod<bool>(
        _MicAudioMethod.stopCapture.name,
      );

      if (stoped != true) {
        throw Exception("Failed to stop microphone capture");
      }

      _isRecording = false;
      _audioStream = null;
    } catch (e) {
      rethrow;
    }
  }

  Future<bool> isCapturing() async {
    return _isRecording;
  }

  @override
  Future<bool> isSupported() async {
    try {
      final isSupport = await _channel.invokeMethod<bool>(
        _MicAudioMethod.isSupported.name,
      );

      return isSupport ?? false;
    } catch (e) {
      rethrow;
    }
  }

  Future<bool> requestPermissions() async {
    final hasPermission = await _channel.invokeMethod<bool>(
      _MicAudioMethod.requestPermissions.name,
    );
    if (hasPermission != true) {
      throw Exception('Microphone permission not granted');
    }
    return true;
  }

  @override
  Future<void> dispose() {
    // TODO: implement dispose
    throw UnimplementedError();
  }
}
