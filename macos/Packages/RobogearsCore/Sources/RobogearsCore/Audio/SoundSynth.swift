import Foundation

/// The app's sound effects. They were synthesised live with Web Audio in the
/// Electron app; here each one is rendered once, sample by sample, from the
/// same oscillators, envelopes and filters
/// (docs/electron-reference/waveform-preview-and-sounds.md, section A).
public enum SoundEffect: String, CaseIterable, Sendable {
    /// Rising C5 → G5: a batch starts.
    case downloadChime
    /// Falling G5 → C5: a batch is cancelled.
    case cancelChime
    /// G5 → C6 → E6 bells: a batch finished with nothing failed.
    case successPing
    /// New in the Swift app (decision 4, item 2.8): a quieter, lower falling
    /// pair for a batch that finished with failures. Owner to approve by ear.
    case finishedWithProblems
    /// Low two-tone honk: an action was blocked (no folder, not signed in…).
    case warningHonk
    /// Higher two-tone honk. Unused in the Electron app since v0.1.25 but
    /// kept "in case we want to repurpose" (CLAUDE.md).
    case clownHorn
    /// Easter egg: click the logo or the app name.
    case brandFart
    /// Easter egg: click the version number (the same sound at 7× pitch).
    case versionFart
}

/// Renders sound effects to mono Float samples in the range -1…1.
public enum SoundSynth {
    public static let defaultSampleRate: Double = 48_000

    public static func render(_ effect: SoundEffect, sampleRate: Double = defaultSampleRate) -> [Float] {
        // Every Web Audio graph started at `currentTime + 0.02`; keep that
        // lead-in so the attack isn't clipped by the output starting up.
        let t = 0.02
        var mix = Mix(sampleRate: sampleRate)
        switch effect {
        case .downloadChime:
            mix.add(blip(523.25, at: t, duration: 0.13, attack: 0.012))
            mix.add(blip(783.99, at: t + 0.09, duration: 0.18, attack: 0.012))
        case .cancelChime:
            mix.add(blip(783.99, at: t, duration: 0.10, attack: 0.012))
            mix.add(blip(523.25, at: t + 0.07, duration: 0.15, attack: 0.012))
        case .successPing:
            mix.add(blip(783.99, at: t, duration: 0.28, attack: 0.008))
            mix.add(blip(1046.50, at: t + 0.07, duration: 0.32, attack: 0.008))
            mix.add(blip(1318.51, at: t + 0.14, duration: 0.42, attack: 0.008))
        case .finishedWithProblems:
            // E5 → C#5, a falling minor third at under two-thirds of the
            // chime's level: clearly "done", clearly not "all good".
            mix.add(blip(659.25, at: t, duration: 0.16, attack: 0.012, peak: 0.14))
            mix.add(blip(554.37, at: t + 0.12, duration: 0.26, attack: 0.012, peak: 0.14))
        case .warningHonk:
            for voice in honkPair(high: 220, low: 165, lowpass: 1100, peak: 0.3, start: t) { mix.add(voice) }
        case .clownHorn:
            for voice in honkPair(high: 420, low: 310, lowpass: 1800, peak: 0.35, start: t) { mix.add(voice) }
        case .brandFart:
            mix.add(fart(pitchScale: 1, start: t))
        case .versionFart:
            mix.add(fart(pitchScale: 7, start: t))
        }
        return mix.render()
    }

    // MARK: - Voices (one function per Web Audio graph in the Electron app)

    /// Two sines at f and f × 1.005 into one gain node: the chimes and bells.
    static func blip(_ frequency: Double, at start: Double, duration: Double, attack: Double, peak: Double = 0.22) -> Voice {
        var gain = Automation(defaultValue: 1)
        gain.set(0.0001, at: start)
        gain.exponentialRamp(to: peak, at: start + attack)
        gain.exponentialRamp(to: 0.0001, at: start + duration)
        return Voice(
            oscillators: [
                Oscillator(shape: .sine, frequency: .constant(frequency)),
                Oscillator(shape: .sine, frequency: .constant(frequency * 1.005)),
            ],
            filter: nil, gain: gain, start: start, stop: start + duration + 0.05
        )
    }

