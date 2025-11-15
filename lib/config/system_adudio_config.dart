import 'package:desktop_audio_capture/audio_capture.dart';

class SystemAudioConfig extends AudioCaptureConfig {
  /// Sample rate in Hz (default: 16000)
  final int sampleRate;

  /// Number of audio channels (default: 1 for mono)
  final int channels;

  SystemAudioConfig({
    this.sampleRate = 16000,
    this.channels = 1,
  });

  /// Create a copy with modified values
  SystemAudioConfig copyWith({
    int? sampleRate,
    int? channels,
  }) {
    return SystemAudioConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
    );
  }

  /// Convert to map for method channel
  Map<String, dynamic> toMap() {
    return {
      'sampleRate': sampleRate,
      'channels': channels,
    };
  }

  @override
  String toString() {
    return 'SystemAudioConfig(sampleRate: $sampleRate, channels: $channels)';
  }
}