import Foundation
import CoreMedia
import AVFoundation
import UIKit
import Combine
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// MARK: - Audio Source & Storage Mode Enums

public enum AudioInputSource: String, CaseIterable, Identifiable, Codable {
    case microphone = "microphone"
    case deviceAudio = "deviceAudio"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: return L10n.tr("麥克風", "Microphone")
        case .deviceAudio: return L10n.tr("裝置聲音", "Device Audio")
        }
    }
}

public enum SessionStorageMode: String, CaseIterable, Identifiable, Codable {
    case liveOnly = "liveOnly"
    case saveTranscript = "saveTranscript"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .liveOnly: return L10n.tr("僅即時顯示（不存檔）", "Live Only")
        case .saveTranscript: return L10n.tr("保留逐字稿文字", "Save Transcript")
        }
    }
}

// MARK: - Device Audio Availability

public struct DeviceAudioAvailability {
    public static var isSupported: Bool {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            return true
        }
        #endif
        #if targetEnvironment(simulator)
        if #available(iOS 27.0, iPadOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    public static var unavailableReason: String {
        L10n.tr("裝置聲音需要 iOS/iPadOS 27 或更新版本。", "Device Audio requires iOS/iPadOS 27 or later.")
    }
}

// MARK: - Device Audio Diagnostics Model

public struct DeviceAudioDiagnostics: Sendable, Codable {
    public var appVersion: String
    public var osVersion: String
    public var isSupported: Bool
    public var isCapturing: Bool
    public var totalBuffersReceived: Int
    public var firstBufferLatency: Double?
    public var sampleRate: Double
    public var channelCount: Int
    public var targetPCMFormat: String
    public var lastBufferTimestamp: Date?
    public var droppedBuffers: Int
    public var lastError: String?
    public var lastAudioSourceError: String?
    public var currentASREngine: String
    public var audioSessionEvents: [String]

    public init(
        appVersion: String = "1.9.2 (21)",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        isSupported: Bool = DeviceAudioAvailability.isSupported,
        isCapturing: Bool = false,
        totalBuffersReceived: Int = 0,
        firstBufferLatency: Double? = nil,
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        targetPCMFormat: String = "PCM Float32, 16000 Hz, 1 channel, non-interleaved",
        lastBufferTimestamp: Date? = nil,
        droppedBuffers: Int = 0,
        lastError: String? = nil,
        lastAudioSourceError: String? = nil,
        currentASREngine: String = "Apple Speech",
        audioSessionEvents: [String] = []
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.isSupported = isSupported
        self.isCapturing = isCapturing
        self.totalBuffersReceived = totalBuffersReceived
        self.firstBufferLatency = firstBufferLatency
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.targetPCMFormat = targetPCMFormat
        self.lastBufferTimestamp = lastBufferTimestamp
        self.droppedBuffers = droppedBuffers
        self.lastError = lastError
        self.lastAudioSourceError = lastAudioSourceError
        self.currentASREngine = currentASREngine
        self.audioSessionEvents = audioSessionEvents
    }

    public var audioBuffersReceiving: Bool {
        guard let last = lastBufferTimestamp else { return false }
        return isCapturing && Date().timeIntervalSince(last) < 3.0
    }

    public var firstBufferLatencyText: String {
        guard let latency = firstBufferLatency else { return L10n.tr("尚未測得", "Pending / None") }
        return String(format: "%.3f s", latency)
    }

    public var lastBufferAgeText: String {
        guard let last = lastBufferTimestamp else { return L10n.tr("無", "None") }
        let age = Date().timeIntervalSince(last)
        return String(format: "%.1f s", age)
    }

