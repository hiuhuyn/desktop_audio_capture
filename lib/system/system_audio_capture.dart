import 'package:audio_capture/audio_capture.dart';
import 'package:audio_capture/config/system_adudio_config.dart';

class SystemAudioCapture extends AudioCapture {
  @override
  Future<void> initialize() {
    // TODO: implement initialize
    throw UnimplementedError();
  }

  @override
  Future<void> startCapture({AudioCaptureConfig? config}) async {
    if (config is SystemAudioConfig) {
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
  
  @override
  Future<void> dispose() {
    // TODO: implement dispose
    throw UnimplementedError();
  }
}
