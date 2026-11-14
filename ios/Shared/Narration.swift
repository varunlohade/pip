import AVFoundation
import Foundation

/// Something that can say a line. AVSpeechSynthesizer behind it on a phone; tests pass a silent fake.
@MainActor
protocol Speaker: AnyObject {
    /// Says `text`, then calls `done` once (also when stopped).
    func say(_ text: String, done: @escaping () -> Void)
    func stop()
}

/// Keeps the voice and the drawing in step: a step goes on only when its line is said and its shapes are drawn,
/// or when `maxWait` runs out, so a slow voice never stalls the drawing for long. Pure logic, so tests can drive it.
@MainActor
final class NarrationSync {
    private let speaker: Speaker
    private let advance: () -> Void
    private let sleep: (Duration) async throws -> Void
    let maxWait: Duration
    private(set) var step = 0
    private var spoken = false
    private var drawn = false
    private var timeout: Task<Void, Never>?
    private(set) var stopped = false

    init(speaker: Speaker, maxWait: Duration = .seconds(8), sleep: @escaping (Duration) async throws -> Void, advance: @escaping () -> Void) {
        self.speaker = speaker
        self.maxWait = maxWait
        self.sleep = sleep
        self.advance = advance
    }

    /// The page started step `n`: say its line.
    func stepStarted(_ n: Int, say line: String?) {
        guard !stopped else { return }
        step = n
        spoken = false
        drawn = false
        timeout?.cancel()
        guard let line, !line.isEmpty else { spoken = true; return }
        speaker.say(line) { [weak self] in
            guard let self, self.step == n else { return }
            self.spoken = true
            self.goIfReady()
        }
    }

    /// The page drew every shape of step `n` and waits for the voice.
    func stepDrawn(_ n: Int) {
        guard !stopped, n == step else { return }
        drawn = true
        if goIfReady() { return }
        let sleep = sleep, wait = maxWait
        timeout = Task { [weak self] in
            try? await sleep(wait)
            guard let self, !Task.isCancelled, self.step == n, !self.stopped else { return }
            self.speaker.stop()
            self.spoken = true
            self.goIfReady()
        }
    }

    @discardableResult
    private func goIfReady() -> Bool {
        guard spoken, drawn, !stopped else { return false }
        timeout?.cancel()
        drawn = false
        advance()
        return true
    }

    /// The second tap, or the panel closing: quiet at once, and the page is let go.
    func stop() {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        speaker.stop()
        advance()
    }
}

/// One installed voice, as the ranking and the Voice screen see it.
struct VoiceInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let quality: AVSpeechSynthesisVoiceQuality
    let language: String

    init(id: String, name: String, quality: AVSpeechSynthesisVoiceQuality, language: String) {
        self.id = id; self.name = name; self.quality = quality; self.language = language
    }

    init(_ v: AVSpeechSynthesisVoice) { self.init(id: v.identifier, name: v.name, quality: v.quality, language: v.language) }

    /// "Ava (Premium)" and "Ava" are both Ava.
    var baseName: String { String(name.split(separator: " ").first ?? Substring(name)) }

    var qualityBadge: String { quality == .premium ? "Premium" : quality == .enhanced ? "Enhanced" : "Compact" }

    var accent: String { Locale.current.localizedString(forRegionCode: String(language.split(separator: "-").last ?? "")) ?? language }

    static var installedEnglish: [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.map(VoiceInfo.init)
    }
}

/// The voice Pip speaks with: the owner's pick from Settings → Voice, or the brightest good voice installed.
/// Lives in the App Group, so the keyboard's drawing narration uses it too.
struct VoiceChoice: Equatable {
    static let defaultRate: Float = 0.53
    static let defaultPitch: Float = 1.08
    static let preDelay: TimeInterval = 0.12

    var voiceID: String?
    var rate: Float = defaultRate
    var pitch: Float = defaultPitch

    /// Warm, bright voices first, in this order; then the best quality installed.
    static let preferred: [(name: String, qualities: [AVSpeechSynthesisVoiceQuality])] = [
        ("Ava", [.premium, .enhanced]), ("Zoe", [.premium, .enhanced]), ("Samantha", [.enhanced]), ("Evan", [.enhanced]),
    ]

    static func best(_ voices: [VoiceInfo], lang: String) -> VoiceInfo? {
        for p in preferred {
            for q in p.qualities {
                let hits = voices.filter { $0.baseName == p.name && $0.quality == q }
                if let v = hits.first(where: { $0.language == lang }) ?? hits.first { return v }
            }
        }
        let rank = { (v: VoiceInfo) -> Int in
            let q = v.quality == .premium ? 3 : v.quality == .enhanced ? 2 : 1
            return q * 10 + (v.language == lang ? 1 : 0)
        }
        return voices.max { rank($0) < rank($1) }
    }

    static func load(_ d: UserDefaults?) -> VoiceChoice {
        VoiceChoice(voiceID: d?.string(forKey: StoreKey.voiceID.rawValue),
                    rate: d?.object(forKey: StoreKey.voiceRate.rawValue) as? Float ?? defaultRate,
                    pitch: d?.object(forKey: StoreKey.voicePitch.rawValue) as? Float ?? defaultPitch)
    }

    func save(_ d: UserDefaults?) {
        d?.set(voiceID, forKey: StoreKey.voiceID.rawValue)
        d?.set(rate, forKey: StoreKey.voiceRate.rawValue)
        d?.set(pitch, forKey: StoreKey.voicePitch.rawValue)
    }

    /// The utterance for `text`: the chosen voice if it is still installed, else the best one.
    func utterance(_ text: String, voices: [VoiceInfo] = VoiceInfo.installedEnglish) -> AVSpeechUtterance {
        let lang = Locale.preferredLanguages.first(where: { $0.hasPrefix("en") }) ?? "en-US"
        let id = voices.first(where: { $0.id == voiceID })?.id ?? Self.best(voices, lang: lang)?.id
        let u = AVSpeechUtterance(string: text)
        u.voice = id.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: lang)
        u.rate = rate
        u.pitchMultiplier = pitch
        u.preUtteranceDelay = Self.preDelay
        return u
    }
}

/// The phone's own voice: on-device, no network. It speaks with the stored `VoiceChoice` and plays as "ambient" audio,
/// so the ringer/silent switch silences it.
@MainActor
final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var finish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String, done: @escaping () -> Void) {
        speak(text, choice: VoiceChoice.load(SharedStore.defaults), done: done)
    }

    func speak(_ text: String, choice: VoiceChoice, done: @escaping () -> Void = {}) {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.stopSpeaking(at: .immediate)
        finish?()
        finish = done
        synth.speak(choice.utterance(text))
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        finish?()
        finish = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            let f = finish
            finish = nil
            f?()
        }
    }
}