    public func formattedSummary() -> String {
        """
        === Device Audio Diagnostics ===
        App Version: \(appVersion)
        OS Version: \(osVersion)
        Device Audio Supported: \(isSupported ? "YES" : "NO")
        Capture Status: \(isCapturing ? "Capturing" : "Idle")
        Audio Buffers Receiving: \(audioBuffersReceiving ? "YES" : "NO")
        Total Buffers Received: \(totalBuffersReceived)
        First Buffer Latency: \(firstBufferLatencyText)
        Sample Rate: \(Int(sampleRate)) Hz
        Channel Count: \(channelCount)
        Target Format: \(targetPCMFormat)
        Last Buffer Age: \(lastBufferAgeText)
        Dropped Buffers: \(droppedBuffers)
        Current ASR Engine: \(currentASREngine)
        Last Error: \(lastError ?? "None")
        Last Audio Error: \(lastAudioSourceError ?? "None")
        Audio Session Events:\n\(audioSessionEvents.suffix(12).joined(separator: "\n"))
        Generated At: \(Date().formatted())
        ================================
        """
    }
}

// MARK: - Timed Audio Chunk

public struct TimedAudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int
    public let level: Float
    public let startMediaTime: Double
    public let endMediaTime: Double
    public let startSampleIndex: Int
    public let endSampleIndex: Int
    public let sourcePTS: Double

    public var pts: Double { startMediaTime }
    public var duration: Double { max(0.0, endMediaTime - startMediaTime) }

    public init(
        samples: [Float],
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        level: Float = 0,
        startMediaTime: Double = 0,
        endMediaTime: Double = 0,
        startSampleIndex: Int = 0,
        endSampleIndex: Int = 0,
        sourcePTS: Double = 0
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.level = level
        self.startMediaTime = startMediaTime
        self.endMediaTime = endMediaTime
        self.startSampleIndex = startSampleIndex
        self.endSampleIndex = endSampleIndex
        self.sourcePTS = sourcePTS
    }

    public init(
        samples: [Float],
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        level: Float = 0,
        pts: Double = 0,
        startSampleIndex: Int = 0,
        endSampleIndex: Int = 0
    ) {
        let dur = Double(samples.count) / max(1.0, sampleRate)
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.level = level
        self.startMediaTime = pts
        self.endMediaTime = pts + dur
        self.startSampleIndex = startSampleIndex
        self.endSampleIndex = endSampleIndex
        self.sourcePTS = pts
    }
}

// MARK: - Delegate Protocol

@MainActor
public protocol DeviceAudioCaptureDelegate: AnyObject {
    func deviceAudioDidOutput(samples: [Float], level: Float)
    func deviceAudioDidOutput(chunk: TimedAudioChunk)
    func deviceAudioDidEncounterError(_ error: Error)
    func deviceAudioDidStopBySystem()
}

public extension DeviceAudioCaptureDelegate {
    func deviceAudioDidOutput(chunk: TimedAudioChunk) {
        deviceAudioDidOutput(samples: chunk.samples, level: chunk.level)
    }
    func deviceAudioDidOutput(samples: [Float], level: Float) {}
}

// MARK: - Device Audio Capture Manager

