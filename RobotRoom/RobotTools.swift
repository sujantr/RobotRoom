import FoundationModels
import simd

// How the chat makes the robot act. The on-device model reads short notes about the room
// (where the robot is, what it holds, what's in reach) and the player's message, and writes
// a `RobotPlan`: the goal, and the steps to reach it, built from a few simple moves. The
// small model doesn't always plan right, so `PlanCheck` plays the steps through a simple
// model of the room first. If they don't reach the goal, the app works out the steps for
// the goal the model chose.
// The app then carries out the steps one by one and reports what actually happened.

/// Whether the robot can do what the player asks. Asked on its own before planning: a
/// narrow question the small model answers well, so it doesn't swap in a similar move.
/// A walk with a set direction or distance needs no planning, so it's picked up here too.
@Generable
struct RequestKind {
    @Guide(description: """
        talk: chatting or a question. walkDistance: only when the message says a direction word (left, right, \
        forward, back) or a distance, like "walk left 2 meters". doable: anything else the robot can do, \
        including "come here". notPossible: something it can't do.
        """)
    var kind: Kind
    @Guide(description: "For walkDistance only: which way")
    var direction: RobotPlan.Direction?
    @Guide(description: "For walkDistance only: how many meters. 1 if not said.")
    var meters: Double?

    @Generable
    enum Kind { case talk, walkDistance, doable, notPossible }

    static let instructions = """
        A toy robot in a play room can only do these things: walk to the ball, the butter, the table, the \
        player, a wall or the middle of the room; walk a direction or a distance; pick up the ball or the \
        butter; drop it; carry it; put it on the table; bring or pass it to the player. The room has only the \
        robot, a ball, a butter, a table and the player.
        Decide whether the player's message asks for one of those things.
        - "walk left 2 meters", "go forward a bit", "step back": walkDistance.
        - "come here", "come to me", "go to the table", "go to the middle of the room", "pick up the ball", \
        "pass the butter", "bring me the ball", "put the butter on the table", "drop it": doable.
        - "jump", "dance", "spin around", "sit down", "wave at me", "kick the ball", "throw it to me", \
        "eat the butter", "go to the door", "turn on the light": notPossible.
        - "hi", "how are you?", "where is the butter?": talk.
        """

    @MainActor static let warm = WarmSession(instructions: instructions, promptPrefix: "The player says: ")

    @MainActor static func of(_ text: String) async throws -> RequestKind {
        try await warm.take()
            .respond(to: "The player says: \(text)", generating: RequestKind.self, options: GenerationOptions(sampling: .greedy)).content
    }
}

@Generable
struct RobotPlan {
    @Guide(description: """
        What the player wants to end up with. holdBall, holdButter: pick up, get, grab or fetch it. \
        ballOnTable, butterOnTable: put it on the table. ballToPlayer, butterToPlayer: bring, pass or give it \
        to the player. dropped: drop it or let go, right where the robot is. beAtPlayer: come here, come to \
        the player. beAt...: go or walk to a thing or place.
        """)
    var goal: Goal

    @Guide(description: "The steps that reach the goal from where things are now, in order. Empty when there's nothing to do.", .maximumCount(6))
    var steps: [Step]

    @Generable
    enum Goal {
        case beAtPlayer, beAtBall, beAtButter, beAtTable, beAtMiddle, beAtLeftWall, beAtRightWall, beAtBackWall
        case holdBall, holdButter
        case ballOnTable, butterOnTable
        case ballToPlayer, butterToPlayer
        case dropped
        /// Set by the app, not chosen by the planner.
        case moveByMeters(direction: Direction, meters: Double)
        case justTalk, cannotDo
    }

    @Generable
    enum Step {
        case walkToPlayer, walkToBall, walkToButter, walkToTable, walkToMiddle, walkToLeftWall, walkToRightWall, walkToBackWall
        case moveByMeters(direction: Direction, meters: Double)
        case pickUpBall, pickUpButter, drop
    }

    @Generable
    enum Direction {
        /// forward and backward follow the way the robot faces; the rest are as the player sees the room.
        case forward, backward, left, right, towardBackWall, towardFront
    }

