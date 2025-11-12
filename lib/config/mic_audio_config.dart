import 'package:audio_capture/audio_capture.dart';

class MicAudioConfig extends AudioCaptureConfig {
  /// Sample rate in Hz (default: 16000)
  final int sampleRate;

  /// Number of audio channels (default: 1 for mono)
  final int channels;

  /// Bit depth (default: 16)
  final int bitDepth;

  /// Gain boost multiplier (default: 2.5, range: 0.1 to 10.0)
  /// Higher values increase microphone sensitivity
  final double gainBoost;

  /// Input volume (default: 1.0, range: 0.0 to 1.0)
  final double inputVolume;

  MicAudioConfig({
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitDepth = 16,
    this.gainBoost = 2.5,
    this.inputVolume = 1.0,
  });

  /// Create a copy with modified values
  MicAudioConfig copyWith({
    int? sampleRate,
    int? channels,
    int? bitDepth,
    double? gainBoost,
    double? inputVolume,
  }) {
    return MicAudioConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      bitDepth: bitDepth ?? this.bitDepth,
      gainBoost: gainBoost ?? this.gainBoost,
      inputVolume: inputVolume ?? this.inputVolume,
    );
  }

  /// Convert to map for method channel
  Map<String, dynamic> toMap() {
    return {
      'sampleRate': sampleRate,
      'channels': channels,
      'bitDepth': bitDepth,
      'gainBoost': gainBoost,
      'inputVolume': inputVolume,
    };
  }

  @override
  String toString() {
    return 'MicConfig(sampleRate: $sampleRate, channels: $channels, bitDepth: $bitDepth, gainBoost: $gainBoost, inputVolume: $inputVolume)';
  }
}