@MainActor
public final class DeviceAudioCaptureManager: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = DeviceAudioCaptureManager()

    public weak var delegate: DeviceAudioCaptureDelegate?
    @Published public private(set) var isCapturing = false
    @Published public private(set) var diagnostics = DeviceAudioDiagnostics()
    @Published public private(set) var isProbeActive = false

    fileprivate var activeStream: AnyObject?
    fileprivate var streamReceiver: AnyObject?
    private var captureStartTime: Date?
    private var recordedFirstBufferSession = false

    private override init() {
        super.init()
        updateEnvironmentDiagnostics()
    }

    public func updateEnvironmentDiagnostics(engine: String? = nil) {
        diagnostics.isSupported = DeviceAudioAvailability.isSupported
        diagnostics.isCapturing = isCapturing
        diagnostics.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        if let shortVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let buildVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            diagnostics.appVersion = "\(shortVer) (\(buildVer))"
        }
        if let engine {
            diagnostics.currentASREngine = engine
        }
    }

    @discardableResult
    public func copyDiagnostics() -> String {
        updateEnvironmentDiagnostics()
        let summary = diagnostics.formattedSummary()
        UIPasteboard.general.string = summary
        return summary
    }

    public func start() async throws {
        guard !isCapturing else { return }

        guard DeviceAudioAvailability.isSupported else {
            let reason = DeviceAudioAvailability.unavailableReason
            diagnostics.lastError = reason
            throw LectureError.message(reason)
        }

        updateEnvironmentDiagnostics()
        captureStartTime = Date()
        diagnostics.totalBuffersReceived = 0
        diagnostics.firstBufferLatency = nil
        diagnostics.lastBufferTimestamp = nil
        diagnostics.lastError = nil
        diagnostics.audioSessionEvents = []
        recordedFirstBufferSession = false
        recordAudioSessionEvent("before SCContentSharingPicker")
        // Device Audio capture does not need an app-owned playback/record session.
        // Release any session left active by microphone or local playback before
        // invoking ScreenCaptureKit so LectureTranscriber cannot duck the source.
        AudioSessionCoordinator.shared.activateDeviceAudioCapture()
        recordAudioSessionEvent("after releasing app audio session")

        #if targetEnvironment(simulator)
        throw LectureError.message(L10n.tr("模擬器環境不支援裝置聲音擷取，請使用實體 iOS 27 裝置。", "Device Audio is not supported on Simulator. Please test on a real iOS 27 device."))
        #endif

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            let receiver = SCStreamAudioReceiver()
            receiver.manager = self
            self.streamReceiver = receiver

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                receiver.startContinuation = continuation
                let picker = SCContentSharingPicker.shared
                var pickerConfig = SCContentSharingPickerConfiguration()
                #if os(iOS) || os(visionOS)
                pickerConfig.showsMicrophoneControl = false
                #endif
                picker.defaultConfiguration = pickerConfig
                picker.add(receiver)
                picker.isActive = true
                picker.present()
            }
            return
        }
        #endif

        throw LectureError.message(DeviceAudioAvailability.unavailableReason)
    }

    public func stop() async {
        guard isCapturing || streamReceiver != nil else { return }

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            if let scStream = activeStream as? SCStream {
                try? await scStream.stopCapture()
            }
            if let receiver = streamReceiver as? SCStreamAudioReceiver {
                receiver.startContinuation?.resume(throwing: CancellationError())
                receiver.startContinuation = nil
                SCContentSharingPicker.shared.remove(receiver)
            }
        }
        #endif

        recordAudioSessionEvent("capture stop")
        AudioSessionCoordinator.shared.deactivateDeviceAudioCapture()
        activeStream = nil
        streamReceiver = nil
        isCapturing = false
        diagnostics.isCapturing = false
    }

    fileprivate func markCaptureStarted(stream: AnyObject) {
        activeStream = stream
        isCapturing = true
        diagnostics.isCapturing = true
        recordAudioSessionEvent("after SCStream.startCapture")
    }

    fileprivate func recordBuffer(sampleRate: Double, channels: Int) {
        diagnostics.totalBuffersReceived += 1
        diagnostics.sampleRate = sampleRate
        diagnostics.channelCount = channels
        let now = Date()
        diagnostics.lastBufferTimestamp = now
        if diagnostics.firstBufferLatency == nil, let start = captureStartTime {
            diagnostics.firstBufferLatency = now.timeIntervalSince(start)
        }
        if !recordedFirstBufferSession {
            recordedFirstBufferSession = true
            recordAudioSessionEvent("first audio buffer")
        }
    }

    public func startCaptureProbe() async throws {
        delegate = nil
        isProbeActive = true
        do { try await start() }
        catch { isProbeActive = false; throw error }
    }

    public func stopCaptureProbe() async {
        await stop()
        isProbeActive = false
    }

    func recordAudioSessionEvent(_ label: String) {
        let audio = AVAudioSession.sharedInstance()
        let inputs = audio.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = audio.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let options = String(describing: audio.categoryOptions)
        let entry = "[\(label)] category=\(audio.category.rawValue) mode=\(audio.mode.rawValue) options=\(options) route=in[\(inputs)] out[\(outputs)] sampleRate=\(audio.sampleRate) outputVolume=\(audio.outputVolume) secondarySilenced=\(audio.secondaryAudioShouldBeSilencedHint)"
        diagnostics.audioSessionEvents.append(entry)
        print("DeviceAudioAudioSession \(entry)")
    }

    fileprivate func handleStreamError(_ error: Error) {
        isCapturing = false
        diagnostics.isCapturing = false
        isProbeActive = false
        diagnostics.lastError = error.localizedDescription
        activeStream = nil
        streamReceiver = nil
        delegate?.deviceAudioDidEncounterError(error)
    }

    fileprivate func handleStreamStopped() {
        isCapturing = false
        diagnostics.isCapturing = false
        activeStream = nil
        streamReceiver = nil
        delegate?.deviceAudioDidStopBySystem()
    }
}