    /// What the planner knows about the robot's moves and how the room works.
    static let instructions = """
        You plan the moves of a toy robot in a play room. Read the notes about the room and the player's \
        message. Choose what the player wants to end up with, then list the steps that get there.

        The moves:
        - walkToPlayer: walk to the player, wherever they are.
        - walkToBall, walkToButter, walkToTable: walk until right next to it, wherever it is.
        - walkToMiddle, walkToLeftWall, walkToRightWall, walkToBackWall: walk to that part of the room.
        - pickUpBall, pickUpButter: lift it. Only works right next to it, so walk to it first unless the notes \
        say it is within reach. The robot holds one thing at a time, so drop what it holds first.
        - drop: let go of what the robot holds, where it stands. Dropping right after walkToTable leaves it \
        on the table.

        Rules:
        - Do only what the player asks, plus any steps that must come first. Skip steps that are already done.

        Examples:
        - "come here": goal beAtPlayer, steps walkToPlayer.
        - "go to the table": goal beAtTable, steps walkToTable.
        - "pass the butter", holding nothing: goal butterToPlayer, steps walkToButter, pickUpButter, walkToPlayer.
        - "pass the butter", holding the ball: goal butterToPlayer, steps drop, walkToButter, pickUpButter, \
        walkToPlayer.
        - "put the ball on the table", holding nothing: goal ballOnTable, steps walkToBall, pickUpBall, \
        walkToTable, drop.
        - "pick up the ball", ball not within reach: goal holdBall, steps walkToBall, pickUpBall.
        - "drop it", holding the butter: goal dropped, steps drop.
        """

    @MainActor static let warm = WarmSession(instructions: instructions, promptPrefix: "Notes about the room:\n")

    /// Ask the model for a plan and check it. Returns the goal, the steps to take and a note
    /// on how the plan was made.
    @MainActor static func make(for text: String, notes: String, world: PlanCheck.World) async throws -> (goal: Goal, steps: [Step], note: String) {
        let request = try await RequestKind.of(text)
        switch request.kind {
        case .talk: return (.justTalk, [], "model: talk")
        case .notPossible: return (.cannotDo, [], "model: not possible")
        case .walkDistance:
            let direction = request.direction ?? .forward, meters = request.meters ?? 1
            return (.moveByMeters(direction: direction, meters: meters), [.moveByMeters(direction: direction, meters: meters)], "model: walk")
        case .doable: break
        }
        let plan = try await warm.take().respond(
            to: "Notes about the room:\n\(notes)\n\nThe player says: \(text)", generating: RobotPlan.self,
            options: GenerationOptions(sampling: .greedy)
        ).content
        // If the model's steps don't work, use the app's steps for the goal the model chose.
        // (Asking the model to fix its plan took another ~3 s on the phone and often failed again.)
        let check = PlanCheck(world: world)
        guard check.problem(with: plan.steps, goal: plan.goal) != nil else { return (plan.goal, plan.steps, "model") }
        return (plan.goal, check.steps(toReach: plan.goal), "worked out by the app for goal \(plan.goal)")
    }
}

/// A simple model of the room for checking plans: what the robot is next to, what it holds,
/// and what's on the table. It knows each move's needs and effects.
struct PlanCheck {
    enum Spot: Hashable { case item(Item), table, player, middle, leftWall, rightWall, backWall }

    struct World {
        var near: Set<Spot>
        var held: Item?
        var onTable: Set<Item>
    }

    let world: World

    /// What's wrong with these steps for this goal, or nil when they work.
    func problem(with steps: [RobotPlan.Step], goal: RobotPlan.Goal) -> String? {
        var w = world
        var droppedAt: Set<Spot> = []
        for (index, step) in steps.enumerated() {
            let n = index + 1
            switch step {
            case .walkToBall: w.walk(to: .item(.ball))
            case .walkToButter: w.walk(to: .item(.butter))
            case .walkToTable: w.walk(to: .table)
            case .walkToPlayer: w.walk(to: .player)
            case .walkToMiddle: w.walk(to: .middle)
            case .walkToLeftWall: w.walk(to: .leftWall)
            case .walkToRightWall: w.walk(to: .rightWall)
            case .walkToBackWall: w.walk(to: .backWall)
            case .moveByMeters: w.near = []
            case .pickUpBall, .pickUpButter:
                let item: Item = step == .pickUpBall ? .ball : .butter
                if w.held == item { return "Step \(n): the robot is already holding \(item.name)." }
                if w.held != nil { return "Step \(n): the robot's hands are full, so drop must come first." }
                if !w.near.contains(.item(item)) { return "Step \(n): \(item.name) isn't within reach yet." }
                w.held = item
                w.onTable.remove(item)
            case .drop:
                guard let item = w.held else { return "Step \(n): the robot isn't holding anything to drop." }
                w.held = nil
                if w.near.contains(.table) { w.onTable.insert(item) }
                w.near.insert(.item(item))
                droppedAt = w.near
            }
        }
        let reached: Bool = switch goal {
        case .justTalk, .cannotDo: steps.isEmpty
        case .beAtPlayer: w.near.contains(.player)
        case .beAtBall: w.near.contains(.item(.ball)) || w.held == .ball
        case .beAtButter: w.near.contains(.item(.butter)) || w.held == .butter
        case .beAtTable: w.near.contains(.table)
        case .beAtMiddle: w.near.contains(.middle)
        case .beAtLeftWall: w.near.contains(.leftWall)
        case .beAtRightWall: w.near.contains(.rightWall)
        case .beAtBackWall: w.near.contains(.backWall)
        case .moveByMeters: steps.count == 1
        case .holdBall: w.held == .ball
        case .holdButter: w.held == .butter
        case .ballOnTable: w.onTable.contains(.ball)
        case .butterOnTable: w.onTable.contains(.butter)
        case .ballToPlayer: w.near.contains(.player) && (w.held == .ball || droppedAt.contains(.player))
        case .butterToPlayer: w.near.contains(.player) && (w.held == .butter || droppedAt.contains(.player))
        case .dropped: w.held == nil
        }
        return reached ? nil : "After these steps the goal \(goal) isn't reached."
    }

