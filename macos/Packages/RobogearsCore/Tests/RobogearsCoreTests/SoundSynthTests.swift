import Foundation
import Testing
@testable import RobogearsCore

/// Energy of one frequency in a window of samples (Goertzel), used to check
/// that each note sits where the Electron app put it.
private func energy(_ samples: [Float], at frequency: Double, from start: Double, to end: Double, sampleRate: Double = 48_000) -> Double {
    let a = max(0, Int(start * sampleRate)), b = min(samples.count, Int(end * sampleRate))
    guard a < b else { return 0 }
    let w = 2 * Double.pi * frequency / sampleRate
    let coeff = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for i in a..<b {
        let s0 = Double(samples[i]) + coeff * s1 - s2
        s2 = s1; s1 = s0
    }
    return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / Double(b - a)
}

private func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

/// True when `frequency` clearly stands out from its neighbours `spread` Hz
/// either side in the window, so a note that is merely close isn't accepted.
private func noteSounds(_ samples: [Float], _ frequency: Double, from start: Double, to end: Double, spread: Double = 40) -> Bool {
    let centre = energy(samples, at: frequency, from: start, to: end)
    let neighbours = max(energy(samples, at: frequency - spread, from: start, to: end),
                         energy(samples, at: frequency + spread, from: start, to: end))
    return centre > 5 * neighbours
}

@Test(arguments: SoundEffect.allCases)
func everySoundRendersAudibleFiniteSamplesWithoutClipping(_ effect: SoundEffect) {
    let samples = SoundSynth.render(effect)
    #expect(!samples.isEmpty)
    #expect(samples.allSatisfy { $0.isFinite })
    #expect(peak(samples) > 0.05)
    #expect(peak(samples) < 0.99)
}

@Test func soundLengthsMatchTheElectronTimings() {
    // Lengths are the last oscillator stop time: lead-in 0.02 s + timings
    // from waveform-preview-and-sounds.md A3-A7.
    let expected: [SoundEffect: Double] = [
        .downloadChime: 0.02 + 0.09 + 0.18 + 0.05,
        .cancelChime: 0.02 + 0.07 + 0.15 + 0.05,
        .successPing: 0.02 + 0.14 + 0.42 + 0.05,
        .warningHonk: 0.02 + 0.22 + 0.22 + 0.05,
        .clownHorn: 0.02 + 0.22 + 0.22 + 0.05,
        .brandFart: 0.02 + 0.42 + 0.05,
        .versionFart: 0.02 + 0.42 + 0.05,
    ]
    for (effect, seconds) in expected {
        let length = Double(SoundSynth.render(effect).count) / SoundSynth.defaultSampleRate
        #expect(abs(length - seconds) < 0.001, "\(effect) lasts \(length) s, expected \(seconds) s")
    }
}

@Test func downloadChimeRisesFromC5ToG5() {
    let s = SoundSynth.render(.downloadChime)
    // Before G5 enters (t < 0.11 s) the C5 dominates; near the end only G5 is left.
    #expect(noteSounds(s, 523.25, from: 0.03, to: 0.10))
    #expect(energy(s, at: 523.25, from: 0.03, to: 0.10) > 10 * energy(s, at: 783.99, from: 0.03, to: 0.10))
    #expect(noteSounds(s, 783.99, from: 0.16, to: 0.22))
    #expect(energy(s, at: 783.99, from: 0.16, to: 0.22) > 10 * energy(s, at: 523.25, from: 0.16, to: 0.22))
}

@Test func cancelChimeFallsFromG5ToC5() {
    let s = SoundSynth.render(.cancelChime)
    #expect(noteSounds(s, 783.99, from: 0.025, to: 0.085))
    #expect(noteSounds(s, 523.25, from: 0.13, to: 0.20))
    #expect(energy(s, at: 523.25, from: 0.13, to: 0.20) > 10 * energy(s, at: 783.99, from: 0.13, to: 0.20))
}

@Test func successPingPlaysThreeRisingBells() {
    let s = SoundSynth.render(.successPing)
    #expect(noteSounds(s, 783.99, from: 0.025, to: 0.085))
    #expect(noteSounds(s, 1046.50, from: 0.22, to: 0.30, spread: 60))
    #expect(noteSounds(s, 1318.51, from: 0.40, to: 0.55, spread: 60))
}

@Test func problemSoundIsQuieterThanTheSuccessPing() {
    #expect(peak(SoundSynth.render(.finishedWithProblems)) < peak(SoundSynth.render(.successPing)) * 0.7)
}

@Test func warningHonkSitsBelowTheClownHorn() {
    let warning = SoundSynth.render(.warningHonk)
    // Second honk settles on 165 Hz for the warning…
    #expect(noteSounds(warning, 165, from: 0.36, to: 0.44, spread: 25))
    #expect(energy(warning, at: 165, from: 0.36, to: 0.44) > 5 * energy(warning, at: 310, from: 0.36, to: 0.44))
    // …and on 310 Hz for the clown horn.
    let clown = SoundSynth.render(.clownHorn)
    #expect(noteSounds(clown, 310, from: 0.36, to: 0.44, spread: 25))
}

@Test func versionFartIsMuchHigherThanTheBrandFart() {
    func centroid(_ s: [Float]) -> Double {
        // Zero-crossing rate as a cheap brightness measure.
        var crossings = 0
        for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { crossings += 1 }
        return Double(crossings) / Double(s.count)
    }
    #expect(centroid(SoundSynth.render(.versionFart)) > 3 * centroid(SoundSynth.render(.brandFart)))
}

@Test func exponentialRampFollowsWebAudioSemantics() {
    var a = Automation(defaultValue: 1)
    a.set(0.0001, at: 1)
    a.exponentialRamp(to: 0.01, at: 2)
    // Halfway through an exponential ramp the value is the geometric mean.
    #expect(abs(a.value(at: 1.5) - 0.001) < 1e-9)
    // Before the first event the default holds; after the last, its value.
    #expect(a.value(at: 0.5) == 1)
    #expect(a.value(at: 3) == 0.01)
}

@Test func linearRampStartsFromThePreviousEvent() {
    var a = Automation(defaultValue: 0)
    a.set(0.42, at: 0)
    a.linearRamp(to: 0.32, at: 1)
    #expect(abs(a.value(at: 0.5) - 0.37) < 1e-12)
}
