import Foundation
import AVFoundation
import UIKit
import Combine

// MARK: - Audio Session State

public enum AudioSessionState: String, Sendable, Codable, Equatable {
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
    public var selectedMicrophoneType: String
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
        selectedMicrophoneType: String = "Built-in Mic",
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
        self.selectedMicrophoneType = selectedMicrophoneType
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
        Microphone Target: \(selectedMicrophoneType)
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

    // MARK: - Microphone Route Policy

    /// Configures audio session for normal microphone recording.
    /// Baseline policy:
    /// - Category: .playAndRecord
    /// - Mode: .default (NOT .spokenAudio, NOT .measurement)
    /// - Option: .mixWithOthers preserved so other-app media is not silenced.
    /// Route-specific options:
    /// 1. Built-in mic + Bluetooth media: [.mixWithOthers, .allowBluetoothA2DP].
    ///    Request built-in mic input so Bluetooth output stays on high-quality A2DP.
    ///    Does NOT enable HFP.
    /// 2. Built-in mic + speaker: [.mixWithOthers, .defaultToSpeaker].
    /// 3. Bluetooth microphone: [.mixWithOthers, .allowBluetooth] only when user/system intentionally selects Bluetooth mic.
    public func activateMicrophoneCapture(preferBluetoothMic: Bool, allowsPlayback: Bool = true) throws {
        try activateMicrophoneCapture(allowsPlayback: allowsPlayback, preferBluetoothMic: preferBluetoothMic)
    }

    public func activateMicrophoneCapture(allowsPlayback: Bool = true, preferBluetoothMic: Bool = false) throws {
        // Invariant: If device audio capture is running, microphone capture cannot overlap
        if currentState == .deviceAudioCapture {
            deactivateDeviceAudioCapture()
        }

        let session = AVAudioSession.sharedInstance()
        currentState = .microphoneCapture

        let mode: AVAudioSession.Mode = .default
        let available = session.availableInputs ?? []
        let hasBluetoothInput = available.contains { $0.portType == .bluetoothHFP }
        let hasBluetoothOutput = session.currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }

        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        var targetMicType = "Built-in Mic"

        if preferBluetoothMic && hasBluetoothInput {
            // User explicitly requested Bluetooth microphone -> HFP mode
            options.insert(.bluetoothHFPCompatible)
            targetMicType = "Bluetooth Mic (HFP)"
        } else if hasBluetoothOutput || hasBluetoothInput {
            // Bluetooth device connected, but user wants built-in mic capture + Bluetooth media output
            options.insert(.allowBluetoothA2DP)
            targetMicType = "Built-in Mic + Bluetooth A2DP Output"
        } else {
            // Built-in mic + iPhone speaker
            options.insert(.defaultToSpeaker)
            targetMicType = "Built-in Mic + Speaker"
        }

        do {
            try session.setCategory(.playAndRecord, mode: mode, options: options)

            // Select preferred input without fighting route in an infinite loop
            if !(preferBluetoothMic && hasBluetoothInput) {
                if let builtIn = available.first(where: { $0.portType == .builtInMic }) {
                    try? session.setPreferredInput(builtIn)
                }
            } else if let btInput = available.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(btInput)
            }

            try session.setActive(true)
            refreshDiagnostics(selectedMicrophoneType: targetMicType)
        } catch {
            diagnostics.lastError = error.localizedDescription
            refreshDiagnostics(selectedMicrophoneType: targetMicType)
            throw error
        }
    }

    /// Deactivates microphone audio session with notifyOthersOnDeactivation.
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

    // MARK: - Device Audio Policy (Zero Owned Session)

    /// Invariant: Device Audio MUST OWN NO AVAudioSession!
    /// Releases any app-owned session proactively before ScreenCaptureKit starts.
    public func activateDeviceAudioCapture() {
        currentState = .deviceAudioCapture
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        refreshDiagnostics(selectedMicrophoneType: "None (Device Audio ScreenCaptureKit)")
    }

    public func deactivateDeviceAudioCapture() {
        currentState = .idle
        refreshDiagnostics()
    }

    // MARK: - Playback Policy

    /// Configures audio session for recorded file playback.
    public func activatePlayback() throws {
        guard currentState != .deviceAudioCapture else {
            // Device audio active; do not interrupt
            return
        }
        let session = AVAudioSession.sharedInstance()
        currentState = .recordedFilePlayback
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            refreshDiagnostics()
        } catch {
            diagnostics.lastError = error.localizedDescription
            refreshDiagnostics()
            throw error
        }
    }

    public func deactivatePlayback() {
        guard currentState == .recordedFilePlayback else { return }
        let session = AVAudioSession.sharedInstance()
        currentState = .idle
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        refreshDiagnostics()
    }

    // MARK: - Picture-in-Picture Policy

    public func prepareForPiP(isDeviceAudio: Bool = false) {
        beginPiPPresentation(requiresAudioSession: !isDeviceAudio)
    }

    /// Invariant: PiP during Device Audio must NOT activate an app-owned audio session.
    public func beginPiPPresentation(requiresAudioSession: Bool = false) {
        guard requiresAudioSession else {
            // Device Audio or video-only: do not activate AVAudioSession!
            return
        }
        guard currentState != .deviceAudioCapture else {
            // Strict guard: Device Audio owns NO audio session!
            return
        }
        if currentState == .idle {
            currentState = .pipPresentation
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            refreshDiagnostics()
        }
    }

    public func endPiPPresentation() {
        if currentState == .pipPresentation {
            currentState = .idle
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            refreshDiagnostics()
        }
    }

    // MARK: - Diagnostics

    public func refreshDiagnostics(
        reason: String? = nil,
        interruption: String? = nil,
        selectedMicrophoneType: String? = nil
    ) {
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
            selectedMicrophoneType: selectedMicrophoneType ?? diagnostics.selectedMicrophoneType,
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

// MARK: - Compatibility Extensions

extension AVAudioSession.CategoryOptions {
    public static var bluetoothHFPCompatible: AVAudioSession.CategoryOptions {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            return .allowBluetoothHFP
        } else {
            return .allowBluetooth
        }
        #else
        return .allowBluetooth
        #endif
    }
}

