import 'dart:async';

import 'package:audio_capture/audio_capture.dart';
import 'package:flutter/services.dart';
export 'package:audio_capture/config/mic_audio_config.dart';
export 'package:audio_capture/mic/input_device.dart';

/// Decibel data from audio capture
class DecibelData {
  final double decibel; // -120 to 0 dB
  final double timestamp; // Unix timestamp

  const DecibelData({
    required this.decibel,
    required this.timestamp,
  });

  factory DecibelData.fromMap(Map<String, dynamic> map) {
    return DecibelData(
      decibel: (map['decibel'] as num?)?.toDouble() ?? -120.0,
      timestamp: (map['timestamp'] as num?)?.toDouble() ?? 
          DateTime.now().millisecondsSinceEpoch / 1000.0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'decibel': decibel,
      'timestamp': timestamp,
    };
  }

  @override
  String toString() => 'DecibelData(decibel: ${decibel.toStringAsFixed(1)} dB, timestamp: $timestamp)';
}

enum _MicAudioMethod {
  isSupported,
  startCapture,
  stopCapture,
  requestPermissions,
  hasInputDevice,
  getAvailableInputDevices,
}

class MicAudioCapture extends AudioCapture {
  static const MethodChannel _channel = MethodChannel(
    'com.mic_audio_transcriber/mic_capture',
  );
  static const EventChannel _audioStreamChannel = EventChannel(
    'com.mic_audio_transcriber/mic_stream',
  );
  static const EventChannel _statusStreamChannel = EventChannel(
    'com.mic_audio_transcriber/mic_status',
  );
  static const EventChannel _decibelStreamChannel = EventChannel(
    'com.mic_audio_transcriber/mic_decibel',
  );

  Stream<Uint8List>? _audioStream;
  Stream<MicStatus>? _statusStream;
  Stream<DecibelData>? _decibelStream;
  bool _isRecording = false;

  Stream<Uint8List>? get audioStream {
    // Return existing stream if available
    if (_audioStream != null) {
      return _audioStream;
    }
    // If not recording, return null
    if (!_isRecording) {
      return null;
    }
    // Create stream lazily if recording but stream not created yet
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
    return _audioStream;
  }
  
  /// Stream of microphone status updates
  /// Returns [MicStatus] containing:
  /// - `isActive`: whether mic is currently active
  /// - `deviceName`: name of the microphone device (if available)
  Stream<MicStatus>? get statusStream {
    // Create status stream if not already created
    _statusStream ??= _statusStreamChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      if (event is Map) {
        return MicStatus.fromMap(Map<String, dynamic>.from(event));
      }
      return const MicStatus(isActive: false);
    });
    return _statusStream;
  }

  /// Stream of microphone decibel (dB) readings
  /// Returns [DecibelData] containing:
  /// - `decibel`: double - decibel value (-120 to 0 dB)
  /// - `timestamp`: double - Unix timestamp
  Stream<DecibelData>? get decibelStream => _decibelStream;

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

      try {
        final result = await _channel.invokeMethod<dynamic>(
          _MicAudioMethod.startCapture.name,
          _config.toMap(),
        );

        if (result is! bool || result != true) {
          final errorMsg = result is String 
              ? result 
              : 'Failed to start microphone capture. Returned: $result';
          throw Exception(errorMsg);
        }
      } on PlatformException catch (e) {
        throw Exception('Failed to start microphone capture: ${e.message ?? e.code}');
      }

      // Create audio stream
      // Note: Stream will be subscribed by listeners, which triggers onListen on native side
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

      // Create decibel stream
      _decibelStream = _decibelStreamChannel.receiveBroadcastStream().map((
        dynamic event,
      ) {
        if (event is Map) {
          return DecibelData.fromMap(Map<String, dynamic>.from(event));
        }
        return DecibelData(decibel: -120.0, timestamp: DateTime.now().millisecondsSinceEpoch / 1000.0);
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
      final stoped = await _channel.invokeMethod<bool>(
        _MicAudioMethod.stopCapture.name,
      );

      if (stoped != true) {
        throw Exception("Failed to stop microphone capture");
      }

      _isRecording = false;
      _audioStream = null;
      _statusStream = null;
      _decibelStream = null;
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

  /// Check if there is any available input device (microphone)
  /// 
  /// Returns `true` if there is at least one available input device, `false` if there is no available input device
  Future<bool> hasInputDevice() async {
    try {
      final hasDevice = await _channel.invokeMethod<bool>(
        _MicAudioMethod.hasInputDevice.name,
      );
      return hasDevice ?? false;
    } catch (e) {
      rethrow;
    }
  }

  /// Get available input devices (microphone)
  /// 
  /// Returns a list of [InputDevice] containing device information:
  /// - `id`: Device ID
  /// - `name`: Device name
  /// - `type`: Device type ([InputDeviceType])
  /// - `channelCount`: Number of audio channels
  /// - `isDefault`: Whether the device is the default device
  Future<List<InputDevice>> getAvailableInputDevices() async {
    try {
      final devices = await _channel.invokeMethod<List<dynamic>>(
        _MicAudioMethod.getAvailableInputDevices.name,
      );
      
      if (devices == null) {
        return [];
      }
      
      return devices
          .whereType<Map>()
          .map((device) => InputDevice.fromMap(
                Map<String, dynamic>.from(device),
              ))
          .toList();
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> dispose() {
    // TODO: implement dispose
    throw UnimplementedError();
  }
}
