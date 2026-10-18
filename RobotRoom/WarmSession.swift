import FoundationModels

/// Keeps a fresh model session ready with its instructions already loaded, so a request
/// doesn't wait for the model to read them first. Each session is used once; taking it
/// starts warming the next one.
@MainActor
final class WarmSession {
    private let instructions: String
    private let promptPrefix: String
    private var ready: LanguageModelSession?

    init(instructions: String, promptPrefix: String) {
        self.instructions = instructions
        self.promptPrefix = promptPrefix
    }

    /// Load the model and the instructions now, ahead of the first request.
    func warm() {
        guard ready == nil else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm(promptPrefix: Prompt(promptPrefix))
        ready = session
    }

    /// A session ready to use. The next one starts warming straight away.
    func take() -> LanguageModelSession {
        let session = ready ?? LanguageModelSession(instructions: instructions)
        ready = nil
        warm()
        return session
    }
}
