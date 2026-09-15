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
    public static var isNativeLinked: Bool {
        #if canImport(ScreenCaptureKit)
        return true
        #else
        return false
        #endif
    }

    public static var isSupported: Bool {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            return true
        }
        #endif
        return false
    }

    public static var unavailableReason: String {
        #if canImport(ScreenCaptureKit)
        return L10n.tr("裝置聲音需要 iOS/iPadOS 27 或更新版本。", "Device Audio requires iOS/iPadOS 27 or later.")
        #else
        return L10n.tr("目前建置版本未包含 iOS 27 原生 ScreenCaptureKit 支援（Build SDK 太舊，需使用 Xcode 27+）。", "Current build lacks native iOS 27 ScreenCaptureKit support (Build SDK is too old, requires Xcode 27+).")
        #endif
    }
}

// MARK: - Device Audio Diagnostics Model

public struct DeviceAudioDiagnostics: Sendable, Codable {
    public var appVersion: String
    public var osVersion: String
    public var buildSDK: String
    public var isSupported: Bool
    public var isScreenCaptureKitNativeLinked: Bool
    public var captureStatus: String
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

    public static var detectedBuildSDK: String {
        var parts: [String] = []
        if let sdk = Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String {
            parts.append("SDK: \(sdk)")
        }
        if let xcode = Bundle.main.object(forInfoDictionaryKey: "DTXcode") as? String {
            let xcodeBuild = Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String ?? ""
            parts.append("Xcode: \(xcode)\(xcodeBuild.isEmpty ? "" : " (\(xcodeBuild))")")
        }
        if parts.isEmpty {
            #if canImport(ScreenCaptureKit)
            return "iOS 27 SDK / Xcode 27 (Native ScreenCaptureKit)"
            #else
            return "Legacy SDK (Pre-iOS 27)"
            #endif
        }
        return parts.joined(separator: " · ")
    }

    public init(
        appVersion: String = "1.8.5 (18)",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        buildSDK: String = DeviceAudioDiagnostics.detectedBuildSDK,
        isSupported: Bool = DeviceAudioAvailability.isSupported,
        isScreenCaptureKitNativeLinked: Bool = DeviceAudioAvailability.isNativeLinked,
        captureStatus: String = "Idle",
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
        self.buildSDK = buildSDK
        self.isSupported = isSupported
        self.isScreenCaptureKitNativeLinked = isScreenCaptureKitNativeLinked
        self.captureStatus = captureStatus
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
        Build SDK: \(buildSDK)
        Device Audio Supported: \(isSupported ? "YES" : "NO")
        ScreenCaptureKit Native Linked: \(isScreenCaptureKitNativeLinked ? "YES" : "NO")
        Capture Status: \(captureStatus)
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
    private var pickerContinuation: Any?

    private override init() {
        super.init()
        updateEnvironmentDiagnostics()
    }

    public func updateEnvironmentDiagnostics(engine: String? = nil) {
        diagnostics.isSupported = DeviceAudioAvailability.isSupported
        diagnostics.isScreenCaptureKitNativeLinked = DeviceAudioAvailability.isNativeLinked
        diagnostics.buildSDK = DeviceAudioDiagnostics.detectedBuildSDK
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
            diagnostics.lastAudioSourceError = reason
            throw LectureError.message(reason)
        }

        updateEnvironmentDiagnostics()
        captureStartTime = Date()
        diagnostics.totalBuffersReceived = 0
        diagnostics.firstBufferLatency = nil
        diagnostics.lastBufferTimestamp = nil
        diagnostics.droppedBuffers = 0
        diagnostics.lastError = nil
        diagnostics.lastAudioSourceError = nil

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
            do {
                try await startNativeCapture()
                return
            } catch {
                diagnostics.lastError = error.localizedDescription
                diagnostics.lastAudioSourceError = error.localizedDescription
                isCapturing = false
                diagnostics.isCapturing = false
                diagnostics.captureStatus = "Error"
                throw error
            }
        }
        #endif

