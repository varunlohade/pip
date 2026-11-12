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

/// The phone's own voice: on-device, no network. It picks the best English voice installed (Premium, then Enhanced,
/// then the default) and plays as "ambient" audio, so the ringer/silent switch silences it.
@MainActor
final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var finish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    static var bestVoice: AVSpeechSynthesisVoice? {
        let lang = Locale.preferredLanguages.first(where: { $0.hasPrefix("en") }) ?? "en-US"
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let rank = { (v: AVSpeechSynthesisVoice) -> Int in
            let q = v.quality == .premium ? 3 : v.quality == .enhanced ? 2 : 1
            return q * 10 + (v.language == lang ? 1 : 0)
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: lang)
    }

    func say(_ text: String, done: @escaping () -> Void) {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        finish?()
        finish = done
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
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
