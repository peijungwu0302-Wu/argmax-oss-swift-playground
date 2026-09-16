import Foundation
import AVFoundation
import UIKit
import Combine

// MARK: - Audio Session State

public enum AudioSessionState: String, Sendable, Codable {
    case idle
    case microphoneCapture
    case recordedFilePlayback
    case deviceAudioCapture
    case pipPresentation
    case routeTransition
}

// MARK: - Audio Session Diagnostics Model

public struct AudioSessionDiagnostics: Sendable, Codable {
    public var currentState: AudioSessionState
    public var category: String
    public var mode: String
    public var categoryOptions: String
    public var currentInputs: [String]
    public var currentOutputs: [String]
    public var availableInputs: [String]
    public var preferredInput: String?
    public var sampleRate: Double
    public var ioBufferDuration: Double
    public var outputVolume: Float
    public var inputGain: Float
    public var isInputGainSettable: Bool
    public var lastRouteChangeReason: String?
    public var lastInterruption: String?
    public var lastError: String?
    public var timestamp: Date

    public init(
        currentState: AudioSessionState = .idle,
        category: String = "",
        mode: String = "",
        categoryOptions: String = "",
        currentInputs: [String] = [],
        currentOutputs: [String] = [],
        availableInputs: [String] = [],
        preferredInput: String? = nil,
        sampleRate: Double = 0,
        ioBufferDuration: Double = 0,
        outputVolume: Float = 0,
        inputGain: Float = 0,
        isInputGainSettable: Bool = false,
        lastRouteChangeReason: String? = nil,
        lastInterruption: String? = nil,
        lastError: String? = nil,
        timestamp: Date = Date()
    ) {
        self.currentState = currentState
        self.category = category
        self.mode = mode
        self.categoryOptions = categoryOptions
        self.currentInputs = currentInputs
        self.currentOutputs = currentOutputs
        self.availableInputs = availableInputs
        self.preferredInput = preferredInput
        self.sampleRate = sampleRate
        self.ioBufferDuration = ioBufferDuration
        self.outputVolume = outputVolume
        self.inputGain = inputGain
        self.isInputGainSettable = isInputGainSettable
        self.lastRouteChangeReason = lastRouteChangeReason
        self.lastInterruption = lastInterruption
        self.lastError = lastError
        self.timestamp = timestamp
    }

    public func formattedSummary() -> String {
        """
        === AudioSession Diagnostics ===
        State: \(currentState.rawValue)
        Category: \(category)
        Mode: \(mode)
        Options: \(categoryOptions)
        Current Inputs: \(currentInputs.isEmpty ? "None" : currentInputs.joined(separator: ", "))
        Current Outputs: \(currentOutputs.isEmpty ? "None" : currentOutputs.joined(separator: ", "))
        Available Inputs: \(availableInputs.isEmpty ? "None" : availableInputs.joined(separator: ", "))
        Preferred Input: \(preferredInput ?? "Default")
        Sample Rate: \(Int(sampleRate)) Hz
        IO Buffer Duration: \(String(format: "%.4f s", ioBufferDuration))
        Output Volume: \(String(format: "%.2f", outputVolume))
        Input Gain: \(String(format: "%.2f", inputGain)) (Settable: \(isInputGainSettable ? "YES" : "NO"))
        Last Route Change: \(lastRouteChangeReason ?? "None")
        Last Interruption: \(lastInterruption ?? "None")
        Last Error: \(lastError ?? "None")
        Updated: \(timestamp.formatted(date: .abbreviated, time: .standard))
        ================================
        """
    }
}

// MARK: - Centralized Audio Session Coordinator

@MainActor
public final class AudioSessionCoordinator: ObservableObject {
    public static let shared = AudioSessionCoordinator()

    @Published public private(set) var currentState: AudioSessionState = .idle
    @Published public private(set) var diagnostics: AudioSessionDiagnostics = AudioSessionDiagnostics()

    private var observers: [NSObjectProtocol] = []

    private init() {
        registerNotifications()
        refreshDiagnostics()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - State Management

    /// Configures audio session for microphone recording.
    /// Uses .playAndRecord with .spokenAudio mode (or .default), avoiding .measurement (which turns off AGC/tuning)
    /// and avoiding forcing unwanted Bluetooth HFP telephone quality.
    public func activateMicrophoneCapture(allowsPlayback: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        currentState = .microphoneCapture

        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
        if allowsPlayback {
            options.insert(.allowBluetoothA2DP)
            options.insert(.allowBluetooth)
        }

        // Use .spokenAudio for speech-oriented capture
        let mode: AVAudioSession.Mode = .spokenAudio

        do {
            try session.setCategory(.playAndRecord, mode: mode, options: options)
            optimizeMicrophoneRoute(session: session)
            try session.setActive(true)
            refreshDiagnostics()
        } catch {
            diagnostics.lastError = error.localizedDescription
            refreshDiagnostics()
            throw error
        }
    }

    /// Deactivates microphone audio session.
    public func deactivateMicrophoneCapture() {
        let session = AVAudioSession.sharedInstance()
        currentState = .idle
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            diagnostics.lastError = error.localizedDescription
        }
        refreshDiagnostics()
    }

