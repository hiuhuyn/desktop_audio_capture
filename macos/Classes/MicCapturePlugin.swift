import Cocoa
import FlutterMacOS
import AVFoundation

class MicCapturePlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isCapturing = false
    
    // Audio format configuration (defaults, can be overridden by config)
    private var sampleRate: Double = 16000.0
    private var channels: UInt32 = 1
    private var bitDepth: UInt32 = 16
    
    // Gain boost to increase microphone sensitivity (default: 2.5)
    private var gainBoost: Float = 2.5
    
    // Input volume (default: 1.0)
    private var inputVolume: Float = 1.0
    
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MicCapturePlugin()
        
        let methodChannel = FlutterMethodChannel(
            name: "com.mic_audio_transcriber/mic_capture",
            binaryMessenger: registrar.messenger
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        
        let eventChannel = FlutterEventChannel(
            name: "com.mic_audio_transcriber/mic_stream",
            binaryMessenger: registrar.messenger
        )
        instance.eventChannel = eventChannel
        eventChannel.setStreamHandler(instance)
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(true)
            
        case "requestPermissions":
            requestPermissions(result: result)
            
        case "startCapture":
            if let args = call.arguments as? [String: Any] {
                startCapture(config: args, result: result)
            } else {
                startCapture(config: nil, result: result)
            }
            
        case "stopCapture":
            stopCapture(result: result)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func requestPermissions(result: @escaping FlutterResult) {
        // On macOS, microphone permission is handled by the system
        // macOS will prompt automatically when we try to access the microphone
        // We can't check permission directly, so we return true and let
        // the system handle the permission prompt when startCapture is called
        result(true)
    }
    
    private func startCapture(config: [String: Any]?, result: @escaping FlutterResult) {
        guard !isCapturing else {
            print("Already capturing")
            result(false)
            return
        }
        
        // Parse configuration from Flutter
        if let config = config {
            if let sampleRateValue = config["sampleRate"] as? NSNumber {
                sampleRate = sampleRateValue.doubleValue
            }
            if let channelsValue = config["channels"] as? NSNumber {
                channels = channelsValue.uint32Value
            }
            if let bitDepthValue = config["bitDepth"] as? NSNumber {
                bitDepth = bitDepthValue.uint32Value
            }
            if let gainBoostValue = config["gainBoost"] as? NSNumber {
                gainBoost = gainBoostValue.floatValue
                // Clamp gain boost to reasonable range (0.1 to 10.0)
                gainBoost = max(0.1, min(10.0, gainBoost))
            }
            if let inputVolumeValue = config["inputVolume"] as? NSNumber {
                inputVolume = inputVolumeValue.floatValue
                // Clamp input volume to valid range (0.0 to 1.0)
                inputVolume = max(0.0, min(1.0, inputVolume))
            }
        }
        
        do {
            // Create audio engine
            let engine = AVAudioEngine()
            inputNode = engine.inputNode
            
            // Set input volume from config
            inputNode!.volume = inputVolume
            
            // Get input format
            let inputFormat = inputNode!.outputFormat(forBus: 0)
            print("🎤 Input Format:")
            print("  Sample Rate: \(inputFormat.sampleRate) Hz")
            print("  Channels: \(inputFormat.channelCount)")
            print("  Output Sample Rate: \(sampleRate) Hz")
            print("  Output Channels: \(channels)")
            print("  Gain Boost: \(gainBoost)x")
            print("  Input Volume: \(inputVolume)")
            
            // Create output format (16kHz, mono, 16-bit PCM)
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            ) else {
                print("Failed to create output format")
                result(false)
                return
            }
            
            // Install tap on input node
            // Note: installTap will fail if a tap already exists, so we ensure
            // cleanup is done properly in stopCapture to prevent duplicate taps
            let bufferSize: AVAudioFrameCount = 4096
            inputNode!.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
                self?.processAudioBuffer(buffer, outputFormat: outputFormat)
            }
            
            // Start audio engine
            try engine.start()
            
            audioEngine = engine
            isCapturing = true
            print("✅ Microphone capture started successfully!")
            result(true)
            
        } catch {
            print("❌ Error starting microphone capture: \(error)")
            // Clean up on error
            audioEngine = nil
            inputNode = nil
            isCapturing = false
            result(false)
        }
    }
    
    private func stopCapture(result: @escaping FlutterResult) {
        guard isCapturing, let engine = audioEngine, let input = inputNode else {
            result(false)
            return
        }
        
        do {
            // Remove tap
            input.removeTap(onBus: 0)
            
            // Stop engine
            engine.stop()
            
            // Clean up
            audioEngine = nil
            inputNode = nil
            isCapturing = false
            
            print("✅ Microphone capture stopped")
            result(true)
            
        } catch {
            print("Error stopping microphone capture: \(error.localizedDescription)")
            // Still clean up even on error
            audioEngine = nil
            inputNode = nil
            isCapturing = false
            result(false)
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let eventSink = eventSink else { return }
        
        // Convert buffer to target format if needed
        guard let convertedBuffer = convertBuffer(buffer, to: outputFormat) else {
            return
        }
        
        // Extract PCM data
        guard let audioData = extractPCMData(from: convertedBuffer) else {
            return
        }
        
        // Send to Flutter via event channel
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(FlutterStandardTypedData(bytes: audioData))
        }
    }
    
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // If formats match, return as is
        if buffer.format.isEqual(format) {
            return buffer
        }
        
        // Create converter
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }
        
        // Calculate output buffer size
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            return nil
        }
        
        // Convert
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            print("⚠️ Conversion error: \(error)")
            return nil
        }
        
        return outputBuffer
    }
    
    private func extractPCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let int16ChannelData = buffer.int16ChannelData else {
            return nil
        }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        // Apply gain boost and convert to mono if needed
        var monoData = Data(capacity: frameLength * MemoryLayout<Int16>.size)
        let maxValue: Float = 32767.0
        let minValue: Float = -32768.0
        
        if channelCount == 1 {
            // Mono: apply gain boost
            let channel = int16ChannelData.pointee
            for i in 0..<frameLength {
                let sample = Float(channel[i]) * gainBoost
                // Clamp to prevent clipping
                let clamped = max(minValue, min(maxValue, sample))
                let boosted = Int16(clamped)
                withUnsafeBytes(of: boosted) { monoData.append(contentsOf: $0) }
            }
        } else {
            // Stereo: convert to mono and apply gain boost
            let leftChannel = int16ChannelData.pointee
            let rightChannel = int16ChannelData.advanced(by: 1).pointee
            
            for i in 0..<frameLength {
                let left = Float(leftChannel[i])
                let right = Float(rightChannel[i])
                // Average channels then apply gain boost
                let mono = (left + right) / 2.0 * gainBoost
                // Clamp to prevent clipping
                let clamped = max(minValue, min(maxValue, mono))
                let boosted = Int16(clamped)
                withUnsafeBytes(of: boosted) { monoData.append(contentsOf: $0) }
            }
        }
        
        return monoData
    }
}

// MARK: - FlutterStreamHandler
extension MicCapturePlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

