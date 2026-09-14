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
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            return true
        }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 27 {
            return true
        }
        #if os(macOS)
        if #available(macOS 13.0, *) {
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

    public init(
        appVersion: String = "1.8.4 (17)",
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
        currentASREngine: String = "Apple Speech"
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
        Generated At: \(Date().formatted())
        ================================
        """
    }
}

// MARK: - Delegate Protocol

@MainActor
public protocol DeviceAudioCaptureDelegate: AnyObject {
    func deviceAudioDidOutput(samples: [Float], level: Float)
    func deviceAudioDidEncounterError(_ error: Error)
    func deviceAudioDidStopBySystem()
}

// MARK: - Device Audio Capture Manager

@MainActor
public final class DeviceAudioCaptureManager: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = DeviceAudioCaptureManager()

    public weak var delegate: DeviceAudioCaptureDelegate?
    @Published public private(set) var isCapturing = false
    @Published public private(set) var diagnostics = DeviceAudioDiagnostics()

    private var activeStream: AnyObject?
    private var streamReceiver: AnyObject?
    private var captureStartTime: Date?

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

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            do {
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 16000
                config.channelCount = 1
                config.queueDepth = 5

                // Minimize video processing
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let shareable = try await SCShareableContent.current
                guard let display = shareable.displays.first else {
                    throw LectureError.message(L10n.tr("找不到可擷取的裝置螢幕或音訊來源。", "No shareable display or audio source found."))
                }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let receiver = SCStreamAudioReceiver()
                receiver.manager = self
                self.streamReceiver = receiver

                let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
                try stream.addStreamOutput(
                    receiver,
                    type: .audio,
                    sampleHandlerQueue: DispatchQueue(label: "com.peijungwu0302.deviceaudio.capture", qos: .userInitiated)
                )

                try await stream.startCapture()
                self.activeStream = stream
                self.isCapturing = true
                self.diagnostics.isCapturing = true
                return
            } catch {
                diagnostics.lastError = error.localizedDescription
                throw error
            }
        }
        #endif

        // Dynamic runtime bridge for iOS 27 when compiled with SDKs prior to iOS 27
        try await startDynamicCapture()
    }

    private func startDynamicCapture() async throws {
        // Attempt dynamic lookup of ScreenCaptureKit classes in iOS 27 runtime
        guard let scStreamClass = NSClassFromString("SCStream") as? NSObject.Type,
              let scConfigClass = NSClassFromString("SCStreamConfiguration") as? NSObject.Type,
              let scContentClass = NSClassFromString("SCShareableContent") as? NSObject.Type,
              let scFilterClass = NSClassFromString("SCContentFilter") as? NSObject.Type else {
            let msg = L10n.tr(
                "本機 iOS 執行階段尚未提供 ScreenCaptureKit 符號（SDK iphoneos26.5 編譯；需要實體 iOS 27 裝置）。",
                "ScreenCaptureKit symbols not found in runtime (built with SDK iphoneos26.5; requires iOS 27 device)."
            )
            diagnostics.lastError = msg
            throw LectureError.message(msg)
        }

        let config = scConfigClass.init()
        config.setValue(true, forKey: "capturesAudio")
        config.setValue(true, forKey: "excludesCurrentProcessAudio")
        config.setValue(16000, forKey: "sampleRate")
        config.setValue(1, forKey: "channelCount")
        config.setValue(5, forKey: "queueDepth")
        config.setValue(2, forKey: "width")
        config.setValue(2, forKey: "height")
        config.setValue(CMTime(value: 1, timescale: 1), forKey: "minimumFrameInterval")

        // Retrieve shareable content asynchronously
        let shareable: AnyObject = try await withCheckedThrowingContinuation { continuation in
            let selector = NSSelectorFromString("getShareableContentWithCompletionHandler:")
            guard scContentClass.responds(to: selector) else {
                continuation.resume(throwing: LectureError.message("SCShareableContent API incompatible"))
                return
            }
            typealias GetShareableFunc = @convention(c) (AnyObject, Selector, @escaping (AnyObject?, Error?) -> Void) -> Void
            let methodIMP = scContentClass.method(for: selector)
            let fn = unsafeBitCast(methodIMP, to: GetShareableFunc.self)
            fn(scContentClass, selector) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: LectureError.message("No shareable content returned"))
                }
            }
        }

        guard let displays = (shareable.value(forKey: "displays") as? [AnyObject]),
              let firstDisplay = displays.first else {
            throw LectureError.message(L10n.tr("找不到可擷取的裝置螢幕或音訊來源。", "No shareable display or audio source found."))
        }

        // Initialize SCContentFilter with display
        let filterInitSelector = NSSelectorFromString("initWithDisplay:excludingApplications:exceptingWindows:")
        guard scFilterClass.instancesRespond(to: filterInitSelector) else {
            throw LectureError.message("SCContentFilter initialization incompatible")
        }
        let filterAlloc = scFilterClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        typealias FilterInitFunc = @convention(c) (AnyObject, Selector, AnyObject, [AnyObject], [AnyObject]) -> AnyObject
        let filterInitIMP = filterAlloc.method(for: filterInitSelector)
        let filterFn = unsafeBitCast(filterInitIMP, to: FilterInitFunc.self)
        let filter = filterFn(filterAlloc, filterInitSelector, firstDisplay, [], [])

        // Receiver delegate
        let receiver = SCStreamAudioReceiver()
        receiver.manager = self
        self.streamReceiver = receiver

        // Initialize SCStream: initWithFilter:configuration:delegate:
        let streamInitSelector = NSSelectorFromString("initWithFilter:configuration:delegate:")
        guard scStreamClass.instancesRespond(to: streamInitSelector) else {
            throw LectureError.message("SCStream initialization incompatible")
        }
        let streamAlloc = scStreamClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        typealias StreamInitFunc = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject) -> AnyObject
        let streamInitIMP = streamAlloc.method(for: streamInitSelector)
        let streamFn = unsafeBitCast(streamInitIMP, to: StreamInitFunc.self)
        let stream = streamFn(streamAlloc, streamInitSelector, filter, config, receiver)

        // Add stream output: addStreamOutput:type:sampleHandlerQueue:error:
        let addOutputSelector = NSSelectorFromString("addStreamOutput:type:sampleHandlerQueue:error:")
        let queue = DispatchQueue(label: "com.peijungwu0302.deviceaudio.capture", qos: .userInitiated)
        typealias AddOutputFunc = @convention(c) (AnyObject, Selector, AnyObject, Int, DispatchQueue, UnsafeMutablePointer<NSError?>?) -> Bool
        let addOutputIMP = (stream as AnyObject).method(for: addOutputSelector)
        let addOutputFn = unsafeBitCast(addOutputIMP, to: AddOutputFunc.self)
        var addError: NSError?
        let addSuccess = addOutputFn(stream, addOutputSelector, receiver, 1 /* audio */, queue, &addError)
        if !addSuccess, let addError {
            throw addError
        }

        // Start capture: startCaptureWithCompletionHandler:
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startCaptureSelector = NSSelectorFromString("startCaptureWithCompletionHandler:")
            typealias StartCaptureFunc = @convention(c) (AnyObject, Selector, @escaping (Error?) -> Void) -> Void
            let startCaptureIMP = (stream as AnyObject).method(for: startCaptureSelector)
            let startFn = unsafeBitCast(startCaptureIMP, to: StartCaptureFunc.self)
            startFn(stream, startCaptureSelector) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        self.activeStream = stream
        self.isCapturing = true
        self.diagnostics.isCapturing = true
    }

    public func stop() async {
        guard isCapturing else { return }

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            if let scStream = activeStream as? SCStream {
                try? await scStream.stopCapture()
            }
        }
        #endif

        if let stream = activeStream {
            let stopSelector = NSSelectorFromString("stopCaptureWithCompletionHandler:")
            if stream.responds(to: stopSelector) {
                typealias StopFunc = @convention(c) (AnyObject, Selector, ((Error?) -> Void)?) -> Void
                let stopIMP = stream.method(for: stopSelector)
                let stopFn = unsafeBitCast(stopIMP, to: StopFunc.self)
                stopFn(stream, stopSelector, nil)
            }
        }

        activeStream = nil
        streamReceiver = nil
        isCapturing = false
        diagnostics.isCapturing = false
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
    }

    fileprivate func handleStreamError(_ error: Error) {
        isCapturing = false
        diagnostics.isCapturing = false
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
private final class SCStreamAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var manager: DeviceAudioCaptureManager?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Discard all video frames immediately
        guard type == .audio else { return }
        processAudioBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.handleStreamError(error)
        }
    }

    @objc(stream:didOutputSampleBuffer:ofType:)
    func dynamicStream(_ stream: AnyObject, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: Int) {
        guard type == 1 else { return } // 1 == audio
        processAudioBuffer(sampleBuffer)
    }

    @objc(stream:didStopWithError:)
    func dynamicStream(_ stream: AnyObject, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.handleStreamError(error)
        }
    }

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

        Task { @MainActor [weak self] in
            guard let manager = self?.manager else { return }
            manager.recordBuffer(sampleRate: inRate, channels: inChannels)
            manager.delegate?.deviceAudioDidOutput(samples: samples, level: level)
        }
    }

    private func extractPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else { return nil }
        guard let format = AVAudioFormat(streamDescription: [asbd]) else { return nil }

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
            flags: kCMSampleBufferFlag_AudioBufferList_AssureOwnership,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

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
#else
private final class SCStreamAudioReceiver: NSObject {
    weak var manager: DeviceAudioCaptureManager?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    @objc(stream:didOutputSampleBuffer:ofType:)
    func dynamicStream(_ stream: AnyObject, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: Int) {
        guard type == 1 else { return } // 1 == audio
        processAudioBuffer(sampleBuffer)
    }

    @objc(stream:didStopWithError:)
    func dynamicStream(_ stream: AnyObject, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.handleStreamError(error)
        }
    }

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

        Task { @MainActor [weak self] in
            guard let manager = self?.manager else { return }
            manager.recordBuffer(sampleRate: inRate, channels: inChannels)
            manager.delegate?.deviceAudioDidOutput(samples: samples, level: level)
        }
    }

    private func extractPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else { return nil }
        guard let format = AVAudioFormat(streamDescription: [asbd]) else { return nil }

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
            flags: kCMSampleBufferFlag_AudioBufferList_AssureOwnership,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

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