    /// Steps that reach the goal from the current room, worked out without the model.
    func steps(toReach goal: RobotPlan.Goal) -> [RobotPlan.Step] {
        func fetch(_ item: Item) -> [RobotPlan.Step] {
            if world.held == item { return [] }
            let free: [RobotPlan.Step] = world.held == nil ? [] : [.drop]
            let walk: [RobotPlan.Step] = world.near.contains(.item(item)) && world.held == nil
                ? [] : [item == .ball ? .walkToBall : .walkToButter]
            return free + walk + [item == .ball ? .pickUpBall : .pickUpButter]
        }
        return switch goal {
        case .justTalk, .cannotDo: []
        case .beAtPlayer: [.walkToPlayer]
        case .beAtBall: world.held == .ball ? [] : [.walkToBall]
        case .beAtButter: world.held == .butter ? [] : [.walkToButter]
        case .beAtTable: [.walkToTable]
        case .beAtMiddle: [.walkToMiddle]
        case .beAtLeftWall: [.walkToLeftWall]
        case .beAtRightWall: [.walkToRightWall]
        case .beAtBackWall: [.walkToBackWall]
        case let .moveByMeters(direction, meters): [.moveByMeters(direction: direction, meters: meters)]
        case .holdBall: fetch(.ball)
        case .holdButter: fetch(.butter)
        case .ballOnTable: world.onTable.contains(.ball) ? [] : fetch(.ball) + [.walkToTable, .drop]
        case .butterOnTable: world.onTable.contains(.butter) ? [] : fetch(.butter) + [.walkToTable, .drop]
        case .ballToPlayer: fetch(.ball) + [.walkToPlayer]
        case .butterToPlayer: fetch(.butter) + [.walkToPlayer]
        case .dropped: world.held == nil ? [] : [.drop]
        }
    }
}

private extension PlanCheck.World {
    /// After walking somewhere, the robot is next to that spot only. Things on the table are
    /// within reach from the table, and the table is next to whatever is on it.
    mutating func walk(to spot: PlanCheck.Spot) {
        near = [spot]
        if spot == .table {
            for item in onTable { near.insert(.item(item)) }
        }
        if case let .item(item) = spot, onTable.contains(item) { near.insert(.table) }
    }
}

extension RobotPlan.Step: Equatable {
    static func == (a: RobotPlan.Step, b: RobotPlan.Step) -> Bool { a.words == b.words }
}

extension RobotPlan.Step {
    /// The step in plain words, for the robot's reply: "walked to the table".
    var words: String {
        switch self {
        case .walkToPlayer: "came over to the player you're talking to"
        case .walkToBall: "walked to the ball"
        case .walkToButter: "walked to the butter"
        case .walkToTable: "walked to the table"
        case .walkToMiddle: "walked to the middle of the room"
        case .walkToLeftWall: "walked to the left wall"
        case .walkToRightWall: "walked to the right wall"
        case .walkToBackWall: "walked to the back wall"
        case let .moveByMeters(direction, meters): "walked \(meters.formatted()) m \(direction.words)"
        case .pickUpBall: "picked up the ball"
        case .pickUpButter: "picked up the butter"
        case .drop: "put down what you were holding"
        }
    }
}

extension RobotPlan.Direction {
    var words: String {
        switch self {
        case .forward: "forward"
        case .backward: "backward"
        case .left: "to the left"
        case .right: "to the right"
        case .towardBackWall: "toward the back wall"
        case .towardFront: "toward the front"
        }
    }
}

extension RoomScene {
    /// Carry out a plan step by step, stopping at the first step that fails. Returns what
    /// happened and whether every step worked, or nil when there was nothing to do.
    func perform(_ steps: [RobotPlan.Step]) async -> (report: String, succeeded: Bool)? {
        guard !steps.isEmpty else { return nil }
        var done: [String] = []
        for (index, step) in steps.enumerated() {
            let (report, ok) = await perform(step)
            done.append(report)
            if !ok {
                if index < steps.count - 1 { done.append("Stopped there, so the rest of the plan didn't happen.") }
                return (done.joined(separator: " "), false)
            }
        }
        return (done.joined(separator: " "), true)
    }