    /// Prepares for Device Audio capture:
    /// Invariant: Device Audio MUST NOT acquire or retain an app-owned AVAudioSession!
    /// We proactively release any active app-owned session before ScreenCaptureKit starts.
    public func activateDeviceAudioCapture() {
        currentState = .deviceAudioCapture
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        refreshDiagnostics()
    }

    public func deactivateDeviceAudioCapture() {
        currentState = .idle
        refreshDiagnostics()
    }

    /// Configures audio session for recorded file playback.
    public func activatePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        currentState = .recordedFilePlayback
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
            refreshDiagnostics()
        } catch {
            diagnostics.lastError = error.localizedDescription
            refreshDiagnostics()
            throw error
        }
    }

    public func deactivatePlayback() {
        let session = AVAudioSession.sharedInstance()
        currentState = .idle
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        refreshDiagnostics()
    }

    /// Invariant: PiP in Device Audio mode must NOT activate an app-owned audio session.
    public func prepareForPiP(isDeviceAudio: Bool) {
        if isDeviceAudio {
            // No-op; preserve ScreenCaptureKit system audio routing
            return
        }
        if currentState != .microphoneCapture && currentState != .recordedFilePlayback {
            currentState = .pipPresentation
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            refreshDiagnostics()
        }
    }

    // MARK: - Route Optimization

    private func optimizeMicrophoneRoute(session: AVAudioSession) {
        // Preferred behavior: Input = built-in iPhone microphone, Output = Bluetooth A2DP if connected.
        guard let available = session.availableInputs else { return }

        let hasBluetoothOutput = session.currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }

        if hasBluetoothOutput {
            // Find built-in mic to keep Bluetooth on high-quality A2DP rather than forcing low-bandwidth HFP
            if let builtInMic = available.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
        }
    }

    // MARK: - Diagnostics

    public func refreshDiagnostics(reason: String? = nil, interruption: String? = nil) {
        let session = AVAudioSession.sharedInstance()
        let inPorts = session.currentRoute.inputs.map { "\($0.portType.rawValue): \($0.portName)" }
        let outPorts = session.currentRoute.outputs.map { "\($0.portType.rawValue): \($0.portName)" }
        let avail = session.availableInputs?.map { "\($0.portType.rawValue): \($0.portName)" } ?? []

        diagnostics = AudioSessionDiagnostics(
            currentState: currentState,
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            categoryOptions: String(describing: session.categoryOptions),
            currentInputs: inPorts,
            currentOutputs: outPorts,
            availableInputs: avail,
            preferredInput: session.preferredInput.map { "\($0.portType.rawValue): \($0.portName)" },
            sampleRate: session.sampleRate,
            ioBufferDuration: session.ioBufferDuration,
            outputVolume: session.outputVolume,
            inputGain: session.inputGain,
            isInputGainSettable: session.isInputGainSettable,
            lastRouteChangeReason: reason ?? diagnostics.lastRouteChangeReason,
            lastInterruption: interruption ?? diagnostics.lastInterruption,
            lastError: diagnostics.lastError,
            timestamp: Date()
        )
    }

    @discardableResult
    public func copyDiagnostics() -> String {
        refreshDiagnostics()
        let summary = diagnostics.formattedSummary()
        UIPasteboard.general.string = summary
        return summary
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let desc = type == .began ? "Interruption Began" : "Interruption Ended"
            self.refreshDiagnostics(interruption: desc)
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            let reasonStr: String
            switch reason {
            case .newDeviceAvailable: reasonStr = "New device available"
            case .oldDeviceUnavailable: reasonStr = "Old device unavailable"
            case .categoryChange: reasonStr = "Category change"
            case .override: reasonStr = "Route override"
            case .wakeFromSleep: reasonStr = "Wake from sleep"
            case .noSuitableRouteForCategory: reasonStr = "No suitable route"
            case .routeConfigurationChange: reasonStr = "Route configuration change"
            default: reasonStr = "Unknown (\(reasonValue))"
            }
            self.refreshDiagnostics(reason: reasonStr)
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshDiagnostics(reason: "Media services reset")
        })
    }
}
