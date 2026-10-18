import AVFoundation
import FluidAudio

/// Speech to text with NVIDIA's Parakeet TDT 0.6B v3, run on device through FluidAudio's
/// Core ML port. Tap to start listening, tap again to get the words. The model downloads
/// the first time it's needed and stays loaded after that.
@MainActor @Observable
final class SpeechInput {
    enum Status: Equatable {
        case idle
        case listening
        case transcribing
    }

    private(set) var status: Status = .idle
    /// Shown while the model downloads and loads, e.g. "Downloading speech model 40%".
    private(set) var modelStatus: String?
    private(set) var error: String?

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private let engine = AVAudioEngine()
    private let recorder = Recorder()

    /// Load the model ahead of time, so it's ready by the first tap.
    func prepare() {
        _ = loadModel()
    }

    /// Start recording. The model loads in the background meanwhile, so you can speak right away.
    func start() async {
        guard status == .idle else { return }
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Allow the microphone in Settings to talk to the robot."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            recorder.reset()
            Self.installTap(on: engine.inputNode, recorder: recorder)
            try engine.start()
            status = .listening
        } catch {
            stopEngine()
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        _ = loadModel()
    }

    /// Stop recording and return what was said, or nil if nothing was heard.
    func stop() async -> String? {
        guard status == .listening else { return nil }
        stopEngine()
        status = .transcribing
        defer { status = .idle }

        let (samples, rate) = recorder.take()
        // Less than a third of a second is a tap, not speech.
        guard Double(samples.count) / rate > 0.3 else { return nil }
        do {
            var audio = try AudioConverter().resample(samples, from: rate)
            // The model wants at least a second of audio.
            if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
            let manager = try await loadModel().value
            var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let text = try await manager.transcribe(audio, decoderState: &decoder).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            self.error = "Couldn't understand that: \(error.localizedDescription)"
            return nil
        }
    }

    private func loadModel() -> Task<AsrManager, Error> {
        if let manager { return Task { manager } }
        if let loading { return loading }
        modelStatus = "Loading speech model…"
        let task = Task { [weak self] in
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                    // Only the first launch downloads; after that the files are on the phone
                    // and just need preparing.
                    let status = switch progress.phase {
                    case .listing: "Checking speech model…"
                    case .downloading: "Downloading speech model \(Int(progress.fractionCompleted * 100))%"
                    case .compiling: "Preparing speech model…"
                    }
                    Task { @MainActor in self?.modelStatus = status }
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                self?.manager = manager
                self?.modelStatus = nil
                return manager
            } catch {
                self?.loading = nil
                self?.modelStatus = nil
                self?.error = "Couldn't load the speech model: \(error.localizedDescription)"
                throw error
            }
        }
        loading = task
        return task
    }


    private func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Kept off the main actor: the tap runs on an audio thread.
    nonisolated private static func installTap(on input: AVAudioInputNode, recorder: Recorder) {
        let format = input.outputFormat(forBus: 0)
        recorder.sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.append(buffer)
        }
    }
}

/// Collects microphone samples (first channel) from the audio thread.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    var sampleRate: Double = 48_000

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func take() -> ([Float], Double) {
        lock.withLock {
            defer { samples.removeAll() }
            return (samples, sampleRate)
        }
    }
}
