import 'package:flutter_test/flutter_test.dart';
import 'package:audio_capture/audio_capture.dart';
import 'package:audio_capture/audio_capture_platform_interface.dart';
import 'package:audio_capture/audio_capture_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAudioCapturePlatform
    with MockPlatformInterfaceMixin
    implements AudioCapturePlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final AudioCapturePlatform initialPlatform = AudioCapturePlatform.instance;

  test('$MethodChannelAudioCapture is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAudioCapture>());
  });

  test('getPlatformVersion', () async {
    AudioCapture audioCapturePlugin = AudioCapture();
    MockAudioCapturePlatform fakePlatform = MockAudioCapturePlatform();
    AudioCapturePlatform.instance = fakePlatform;

    expect(await audioCapturePlugin.getPlatformVersion(), '42');
  });
}
