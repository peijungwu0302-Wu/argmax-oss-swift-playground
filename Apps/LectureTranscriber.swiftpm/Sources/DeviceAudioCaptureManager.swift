import Foundation
import CoreMedia
import AVFoundation
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
        return false
    }

    public static var unavailableReason: String {
        L10n.tr("裝置聲音需要 iOS/iPadOS 27 或更新版本。", "Device Audio requires iOS/iPadOS 27 or later.")
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
public final class DeviceAudioCaptureManager: NSObject, @unchecked Sendable {
    public static let shared = DeviceAudioCaptureManager()

    public weak var delegate: DeviceAudioCaptureDelegate?
    @Published public private(set) var isCapturing = false

    private var activeStream: AnyObject?
    private var streamReceiver: AnyObject?

    private override init() {
        super.init()
    }

    public func start() async throws {
        guard !isCapturing else { return }

        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, iPadOS 27.0, macOS 15.0, *) {
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
            return
        }
        #endif

        throw LectureError.message(DeviceAudioAvailability.unavailableReason)
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
        activeStream = nil
        streamReceiver = nil
        isCapturing = false
    }

    fileprivate func handleStreamError(_ error: Error) {
        isCapturing = false
        activeStream = nil
        streamReceiver = nil
        delegate?.deviceAudioDidEncounterError(error)
    }

    fileprivate func handleStreamStopped() {
        isCapturing = false
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

        guard let pcmBuffer = extractPCMBuffer(from: sampleBuffer) else { return }
        guard let convertedBuffer = convertToTarget(pcmBuffer) else { return }
        guard let channelData = convertedBuffer.floatChannelData?[0], convertedBuffer.frameLength > 0 else { return }

        let length = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: length))

        // Calculate audio power level
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, length))
        let level = min(1, max(0, (20 * log10(max(sqrt(power), 0.00001)) + 60) / 60))

        Task { @MainActor [weak self] in
            self?.manager?.delegate?.deviceAudioDidOutput(samples: samples, level: level)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.handleStreamError(error)
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