    /// A sawtooth gliding from 1.08 × f down to f over half the note, through
    /// a lowpass: the honks.
    static func honk(_ frequency: Double, at start: Double, duration: Double, lowpass: Double, peak: Double) -> Voice {
        var pitch = Automation(defaultValue: frequency)
        pitch.set(frequency * 1.08, at: start)
        pitch.exponentialRamp(to: frequency, at: start + duration * 0.5)
        var gain = Automation(defaultValue: 1)
        gain.set(0.0001, at: start)
        gain.exponentialRamp(to: peak, at: start + 0.012)
        gain.exponentialRamp(to: 0.0001, at: start + duration)
        return Voice(
            oscillators: [Oscillator(shape: .sawtooth, frequency: .automated(pitch))],
            filter: Lowpass(cutoff: lowpass, qDecibels: 1), gain: gain, start: start, stop: start + duration + 0.05
        )
    }

    static func honkPair(high: Double, low: Double, lowpass: Double, peak: Double, start: Double) -> [Voice] {
        [
            honk(high, at: start, duration: 0.17, lowpass: lowpass, peak: peak),
            honk(low, at: start + 0.22, duration: 0.22, lowpass: lowpass, peak: peak),
        ]
    }

    /// Sawtooth 95 → 48 Hz with a 17 Hz wobble, through a resonant lowpass.
    /// `pitchScale` 7 is the version-click variant.
    static func fart(pitchScale ps: Double, start: Double) -> Voice {
        let duration = 0.42
        var pitch = Automation(defaultValue: 95 * ps)
        pitch.set(95 * ps, at: start)
        pitch.exponentialRamp(to: 48 * ps, at: start + duration)
        var gain = Automation(defaultValue: 1)
        gain.set(0.0001, at: start)
        gain.exponentialRamp(to: 0.42, at: start + 0.02)
        gain.linearRamp(to: 0.32, at: start + duration * 0.45)
        gain.exponentialRamp(to: 0.0001, at: start + duration)
        let wobble = LFO(rate: 17 * ps.squareRoot(), depth: 18 * ps, start: start)
        return Voice(
            oscillators: [Oscillator(shape: .sawtooth, frequency: .automated(pitch), vibrato: wobble)],
            filter: Lowpass(cutoff: 480 * ps, qDecibels: 2.2), gain: gain, start: start, stop: start + duration + 0.05
        )
    }
}

// MARK: - A tiny offline rendition of the Web Audio pieces the sounds use

/// AudioParam automation with Web Audio's semantics: a ramp runs from the
/// previous event's time and value to its own; values hold between events.
struct Automation: Sendable {
    enum Kind: Sendable { case set, linear, exponential }
    struct Event: Sendable { let kind: Kind; let value: Double; let time: Double }

    let defaultValue: Double
    private(set) var events: [Event] = []

    init(defaultValue: Double) { self.defaultValue = defaultValue }

    mutating func set(_ value: Double, at time: Double) { events.append(Event(kind: .set, value: value, time: time)) }
    mutating func linearRamp(to value: Double, at time: Double) { events.append(Event(kind: .linear, value: value, time: time)) }
    mutating func exponentialRamp(to value: Double, at time: Double) { events.append(Event(kind: .exponential, value: value, time: time)) }

    func value(at t: Double) -> Double {
        var previousTime = 0.0
        var previousValue = defaultValue
        for event in events {
            if t < event.time {
                switch event.kind {
                case .set:
                    return previousValue
                case .linear:
                    let span = event.time - previousTime
                    guard span > 0 else { return event.value }
                    return previousValue + (event.value - previousValue) * (t - previousTime) / span
                case .exponential:
                    let span = event.time - previousTime
                    // Web Audio holds the previous value when a ramp would
                    // cross or touch zero; none of these sounds do.
                    guard span > 0, previousValue > 0, event.value > 0 else { return previousValue }
                    return previousValue * pow(event.value / previousValue, (t - previousTime) / span)
                }
            }
            previousTime = event.time
            previousValue = event.value
        }
        return previousValue
    }
}

