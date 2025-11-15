// You have generated a new plugin project without specifying the `--platforms`
// flag. A plugin project with no platform support was generated. To add a
// platform, run `flutter create -t plugin --platforms <platforms> .` under the
// same directory. You can also find a detailed instruction on how to add
// platforms in the `pubspec.yaml` at
// https://flutter.dev/to/pubspec-plugin-platforms.

export 'package:audio_capture/mic/mic_audio_capture.dart';
export 'package:audio_capture/system/system_audio_capture.dart';

// Re-export DecibelData from mic_audio_capture (both mic and system use the same class)
export 'package:audio_capture/mic/mic_audio_capture.dart' show DecibelData;

abstract class AudioCapture {
  Future<void> initialize();
  Future<bool> isSupported();
  Future<void> dispose();
}

abstract class AudioCaptureConfig {}