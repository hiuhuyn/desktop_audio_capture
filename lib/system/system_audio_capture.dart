import 'package:audio_capture/audio_capture.dart';
import 'package:audio_capture/config/system_adudio_config.dart';

class SystemAudioCapture extends AudioCapture {
  @override
  Future<void> initialize() {
    // TODO: implement initialize
    throw UnimplementedError();
  }

  Future<void> startCapture({SystemAudioConfig? config}) async {
    throw UnimplementedError();
  }

  Future<void> stopCapture() async {
    throw UnimplementedError();
  }

  Future<bool> isCapturing() async {
    return false;
  }

  @override
  Future<bool> isSupported() async {
    return true;
  }

  @override
  Future<void> dispose() {
    // TODO: implement dispose
    throw UnimplementedError();
  }
}
