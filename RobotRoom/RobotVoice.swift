import AVFoundation
import FluidAudio

/// The robot's voice: Kokoro-82M text to speech with a male voice, run on device through
/// FluidAudio's Core ML port, then given a light metallic tone. The model downloads the first
/// time and loads when the app opens. Until it's ready, or if it fails, the system speech
/// synthesizer reads the reply instead.
@MainActor @Observable
final class RobotVoice {
    /// Shown while the voice model downloads and loads.
    private(set) var status: String?
    /// Called about 30 times a second with how loud the robot is right now, 0...1, so its
    /// mouth can light up as it talks. 0 when it's quiet.
    var onLevel: (Float) -> Void = { _ in }

    /// Kokoro's American English male voice.
    private static let voiceName = "am_michael"
    private var mouth: Task<Void, Never>?
    private var kokoro: KokoroAneManager?
    private var loading: Task<Void, Never>?
    private var speaking: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let fallback = AVSpeechSynthesizer()
    /// The best-sounding male English system voice installed on the device, for the fallback.
    private let systemVoice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == "en-US" && $0.gender == .male }
        .max { $0.quality.rawValue < $1.quality.rawValue }
        ?? AVSpeechSynthesisVoice(language: "en-US")

    /// Load Kokoro ahead of time, so it's ready by the robot's first reply.
    func prepare() {
        guard kokoro == nil, loading == nil else { return }
        status = "Loading robot voice…"
        loading = Task {
            let manager = KokoroAneManager(defaultVoice: Self.voiceName)
            do {
                try await manager.initialize(preloadVoices: [Self.voiceName])
                kokoro = manager
            } catch {
                // Keep using the system voice.
            }
            status = nil
        }
    }

    func speak(_ text: String) {
        stop()
        speaking = Task {
            guard let kokoro else {
                speakWithSystemVoice(text)
                return
            }
            do {
                let speech = try await kokoro.synthesizeDetailed(text: text)
                try Task.checkCancellation()
                let samples = Self.robotize(speech.samples, sampleRate: Float(speech.sampleRate))
                let levels = Self.loudness(samples, sampleRate: speech.sampleRate)
                try activateAudio()
                let player = try AVAudioPlayer(data: Self.wav(samples, sampleRate: speech.sampleRate))
                self.player = player
                player.play()
                animateMouth { [weak player] in
                    guard let player, player.isPlaying else { return nil }
                    return levels[min(Int(player.currentTime * 30), levels.count - 1)]
                }
            } catch is CancellationError {
            } catch {
                speakWithSystemVoice(text)
            }
        }
    }

    func stop() {
        speaking?.cancel()
        speaking = nil
        mouth?.cancel()
        mouth = nil
        onLevel(0)
        player?.stop()
        player = nil
        fallback.stopSpeaking(at: .immediate)
    }

    /// Give a voice a light robotic tone: a faint 90 Hz shimmer and a short metallic echo,
    /// kept subtle so the voice stays friendly.
    nonisolated static func robotize(_ samples: [Float], sampleRate: Float) -> [Float] {
        let shimmer: Float = 90
        let echo = Int(sampleRate * 0.004)
        var out = [Float](repeating: 0, count: samples.count)
        for n in samples.indices {
            let t = Float(n) / sampleRate
            var y = samples[n] * (0.85 + 0.15 * sin(2 * .pi * shimmer * t))
            if n >= echo { y += 0.3 * out[n - echo] }
            out[n] = y
        }
        // Bring the loudest point back to just under full scale.
        let peak = out.map(abs).max() ?? 0
        return peak > 0 ? out.map { $0 * 0.9 / peak } : out
    }

    /// How loud the speech is in each 1/30 s, 0...1, for the mouth.
    nonisolated static func loudness(_ samples: [Float], sampleRate: Int) -> [Float] {
        let window = max(1, sampleRate / 30)
        var levels: [Float] = []
        var start = 0
        while start < samples.count {
            let chunk = samples[start..<min(start + window, samples.count)]
            levels.append((chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot())
            start += window
        }
        let loudest = levels.max() ?? 0
        // Square root so quieter syllables still show.
        return loudest > 0 ? levels.map { ($0 / loudest).squareRoot() } : [0]
    }

    /// Report the mouth level every frame until `level` returns nil, then close the mouth.
    private func animateMouth(_ level: @escaping @MainActor () -> Float?) {
        mouth?.cancel()
        mouth = Task {
            while !Task.isCancelled, let value = level() {
                onLevel(value)
                try? await Task.sleep(for: .milliseconds(33))
            }
            onLevel(0)
        }
    }

    /// 16-bit mono PCM WAV, for `AVAudioPlayer`.
    nonisolated static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func add<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); add(UInt32(16)); add(UInt16(1)); add(UInt16(1))
        add(UInt32(sampleRate)); add(UInt32(sampleRate * 2)); add(UInt16(2)); add(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); add(UInt32(bytes))
        for sample in samples { add(Int16(max(-1, min(1, sample)) * 32767)) }
        return data
    }

    private func speakWithSystemVoice(_ text: String) {
        try? activateAudio()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice
        // A little higher and quicker than a person, like a toy robot.
        utterance.pitchMultiplier = 0.8
        fallback.speak(utterance)
        // No loudness to follow here, so the mouth flickers while the system voice talks.
        let start = Date()
        animateMouth { [fallback] in
            let t = Date().timeIntervalSince(start)
            guard t < 0.3 || fallback.isSpeaking else { return nil }
            return Float(0.5 + 0.5 * sin(t * 18))
        }
    }

    private func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
    }
}
