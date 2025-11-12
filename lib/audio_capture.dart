// You have generated a new plugin project without specifying the `--platforms`
// flag. A plugin project with no platform support was generated. To add a
// platform, run `flutter create -t plugin --platforms <platforms> .` under the
// same directory. You can also find a detailed instruction on how to add
// platforms in the `pubspec.yaml` at
// https://flutter.dev/to/pubspec-plugin-platforms.

export 'package:audio_capture/mic/mic_audio_capture.dart';
export 'package:audio_capture/system/system_audio_capture.dart';

abstract class AudioCapture {
  Future<void> startCapture({AudioCaptureConfig? config});
  Future<void> stopCapture();
  Future<bool> isSupported();
  Future<bool> requestPermissions();
  Future<bool> isCapturing();
}

abstract class AudioCaptureConfig {}