// MARK: - Stream Audio Receiver

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, iPadOS 27.0, macOS 15.0, *)
private final class SCStreamAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, @unchecked Sendable {
    weak var manager: DeviceAudioCaptureManager?
    var startContinuation: CheckedContinuation<Void, Error>?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // MARK: - SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.manager?.recordAudioSessionEvent("after picker selection")
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 16000
                config.channelCount = 1
                config.width = 2
                config.height = 2

                if let oldStream = self.manager?.activeStream as? SCStream {
                    try? await oldStream.stopCapture()
                }

                let scStream = SCStream(filter: filter, configuration: config, delegate: self)
                try scStream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: DispatchQueue(label: "com.peijungwu0302.deviceaudio.capture", qos: .userInitiated)
                )

                try await scStream.startCapture()
                guard let manager = self.manager else {
                    try? await scStream.stopCapture()
                    return
                }
                manager.markCaptureStarted(stream: scStream)
                self.startContinuation?.resume(returning: ())
                self.startContinuation = nil
            } catch {
                self.startContinuation?.resume(throwing: error)
                self.startContinuation = nil
                self.manager?.handleStreamError(error)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            let err = LectureError.message(L10n.tr("已取消選取音訊來源。", "Audio source selection cancelled."))
            self?.startContinuation?.resume(throwing: err)
            self?.startContinuation = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.startContinuation?.resume(throwing: error)
            self?.startContinuation = nil
            self?.manager?.handleStreamError(error)
        }
    }

    // MARK: - SCStreamOutput & SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Discard all video frames immediately
        guard type == .audio else { return }
        processAudioBuffer(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.handleStreamError(error)
        }
    }

    private var sampleCounter: Int = 0

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = extractPCMBuffer(from: sampleBuffer) else { return }
        let inRate = pcmBuffer.format.sampleRate
        let inChannels = Int(pcmBuffer.format.channelCount)

        guard let convertedBuffer = convertToTarget(pcmBuffer) else { return }
        guard let channelData = convertedBuffer.floatChannelData?[0], convertedBuffer.frameLength > 0 else { return }

        let length = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: length))

        // Calculate audio power level
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, length))
        let level = min(1, max(0, (20 * log10(max(sqrt(power), 0.00001)) + 60) / 60))

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSeconds = pts.isValid ? CMTimeGetSeconds(pts) : 0.0

        let startSample = sampleCounter
        sampleCounter += length
        let endSample = sampleCounter
        let startMediaTime = Double(startSample) / 16000.0
        let endMediaTime = Double(endSample) / 16000.0

        let chunk = TimedAudioChunk(
            samples: samples,
            sampleRate: 16000,
            channelCount: 1,
            level: level,
            startMediaTime: startMediaTime,
            endMediaTime: endMediaTime,
            startSampleIndex: startSample,
            endSampleIndex: endSample,
            sourcePTS: ptsSeconds
        )

        Task { @MainActor [weak self] in
            guard let manager = self?.manager, manager.isCapturing else { return }
            manager.recordBuffer(sampleRate: inRate, channels: inChannels)
            manager.delegate?.deviceAudioDidOutput(chunk: chunk)
        }
    }

    private func extractPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList()
        var bufferListSizeNeeded = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        for i in 0..<Int(bufferList.mNumberBuffers) {
            let src = bufferList.mBuffers.mData
            let size = bufferList.mBuffers.mDataByteSize
            if let dst = pcmBuffer.mutableAudioBufferList.pointee.mBuffers.mData, let src {
                memcpy(dst, src, Int(size))
            }
        }
        return pcmBuffer
    }

    private func convertToTarget(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputBuffer.format == targetFormat {
            return inputBuffer
        }

        if converter == nil || converter?.inputFormat != inputBuffer.format {
            converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = 16000.0 / inputBuffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { return nil }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
#endif
