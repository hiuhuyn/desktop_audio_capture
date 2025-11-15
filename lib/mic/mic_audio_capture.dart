import 'dart:async';

import 'package:audio_capture/audio_capture.dart';
import 'package:flutter/services.dart';
export 'package:audio_capture/config/mic_audio_config.dart';

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

  Stream<Uint8List>? _audioStream;
  Stream<Map<String, dynamic>>? _statusStream;
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
  /// Returns a map with:
  /// - `isActive`: bool - whether mic is currently active
  /// - `deviceName`: String? - name of the microphone device (if available)
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

  /// Kiểm tra xem có thiết bị input (microphone) nào khả dụng không
  /// 
  /// Returns `true` nếu có ít nhất một thiết bị input khả dụng, `false` nếu không có
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

  /// Lấy danh sách tất cả các thiết bị input (microphone) khả dụng
  /// 
  /// Returns một danh sách các Map chứa thông tin thiết bị:
  /// - `id`: String - ID của thiết bị
  /// - `name`: String - Tên thiết bị
  /// - `type`: String - Loại thiết bị ("built-in", "bluetooth", hoặc "external")
  /// - `channelCount`: int - Số lượng kênh audio
  /// - `isDefault`: bool - Có phải thiết bị mặc định không
  Future<List<Map<String, dynamic>>> getAvailableInputDevices() async {
    try {
      final devices = await _channel.invokeMethod<List<dynamic>>(
        _MicAudioMethod.getAvailableInputDevices.name,
      );
      
      if (devices == null) {
        return [];
      }
      
      return devices.map((device) {
        if (device is Map) {
          return Map<String, dynamic>.from(device);
        }
        return <String, dynamic>{};
      }).toList();
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
