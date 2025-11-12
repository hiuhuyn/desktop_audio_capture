import 'package:audio_capture/audio_capture.dart';
import 'package:audio_capture/config/mic_audio_config.dart';

class MicAudioCapture extends AudioCapture {
  @override
  Future<void> startCapture({AudioCaptureConfig? config}) async {
    if (config is MicAudioConfig) {
      return startCapture(config: config);
    }
    throw UnimplementedError();
  }

  @override
  Future<void> stopCapture() async {
    throw UnimplementedError();
  }
  
  @override
  Future<bool> isCapturing() async {
    return false;
  }
  
  @override
  Future<bool> isSupported() async {
    return true;
  }
  
  @override
  Future<bool> requestPermissions() async {
    return true;
  }
}