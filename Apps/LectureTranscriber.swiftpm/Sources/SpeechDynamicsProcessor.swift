import Foundation
import Accelerate

// MARK: - Audio Dynamics Diagnostics

public struct AudioDynamicsDiagnostics: Sendable, Codable, Equatable {
    public var preRMS: Float = 0
    public var preRMSdBFS: Float = -100
    public var prePeak: Float = 0
    public var prePeakdBFS: Float = -100
    public var postRMS: Float = 0
    public var postRMSdBFS: Float = -100
    public var postPeak: Float = 0
    public var postPeakdBFS: Float = -100
    public var targetGaindB: Float = 0

    // Backward-compatible aliases for testing
    public var prePeakDBFS: Float { prePeakdBFS }
    public var postPeakDBFS: Float { postPeakdBFS }
    public var effectiveGainDB: Float { targetGaindB }

    public init() {}

    public func formattedSummary() -> String {
        """
        Input:  RMS=\(String(format: "%.1f", preRMSdBFS)) dBFS, Peak=\(String(format: "%.1f", prePeakdBFS)) dBFS
        Output: RMS=\(String(format: "%.1f", postRMSdBFS)) dBFS, Peak=\(String(format: "%.1f", postPeakdBFS)) dBFS
        Applied Target Gain: +\(String(format: "%.1f", targetGaindB)) dB
        """
    }
}

// MARK: - Speech Dynamics Processor

/// Speech dynamics processor designed for lecture recordings.
/// Solves the "recording too quiet" problem found when comparing LectureTranscriber to Apple Voice Memos.
/// Does NOT use a blind fixed multiplier or harsh clipping.
/// Uses envelope tracking, voice-oriented dynamic range compression, and a transparent peak limiter.
public final class SpeechDynamicsProcessor: @unchecked Sendable {
    private var envelope: Float = 0.0
    private let attackAlpha: Float
    private let releaseAlpha: Float
    private let ceiling: Float = 0.965 // -0.3 dBFS peak ceiling

    private let lock = NSLock()
    private var lastDiagnostics = AudioDynamicsDiagnostics()

    public init(sampleRate: Double = 16000) {
        // Attack ~ 10ms, Release ~ 120ms
        let dt = Float(1.0 / sampleRate)
        let attackTime: Float = 0.010
        let releaseTime: Float = 0.120
        self.attackAlpha = exp(-dt / attackTime)
        self.releaseAlpha = exp(-dt / releaseTime)
    }

    public func currentDiagnostics() -> AudioDynamicsDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return lastDiagnostics
    }

    /// Convenience processor returning both processed samples and captured dynamics diagnostics.
    public func processWithDiagnostics(_ samples: [Float]) -> ([Float], AudioDynamicsDiagnostics) {
        let out = process(samples)
        return (out, currentDiagnostics())
    }

    /// Processes a block of PCM samples in place, returning a listener-optimized speech audio buffer.
    public func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        // 1. Analyze input levels
        var preSumSq: Float = 0
        var preMaxPeak: Float = 0
        for s in samples {
            let absVal = abs(s)
            preSumSq += s * s
            if absVal > preMaxPeak { preMaxPeak = absVal }
        }
        let preRMS = sqrt(max(1e-9, preSumSq / Float(samples.count)))
        let preRMSdB = 20.0 * log10(max(1e-5, preRMS))
        let prePeakdB = 20.0 * log10(max(1e-5, preMaxPeak))

        // 2. Adaptive voice gain calculation:
        // Typical unamplified classroom speech sits around -36 to -28 dBFS RMS.
        // Target listening loudness is around -18 to -16 dBFS RMS (standard podcast / voice memo target).
        // Calculate smooth target makeup gain bounded between +2 dB (loud speaker) and +16 dB (distant voice).
        let targetRMSdB: Float = -16.0
        let rawNeededGaindB = targetRMSdB - preRMSdB
        let targetGaindB: Float = min(16.0, max(2.0, rawNeededGaindB))
        let linearMakeupGain = pow(10.0, targetGaindB / 20.0)

        // Compression parameters: Threshold -18 dBFS, Ratio 2.8:1, Soft Knee
        let thresholdLinear: Float = pow(10.0, -18.0 / 20.0) // ~0.126
        let compRatio: Float = 2.8

        var output = [Float](repeating: 0, count: samples.count)
        var postSumSq: Float = 0
        var postMaxPeak: Float = 0

        var currentEnv = envelope

        for i in 0..<samples.count {
            let inputSample = samples[i]
            let absInput = abs(inputSample)

            // Envelope follower
            if absInput > currentEnv {
                currentEnv = attackAlpha * currentEnv + (1.0 - attackAlpha) * absInput
            } else {
                currentEnv = releaseAlpha * currentEnv + (1.0 - releaseAlpha) * absInput
            }

            // Apply makeup gain
            var gainedSample = inputSample * linearMakeupGain

            // Dynamic compression for high levels above threshold
            let gainedEnv = currentEnv * linearMakeupGain
            if gainedEnv > thresholdLinear {
                let overdB = 20.0 * log10(max(1e-5, gainedEnv / thresholdLinear))
                let gainReductiondB = overdB * (1.0 - 1.0 / compRatio)
                let compFactor = pow(10.0, -gainReductiondB / 20.0)
                gainedSample *= compFactor
            }

            // Smooth transparent peak limiter (soft saturation preventing hard clipping)
            let absGained = abs(gainedSample)
            let limitedSample: Float
            if absGained <= 0.85 {
                limitedSample = gainedSample
            } else {
                // Soft sigmoid knee above 0.85 heading asymptotically to ceiling (0.965)
                let excess = absGained - 0.85
                let compression = (ceiling - 0.85) * tanh(excess / (ceiling - 0.85 + 1e-4))
                let newAbs = 0.85 + compression
                limitedSample = (gainedSample >= 0 ? 1.0 : -1.0) * min(ceiling, newAbs)
            }

            output[i] = limitedSample
            postSumSq += limitedSample * limitedSample
            let absLimited = abs(limitedSample)
            if absLimited > postMaxPeak { postMaxPeak = absLimited }
        }

        self.envelope = currentEnv

        let postRMS = sqrt(max(1e-9, postSumSq / Float(samples.count)))
        let postRMSdB = 20.0 * log10(max(1e-5, postRMS))
        let postPeakdB = 20.0 * log10(max(1e-5, postMaxPeak))

        lock.lock()
        lastDiagnostics = AudioDynamicsDiagnostics()
        lastDiagnostics.preRMS = preRMS
        lastDiagnostics.preRMSdBFS = preRMSdB
        lastDiagnostics.prePeak = preMaxPeak
        lastDiagnostics.prePeakdBFS = prePeakdB
        lastDiagnostics.postRMS = postRMS
        lastDiagnostics.postRMSdBFS = postRMSdB
        lastDiagnostics.postPeak = postMaxPeak
        lastDiagnostics.postPeakdBFS = postPeakdB
        lastDiagnostics.targetGaindB = targetGaindB
        lock.unlock()

        return output
    }
}