struct LFO: Sendable {
    let rate: Double
    let depth: Double
    let start: Double
}

struct Oscillator: Sendable {
    enum Shape: Sendable { case sine, sawtooth }
    enum Frequency: Sendable {
        case constant(Double)
        case automated(Automation)
        func value(at t: Double) -> Double {
            switch self {
            case .constant(let f): return f
            case .automated(let a): return a.value(at: t)
            }
        }
    }
    let shape: Shape
    let frequency: Frequency
    var vibrato: LFO? = nil
}

/// The RBJ lowpass that Web Audio's BiquadFilterNode uses, with Q in dB as
/// the Web Audio spec defines it for lowpass filters.
struct Lowpass: Sendable {
    let cutoff: Double
    let qDecibels: Double
}

struct Voice: Sendable {
    let oscillators: [Oscillator]
    let filter: Lowpass?
    let gain: Automation
    let start: Double
    let stop: Double
}

struct Mix {
    let sampleRate: Double
    private var voices: [Voice] = []

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func add(_ voice: Voice) { voices.append(voice) }

    func render() -> [Float] {
        let end = voices.map(\.stop).max() ?? 0
        let count = Int((end * sampleRate).rounded(.up))
        var out = [Double](repeating: 0, count: count)
        for voice in voices { renderVoice(voice, into: &out) }
        return out.map { Float(max(-1, min(1, $0))) }
    }

    private func renderVoice(_ voice: Voice, into out: inout [Double]) {
        let first = max(0, Int((voice.start * sampleRate).rounded(.down)))
        let last = min(out.count, Int((voice.stop * sampleRate).rounded(.up)))
        guard first < last else { return }
        var phases = [Double](repeating: 0, count: voice.oscillators.count)
        var lfoPhases = [Double](repeating: 0, count: voice.oscillators.count)
        var biquad = voice.filter.map { BiquadState(filter: $0, sampleRate: sampleRate) }
        for i in first..<last {
            let t = Double(i) / sampleRate
            var sample = 0.0
            for (k, osc) in voice.oscillators.enumerated() {
                var f = osc.frequency.value(at: t)
                if let lfo = osc.vibrato {
                    f += lfo.depth * sin(2 * .pi * lfoPhases[k])
                    lfoPhases[k] += lfo.rate / sampleRate
                    lfoPhases[k] -= lfoPhases[k].rounded(.down)
                }
                let dt = max(0, f / sampleRate)
                sample += Self.waveform(osc.shape, phase: phases[k], dt: dt)
                phases[k] += dt
                phases[k] -= phases[k].rounded(.down)
            }
            if biquad != nil { sample = biquad!.process(sample) }
            out[i] += sample * voice.gain.value(at: t)
        }
    }

    /// Band-limited waveforms (Web Audio's oscillators don't alias): a plain
    /// sine, and a sawtooth corrected with PolyBLEP at its jump.
    static func waveform(_ shape: Oscillator.Shape, phase p: Double, dt: Double) -> Double {
        switch shape {
        case .sine:
            return sin(2 * .pi * p)
        case .sawtooth:
            var value = 2 * p - 1
            if dt > 0 {
                if p < dt {
                    let x = p / dt
                    value -= x + x - x * x - 1
                } else if p > 1 - dt {
                    let x = (p - 1) / dt
                    value -= x * x + x + x + 1
                }
            }
            return value
        }
    }
}

struct BiquadState {
    private let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(filter: Lowpass, sampleRate: Double) {
        let w0 = 2 * Double.pi * min(filter.cutoff, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * pow(10, filter.qDecibels / 20))
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = (1 - cosw) / 2 / a0
        b1 = (1 - cosw) / a0
        b2 = (1 - cosw) / 2 / a0
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