    private func perform(_ step: RobotPlan.Step) async -> (String, Bool) {
        switch step {
        case .walkToPlayer: return await goToPlayer()
        case .walkToBall: return await goTo(.ball)
        case .walkToButter: return await goTo(.butter)
        case .walkToTable: return await goToTable()
        case .walkToMiddle: return await goTo(SIMD2(0, 0), "the middle of the room")
        case .walkToLeftWall: return await goTo(SIMD2(-2.4, 0), "the left wall")
        case .walkToRightWall: return await goTo(SIMD2(2.4, 0), "the right wall")
        case .walkToBackWall: return await goTo(SIMD2(0, -2.4), "the back wall")
        case let .moveByMeters(direction, meters): return await walk(direction, meters: Float(meters))
        case .pickUpBall: return await pickUpItem(.ball)
        case .pickUpButter: return await pickUpItem(.butter)
        case .drop:
            let holding = await MainActor.run { hand.held != nil }
            return (await drop(), holding)
        }
    }

    private func goTo(_ item: Item) async -> (String, Bool) {
        if await MainActor.run(body: { hand.held == item }) { return ("You are already holding \(item.name).", true) }
        let (result, walked) = await walk(to: .item(item))
        return result == .reached
            ? (String(format: "Walked %.1f m to %@.", walked, item.name), true)
            : (report(result, walked: walked) + " Didn't reach \(item.name).", false)
    }

    /// The robot heads for the middle of the table, and the table stops it at the edge.
    private func goToTable() async -> (String, Bool) {
        let table = SIMD2(tablePosition.x, tablePosition.z)
        let (result, walked) = await walk(to: .point(table))
        let distance = await MainActor.run { simd_length(robotFloorPosition - table) }
        return distance < 1.2
            ? (String(format: "Walked %.1f m to the table.", walked), true)
            : (report(result, walked: walked) + " Didn't reach the table.", false)
    }

    private func goToPlayer() async -> (String, Bool) {
        let (result, walked) = await walk(to: .player)
        let distance = await MainActor.run { simd_length(robotFloorPosition - playerSpot(from: robotFloorPosition)) }
        return result == .reached || distance < 0.6
            ? (String(format: "Walked %.1f m over to the player.", walked), true)
            : (report(result, walked: walked) + " Didn't reach the player.", false)
    }

    private func goTo(_ point: SIMD2<Float>, _ name: String) async -> (String, Bool) {
        let (result, walked) = await walk(to: .point(point))
        let distance = await MainActor.run { simd_length(robotFloorPosition - point) }
        return distance < 0.6
            ? (String(format: "Walked %.1f m to %@.", walked, name), true)
            : (report(result, walked: walked) + " Didn't reach \(name).", false)
    }

    private func walk(_ direction: RobotPlan.Direction, meters: Float) async -> (String, Bool) {
        let meters = min(max(meters, 0.1), 6)
        let (start, facing) = await MainActor.run { (robotFloorPosition, robotFacing) }
        let step: SIMD2<Float> = switch direction {
        case .forward: facing
        case .backward: -facing
        case .left: SIMD2(-1, 0)
        case .right: SIMD2(1, 0)
        case .towardBackWall: SIMD2(0, -1)
        case .towardFront: SIMD2(0, 1)
        }
        let (result, walked) = await walk(to: .point(start + step * meters))
        return (report(result, walked: walked), result == .reached)
    }

    /// Pick something up. If it's out of reach (the plan skipped walking to it, or it got
    /// nudged), walk up to it first.
    private func pickUpItem(_ item: Item) async -> (String, Bool) {
        if await MainActor.run(body: { hand.held == item }) { return ("You are already holding \(item.name).", true) }
        if let other = await MainActor.run(body: { hand.held }) { return ("Your hands are full: you are holding \(other.name).", false) }
        var walked: Float = 0
        for _ in 0..<3 {
            if await pickUp(item) == "Picked up \(item.name)." {
                return (walked < 0.05 ? "Picked up \(item.name)." : String(format: "Walked %.1f m to %@ and picked it up.", walked, item.name), true)
            }
            let (result, distance) = await walk(to: .item(item))
            walked += distance
            guard result == .reached else { return (report(result, walked: walked) + " Couldn't reach \(item.name).", false) }
        }
        return ("Couldn't get hold of \(item.name).", false)
    }

    private func report(_ result: WalkResult, walked: Float) -> String {
        switch result {
        case .reached:
            String(format: "Walked %.1f m.", walked)
        case .blocked:
            String(format: "Walked %.1f m, then something blocked the way.", walked)
        case .interrupted:
            String(format: "Walked %.1f m, then the player took over with the joystick.", walked)
        case .timedOut:
            String(format: "Walked %.1f m and gave up before getting there.", walked)
        }
    }
}
