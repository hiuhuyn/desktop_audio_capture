import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:desktop_audio_capture/mic/mic_audio_capture.dart';
import 'providers/audio_capture_provider.dart';
import 'providers/settings_provider.dart';
import 'widgets/audio_data_display.dart';
import 'widgets/decibel_display.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AudioCaptureProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        title: 'Audio Capture Example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: const AudioCaptureHome(),
      ),
    );
  }
}

class AudioCaptureHome extends StatelessWidget {
  const AudioCaptureHome({super.key});

  Future<void> _handleToggleMic(BuildContext context) async {
    final captureProvider = context.read<AudioCaptureProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    try {
      await captureProvider.toggleMic(config: settingsProvider.getMicConfig());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: SelectableText('Mic error: $e')),
        );
      }
    }
  }

  Future<void> _handleToggleSystem(BuildContext context) async {
    final captureProvider = context.read<AudioCaptureProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    try {
      await captureProvider.toggleSystem(config: settingsProvider.getSystemConfig());
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: SelectableText('System audio error: $e')),
        );
      }
    }
  }

  Future<void> _showInputDevicesDialog(BuildContext context) async {
    final captureProvider = context.read<AudioCaptureProvider>();
    final micCapture = captureProvider.micCapture;

    // Show loading
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Check if device is available
      final hasDevice = await micCapture.hasInputDevice();
      
      // Get available devices
      final devices = await micCapture.getAvailableInputDevices();

      if (!context.mounted) return;
      Navigator.of(context).pop(); // Close loading

      // Show devices dialog
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Available Input Devices'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Has Input Device: ${hasDevice ? "Yes" : "No"}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                if (devices.isEmpty)
                  const Text('No devices found')
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: devices.length,
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(
                              device.type == InputDeviceType.bluetooth
                                  ? Icons.bluetooth
                                  : device.type == InputDeviceType.builtIn
                                      ? Icons.phone_android
                                      : Icons.usb,
                            ),
                            title: Text(
                              device.name,
                              style: TextStyle(
                                fontWeight: device.isDefault
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Type: ${device.type}'),
                                Text('Channels: ${device.channelCount}'),
                                if (device.isDefault)
                                  const Text(
                                    'Default Device',
                                    style: TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                              ],
                            ),
                            isThreeLine: true,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop(); // Close loading
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: SelectableText('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio Capture'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<AudioCaptureProvider>(
        builder: (context, provider, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Mic Audio Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.mic, size: 32),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Microphone',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Switch(
                              value: provider.micActive,
                              onChanged: (_) => _handleToggleMic(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          provider.micActive
                              ? (provider.micDeviceName != null
                                  ? 'Device: ${provider.micDeviceName}'
                                  : 'Status: Active')
                              : 'Status: Inactive',
                          style: TextStyle(
                            color: provider.micActive ? Colors.green : Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.devices, size: 18),
                          label: const Text('View Available Devices'),
                          onPressed: () => _showInputDevicesDialog(context),
                        ),
                      ],
                    ),
                  ),
                ),
                // Mic Decibel Display
                const SizedBox(height: 8),
                DecibelDisplay(
                  decibel: provider.micDecibel,
                  label: 'Microphone Decibel',
                  isActive: provider.micActive,
                ),
                // Mic Audio Data Display
                if (provider.micActive) ...[
                  const SizedBox(height: 8),
                  Consumer<SettingsProvider>(
                    builder: (context, settings, _) {
                      return AudioDataDisplay(
                        audioStream: provider.micAudioStream,
                        label: 'Microphone',
                        sampleRate: settings.micSampleRate,
                        channels: settings.micChannels,
                      );
                    },
                  ),
                ],
                const SizedBox(height: 16),
                // System Audio Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.speaker, size: 32),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'System Audio',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Switch(
                              value: provider.systemActive,
                              onChanged: (_) => _handleToggleSystem(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          provider.systemActive ? 'Status: Active' : 'Status: Inactive',
                          style: TextStyle(
                            color: provider.systemActive ? Colors.green : Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // System Decibel Display
                const SizedBox(height: 8),
                DecibelDisplay(
                  decibel: provider.systemDecibel,
                  label: 'System Audio Decibel',
                  isActive: provider.systemActive,
                ),
                // System Audio Data Display
                if (provider.systemActive) ...[
                  const SizedBox(height: 8),
                  Consumer<SettingsProvider>(
                    builder: (context, settings, _) {
                      return AudioDataDisplay(
                        audioStream: provider.systemAudioStream,
                        label: 'System Audio',
                        sampleRate: settings.systemSampleRate,
                        channels: settings.systemChannels,
                      );
                    },
                  ),
                ],
                const SizedBox(height: 24),
                // Info
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Info',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '• You can enable both microphone and system audio simultaneously',
                          style: TextStyle(fontSize: 12),
                        ),
                        const Text(
                          '• Tap the settings icon to configure audio parameters',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Microphone'),
              Tab(text: 'System Audio'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            MicSettingsTab(),
            SystemSettingsTab(),
          ],
        ),
      ),
    );
  }
}