        let reason = DeviceAudioAvailability.unavailableReason
        diagnostics.lastError = reason
        diagnostics.lastAudioSourceError = reason
        throw LectureError.message(reason)
    }

    #if canImport(ScreenCaptureKit)
    @available(iOS 27.0, iPadOS 27.0, macOS 15.0, *)
    private func createStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1

        #if os(macOS)
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        #endif

        // Minimize video processing
        config.width = 2
        config.height = 2
        return config
    }

    @available(iOS 27.0, iPadOS 27.0, macOS 15.0, *)
    private func startNativeCapture() async throws {
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true

        let config = createStreamConfiguration()

        #if os(macOS)
        // macOS allows direct filter inspection if screen recording permission is already granted
        var directFilter: SCContentFilter?
        do {
            let shareable = try await SCShareableContent.current
            if let display = shareable.displays.first {
                directFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }
        } catch {
            // Fall back to picker
        }

        if let filter = directFilter {
            do {
                try await beginStreamCapture(filter: filter, config: config)
                return
            } catch {
                // Direct start failed, fall back to picker presentation
            }
        }
        #endif

        // iOS 27+ / macOS fallback: content capture is driven by SCContentSharingPicker
        diagnostics.captureStatus = "Waiting for picker"
        let chosenFilter: SCContentFilter = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCContentFilter, Error>) in
            self.pickerContinuation = continuation
            picker.present()
        }

        try await beginStreamCapture(filter: chosenFilter, config: config)
    }

    @available(iOS 27.0, iPadOS 27.0, macOS 15.0, *)
    private func beginStreamCapture(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
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
        self.diagnostics.captureStatus = "Capturing"
    }
    #endif

    public func stop() async {
        guard isCapturing || pickerContinuation != nil else { return }

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 14.0, *) {
            if let continuation = pickerContinuation as? CheckedContinuation<SCContentFilter, Error> {
                pickerContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
            if let scStream = activeStream as? SCStream {
                try? await scStream.stopCapture()
            }
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
        }
        #endif

        activeStream = nil
        streamReceiver = nil
        isCapturing = false
        diagnostics.isCapturing = false
        diagnostics.captureStatus = "Idle"
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

    fileprivate func recordDroppedBuffer() {
        diagnostics.droppedBuffers += 1
    }

    fileprivate func handleStreamError(_ error: Error) {
        isCapturing = false
        diagnostics.isCapturing = false
        diagnostics.captureStatus = "Error"
        diagnostics.lastError = error.localizedDescription
        diagnostics.lastAudioSourceError = error.localizedDescription
        activeStream = nil
        streamReceiver = nil
        delegate?.deviceAudioDidEncounterError(error)
    }

    fileprivate func handleStreamStopped() {
        isCapturing = false
        diagnostics.isCapturing = false
        diagnostics.captureStatus = "Stopped by system"
        activeStream = nil
        streamReceiver = nil
        delegate?.deviceAudioDidStopBySystem()
    }
}

// MARK: - ScreenCaptureKit Picker Observer

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, iPadOS 27.0, macOS 14.0, *)
extension DeviceAudioCaptureManager: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let continuation = self.pickerContinuation as? CheckedContinuation<SCContentFilter, Error> {
                self.pickerContinuation = nil
                continuation.resume(returning: filter)
            } else {
                #if os(macOS)
                if let activeStream = self.activeStream as? SCStream {
                    try? await activeStream.updateContentFilter(filter)
                }
                #else
                if self.isCapturing {
                    if let activeStream = self.activeStream as? SCStream {
                        try? await activeStream.stopCapture()
                    }
                    let config = self.createStreamConfiguration()
                    try? await self.beginStreamCapture(filter: filter, config: config)
                }
                #endif
            }
        }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let continuation = self.pickerContinuation as? CheckedContinuation<SCContentFilter, Error> {
                self.pickerContinuation = nil
                continuation.resume(throwing: LectureError.message(L10n.tr("已取消分享內容選取。", "Content sharing selection canceled.")))
            }
        }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let continuation = self.pickerContinuation as? CheckedContinuation<SCContentFilter, Error> {
                self.pickerContinuation = nil
                continuation.resume(throwing: error)
            } else {
                self.handleStreamError(error)
            }
        }
    }
}

// MARK: - Stream Audio Receiver

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

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = extractPCMBuffer(from: sampleBuffer) else {
            Task { @MainActor [weak self] in
                self?.manager?.recordDroppedBuffer()
            }
            return
        }
        let inRate = pcmBuffer.format.sampleRate
        let inChannels = Int(pcmBuffer.format.channelCount)

        guard let convertedBuffer = convertToTarget(pcmBuffer) else {
            Task { @MainActor [weak self] in
                self?.manager?.recordDroppedBuffer()
            }
            return
        }
        guard let channelData = convertedBuffer.floatChannelData?[0], convertedBuffer.frameLength > 0 else {
            Task { @MainActor [weak self] in
                self?.manager?.recordDroppedBuffer()
            }
            return
        }

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
        var bufferListSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        let bufferSize = max(bufferListSizeNeeded, MemoryLayout<AudioBufferList>.size)
        let bufferListMemory = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListMemory.deallocate() }
        let bufferListPtr = bufferListMemory.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPtr,
            bufferListSize: bufferSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_AssureOwnership,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        let srcList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        let dstList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for (src, dst) in zip(srcList, dstList) {
            if let srcData = src.mData, let dstData = dst.mData {
                memcpy(dstData, srcData, min(Int(src.mDataByteSize), Int(dst.mDataByteSize)))
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
