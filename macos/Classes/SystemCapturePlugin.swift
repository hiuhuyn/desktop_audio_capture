import Cocoa
import FlutterMacOS
import AVFoundation
import ScreenCaptureKit

@available(macOS 12.3, *)
class SystemCapturePlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var isCapturing = false

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SystemCapturePlugin()

        let methodChannel = FlutterMethodChannel(
            name: "com.system_audio_transcriber/audio_capture",
            binaryMessenger: registrar.messenger
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: "com.system_audio_transcriber/audio_stream",
            binaryMessenger: registrar.messenger
        )
        instance.eventChannel = eventChannel
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            if #available(macOS 12.3, *) {
                result(true)
            } else {
                result(false)
            }

        case "requestPermissions":
            requestPermissions(result: result)

        case "startCapture":
            Task {
                await startCapture(result: result)
            }

        case "stopCapture":
            Task {
                await stopCapture(result: result)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func requestPermissions(result: @escaping FlutterResult) {
        // Check if we already have permission
        let hasPermission = CGPreflightScreenCaptureAccess()

        if hasPermission {
            result(true)
            return
        }

        // Request permission - this will show system dialog
        // Note: This only works ONCE. If user denies, they must go to System Settings manually
        let granted = CGRequestScreenCaptureAccess()

        if granted {
            result(true)
        } else {
            // Permission denied or dialog shown - user needs to go to System Settings
            DispatchQueue.main.async {
                self.showPermissionAlert()
            }
            result(false)
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        This app needs Screen Recording permission to capture system audio.

        Please follow these steps:
        1. Click "Open System Settings" below
        2. In Privacy & Security → Screen Recording
        3. Enable the toggle for this app
        4. Restart the app
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Settings to Screen Recording
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @available(macOS 12.3, *)
    private func startCapture(result: @escaping FlutterResult) async {
        guard !isCapturing else {
            print("Already capturing")
            result(false)
            return
        }

        // Check permission first
        let hasPermission = CGPreflightScreenCaptureAccess()
        if !hasPermission {
            print("No screen recording permission - please grant permission first")
            DispatchQueue.main.async {
                self.showPermissionAlert()
            }
            result(false)
            return
        }

        do {
            print("Getting shareable content...")
            // Get available content (displays and applications)
            let availableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let display = availableContent.displays.first else {
                print("No display found")
                result(false)
                return
            }

            print("Configuring stream for display: \(display.displayID)")
            // Configure stream to capture system audio
            let configuration = SCStreamConfiguration()

            // Audio settings
            configuration.capturesAudio = true
            configuration.sampleRate = 16000 // 16kHz for speech recognition
            configuration.channelCount = 1   // Mono
            configuration.excludesCurrentProcessAudio = true // Don't capture our app's audio

            // Video settings - ScreenCaptureKit requires video to be enabled for audio
            // We set minimal resolution to reduce overhead
            configuration.width = 100
            configuration.height = 100
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
            configuration.queueDepth = 3

            // Pixel format
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            // Don't show cursor in capture
            configuration.showsCursor = false

            // Create content filter to capture entire display
            let filter = SCContentFilter(display: display, excludingWindows: [])

            // Create stream output handler
            streamOutput = StreamOutput(eventSink: eventSink)

            print("Creating stream...")
            // Create and start stream
            stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

            if let stream = stream, let streamOutput = streamOutput {
                print("Adding stream output...")
                try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: .main)

                print("Starting capture...")
                try await stream.startCapture()

                isCapturing = true
                print("✅ Capture started successfully!")
                result(true)
            } else {
                print("Failed to create stream or stream output")
                result(false)
            }

        } catch {
            print("❌ Error starting capture: \(error)")
            if let nsError = error as NSError? {
                print("Error domain: \(nsError.domain), code: \(nsError.code)")
                print("Error info: \(nsError.userInfo)")
            }
            result(false)
        }
    }

    @available(macOS 12.3, *)
    private func stopCapture(result: @escaping FlutterResult) async {
        guard isCapturing, let stream = stream else {
            result(false)
            return
        }

        do {
            // Remove stream output first to prevent frame drops
            if let streamOutput = streamOutput {
                try stream.removeStreamOutput(streamOutput, type: .audio)
            }

            // Stop the stream
            try await stream.stopCapture()
            
            // Clean up after stream is stopped
            self.stream = nil
            self.streamOutput = nil
            isCapturing = false
            result(true)
        } catch {
            print("Error stopping capture: \(error.localizedDescription)")
            // Still clean up even on error
            self.stream = nil
            self.streamOutput = nil
            isCapturing = false
            result(false)
        }
    }
}

// MARK: - FlutterStreamHandler
@available(macOS 12.3, *)
extension SystemCapturePlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        streamOutput?.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        streamOutput?.eventSink = nil
        return nil
    }
}

// MARK: - Stream Output Handler
@available(macOS 12.3, *)
class StreamOutput: NSObject, SCStreamOutput {
    var eventSink: FlutterEventSink?
    private static var hasLoggedFormat = false

    init(eventSink: FlutterEventSink?) {
        self.eventSink = eventSink
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to PCM data
        if let audioData = extractAudioData(from: sampleBuffer) {
            // Send audio data to Flutter via event channel
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(FlutterStandardTypedData(bytes: audioData))
            }
        }
    }

    private func extractAudioData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        // Get audio format description
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        guard let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        // Log audio format (only once)
        if !StreamOutput.hasLoggedFormat {
            StreamOutput.hasLoggedFormat = true
            let desc = audioStreamBasicDescription.pointee
            print("🎤 Audio Format:")
            print("  Sample Rate: \(desc.mSampleRate) Hz")
            print("  Channels: \(desc.mChannelsPerFrame)")
            print("  Bits/Channel: \(desc.mBitsPerChannel)")
            print("  Format ID: \(desc.mFormatID)")
            print("  Format Flags: \(desc.mFormatFlags)")
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            return nil
        }

        // Check if audio is Float32 (common for ScreenCaptureKit)
        if audioStreamBasicDescription.pointee.mFormatID == kAudioFormatLinearPCM &&
           audioStreamBasicDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Convert Float32 to Int16 (LINEAR16)
            let floatPointer = pointer.withMemoryRebound(to: Float32.self, capacity: length / MemoryLayout<Float32>.size) { $0 }
            let sampleCount = length / MemoryLayout<Float32>.size

            var int16Data = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
            for i in 0..<sampleCount {
                // Clamp to [-1.0, 1.0] and convert to Int16 range [-32768, 32767]
                let sample = min(max(floatPointer[i], -1.0), 1.0)
                let int16Sample = Int16(sample * 32767.0)
                withUnsafeBytes(of: int16Sample) { int16Data.append(contentsOf: $0) }
            }

            return int16Data
        } else if audioStreamBasicDescription.pointee.mFormatID == kAudioFormatLinearPCM &&
                  audioStreamBasicDescription.pointee.mBitsPerChannel == 16 {
            // Already Int16, return as is
            return Data(bytes: pointer, count: length)
        }

        // Unknown format
        print("⚠️ Unknown audio format: \(audioStreamBasicDescription.pointee.mFormatID)")
        return nil
    }
}