class MicSettingsTab extends StatelessWidget {
  const MicSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final captureProvider = context.read<AudioCaptureProvider>();

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sample Rate (Hz)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: settingsProvider.micSampleRate.toDouble(),
                  min: 8000,
                  max: 48000,
                  divisions: 8,
                  label: '${settingsProvider.micSampleRate} Hz',
                  onChanged: (value) {
                    settingsProvider.setMicSampleRate(value.toInt());
                  },
                ),
                Text('Current: ${settingsProvider.micSampleRate} Hz'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Channels',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: settingsProvider.micChannels.toDouble(),
                  min: 1,
                  max: 2,
                  divisions: 1,
                  label: settingsProvider.micChannels == 1 ? 'Mono' : 'Stereo',
                  onChanged: (value) {
                    settingsProvider.setMicChannels(value.toInt());
                  },
                ),
                Text('Current: ${settingsProvider.micChannels == 1 ? "Mono" : "Stereo"}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Gain Boost',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: settingsProvider.micGainBoost,
                  min: 0.1,
                  max: 10.0,
                  divisions: 99,
                  label: settingsProvider.micGainBoost.toStringAsFixed(1),
                  onChanged: (value) {
                    settingsProvider.setMicGainBoost(value);
                  },
                ),
                Text('Current: ${settingsProvider.micGainBoost.toStringAsFixed(1)}x'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Input Volume',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: settingsProvider.micInputVolume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  label: settingsProvider.micInputVolume.toStringAsFixed(2),
                  onChanged: (value) {
                    settingsProvider.setMicInputVolume(value);
                  },
                ),
                Text('Current: ${(settingsProvider.micInputVolume * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () {
            captureProvider.micCapture.updateConfig(settingsProvider.getMicConfig());
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Mic settings saved')),
            );
          },
          child: const Text('Save Settings'),
        ),
      ],
    );
  }
}

class SystemSettingsTab extends StatelessWidget {
  const SystemSettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final captureProvider = context.read<AudioCaptureProvider>();

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sample Rate (Hz)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: settingsProvider.systemSampleRate.toDouble(),
                  min: 8000,
                  max: 48000,
                  divisions: 8,
                  label: '${settingsProvider.systemSampleRate} Hz',
                  onChanged: (value) {
                    settingsProvider.setSystemSampleRate(value.toInt());
                  },
                ),
                Text('Current: ${settingsProvider.systemSampleRate} Hz'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Channels',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: settingsProvider.systemChannels.toDouble(),
                  min: 1,
                  max: 2,
                  divisions: 1,
                  label: settingsProvider.systemChannels == 1 ? 'Mono' : 'Stereo',
                  onChanged: (value) {
                    settingsProvider.setSystemChannels(value.toInt());
                  },
                ),
                Text('Current: ${settingsProvider.systemChannels == 1 ? "Mono" : "Stereo"}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () {
            captureProvider.systemCapture.updateConfig(settingsProvider.getSystemConfig());
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('System audio settings saved')),
            );
          },
          child: const Text('Save Settings'),
        ),
      ],
    );
  }
}
