import SwiftUI
import FoundationModels

/// The robot's side of the chat: on-device Foundation Models sessions that plan what to do
/// and reply, each started fresh with a snapshot of the room.
@MainActor @Observable
final class RobotChat {
    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    let room = RoomScene()
    /// What the player says to the robot.
    let speech = SpeechInput()
    /// The robot's voice, reading its replies aloud.
    let voice = RobotVoice()

    init() {
        // The robot's mouth lights up as it talks.
        voice.onLevel = { [room] level in room.mouthLevel = level }
    }
    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    private static let persona = """
        You are a small, friendly toy robot in a cozy play room with a red ball, a butter and a table. \
        Reply as the robot, in one or two short, cheerful sentences. \
        You get notes about the room, for you only: use them, but don't repeat them. \
        The only things in the room are you, the ball, the butter and the table; never make up anything else. \
        Say only what "What happened" says, and add nothing else that happened. \
        Only mention the table if "What happened" mentions it. \
        If something didn't work, say so honestly.
        """

    private let replies = WarmSession(instructions: persona, promptPrefix: "Notes about the play room (for you only):\n")

    /// Load the model and every session's instructions ahead of the first message.
    func warmUp() {
        guard unavailableReason == nil else { return }
        RequestKind.warm.warm()
        RobotPlan.warm.warm()
        replies.warm()
    }

    /// Why the model can't be used on this device, or nil when it can.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to talk to the robot."
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading. Try again in a little while."
        case .unavailable:
            "The on-device model isn't available."
        }
    }

    func send(_ text: String) async {
        messages.append(Message(fromUser: true, text: text))
        isThinking = true
        defer { isThinking = false }

        do {
            // 1. Plan the steps the message asks for, knowing the room, and carry them out.
            let plan = try await RobotPlan.make(for: text, notes: room.planningNotes(), world: room.planningWorld())
            // While the robot walks, write the reply as if everything works, so it's ready
            // the moment the robot is done. If something goes wrong, it's rewritten below.
            let landsOnTable = plan.steps.lastIndex(of: .drop).map { $0 > 0 && plan.steps[$0 - 1] == .walkToTable }
            let hopeful = plan.steps.isEmpty ? nil : Task {
                let words = plan.steps.enumerated().map { index, step in
                    guard step == .drop else { return step.words }
                    return index > 0 && plan.steps[index - 1] == .walkToTable ? "put it down on the table" : "put it down on the floor"
                }.joined(separator: ", then ")
                return try await reply(to: text, happened: "You \(words), just as the player asked. It all worked.", fallback: nil, withNotes: false)
            }
            let outcome = await room.perform(plan.steps)

            // 2. Reply as the robot, knowing the room and what actually happened.
            let happened: String
            if case .cannotDo = plan.goal {
                happened = "You did nothing, because you can't do that. Say plainly that you can't, without a reason. You can walk around the room and to the player, and pick up, carry, pass and put down the ball and the butter."
            } else if let outcome {
                happened = "You just did this: \(outcome.report) " + (outcome.succeeded ? "It all worked." : "It did NOT fully work: only those things happened.")
            } else if case .justTalk = plan.goal {
                happened = "Nothing: this is just chat. Answer using the notes."
            } else {
                happened = "Nothing, because what the player asked for was already done."
            }
            let answer: String
            // The reply written during the walk guessed where a dropped thing lands; use it only if
            // that guess was right.
            let landedAsGuessed = landsOnTable.map { $0 == (outcome?.report.contains("landed on the table") == true) } ?? true
            if let hopeful, outcome?.succeeded == true, landedAsGuessed {
                answer = try await hopeful.value
            } else {
                hopeful?.cancel()
                answer = try await reply(to: text, happened: happened, fallback: outcome?.report)
            }
            messages.append(Message(fromUser: false, text: answer))
            voice.speak(answer)
        } catch {
            messages.append(Message(fromUser: false, text: "(Error: \(error.localizedDescription))"))
        }
    }

    /// The robot's reply, from a fresh session each time (see `WarmSession`): a long-running chat fills the small
    /// on-device context quickly, and the model starts copying its own earlier replies and
    /// bringing up things that happened before. If the prompt still doesn't fit the context,
    /// it falls back to the plain report of what happened.
    private func reply(to text: String, happened: String, fallback: String?, withNotes: Bool = true) async throws -> String {
        let notes = withNotes ? "Notes about the play room (for you only):\n\(room.planningNotes())\n\n" : ""
        let now = "The player says: \(text)\n\nWhat happened: \(happened)\n\nYour short reply:"
        func echoes(_ reply: String) -> Bool { reply.contains("Notes about the play room") || reply.contains("The room is 6 m wide") }

        let prompt = notes + now
        for _ in 0..<2 {
            do {
                let answer = try await replies.take()
                    .respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 80)).content
                if !echoes(answer) { return answer }
            } catch let error as LanguageModelSession.GenerationError {
                // Too long for the model's context: start a new chat and try again.
                guard case .exceededContextWindowSize = error else { throw error }
            }
        }
        return fallback ?? "Beep boop!"
    }
}

/// The chat, written over the room: just the latest exchange, small, at the top of the
/// screen. It fades away a few seconds after the robot answers.
struct ChatOverlay: View {
    let chat: RobotChat
    @State private var visible = true

    var body: some View {
        VStack(spacing: 6) {
            if let reason = chat.unavailableReason {
                Label(reason, systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if visible || chat.isThinking {
                ForEach(chat.messages.suffix(2)) { message in
                    MessageBubble(message: message)
                        .transition(.opacity)
                }
                if chat.isThinking {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal)
        .animation(.default, value: chat.messages.count)
        .animation(.default, value: chat.isThinking)
        .animation(.easeOut(duration: 0.6), value: visible)
        .task(id: chat.messages.count) {
            // Show each new message, then fade it out.
            visible = true
            try? await Task.sleep(for: .seconds(8))
            visible = false
        }
    }
}

/// Tap once to talk to the robot, again to send what you said.
struct MicButton: View {
    let chat: RobotChat

    var body: some View {
        let listening = chat.speech.status == .listening
        VStack(alignment: .trailing, spacing: 6) {
            if let note = chat.speech.error ?? chat.speech.modelStatus ?? chat.voice.status ?? hint {
                Text(note)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
            Button(action: toggleListening) {
                Image(systemName: listening ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .symbolEffect(.pulse, isActive: listening)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(listening ? .red : .accentColor)
            .disabled(chat.unavailableReason != nil || chat.isThinking || chat.speech.status == .transcribing)
        }
    }

    private var hint: String? {
        switch chat.speech.status {
        case .idle: nil
        case .listening: "Listening… tap to stop"
        case .transcribing: "Working out what you said…"
        }
    }

    private func toggleListening() {
        let speech = chat.speech
        Task {
            if speech.status == .listening {
                if let text = await speech.stop(), !chat.isThinking {
                    await chat.send(text)
                }
            } else {
                // Don't let the robot talk over you.
                chat.voice.stop()
                await speech.start()
            }
        }
    }
}

private struct MessageBubble: View {
    let message: RobotChat.Message

    var body: some View {
        HStack {
            if message.fromUser { Spacer(minLength: 80) }
            Text(message.text)
                .font(.footnote)
                .lineLimit(3)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(message.fromUser ? Color.white : Color.primary)
                .background {
                    if message.fromUser {
                        RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.85))
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                    }
                }
            if !message.fromUser { Spacer(minLength: 80) }
        }
    }
}
