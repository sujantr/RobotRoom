import SwiftUI
import SceneKit

struct RoomView: View {
    @State private var chat = RobotChat()

    var body: some View {
        let hand = chat.room.hand

        RoomSceneView(room: chat.room)
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                Joystick { chat.room.joystick = $0 }
                    .padding(24)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 16) {
                    Button {
                        chat.room.toggleHold()
                    } label: {
                        Label(hand.held != nil ? "Drop" : "Pick up",
                              systemImage: hand.held != nil ? "arrow.down.to.line" : "hand.raised.fill")
                            .font(.headline)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(hand.held == nil && hand.reachable == nil)

                    MicButton(chat: chat)
                }
                .padding(24)
            }
            .task {
                chat.speech.prepare()
                chat.voice.prepare()
                chat.warmUp()
            }
            .overlay(alignment: .top) {
                ChatOverlay(chat: chat)
                    .padding(.top, 8)
            }
    }
}

/// The things in the room the robot can pick up and carry, one at a time.
enum Item: CaseIterable, Sendable {
    case ball, butter

    var name: String {
        switch self {
        case .ball: "the ball"
        case .butter: "the butter"
        }
    }
}

/// What the Pick up / Drop button needs to know. Only changed on the main thread.
@Observable
final class HandState {
    /// What the robot is carrying, if anything.
    var held: Item?
    /// The nearest thing the robot could pick up right now.
    var reachable: Item?
    /// Every thing within reach right now.
    var inReach: Set<Item> = []
}

/// The scene, the robot's walking and carrying (by joystick or by the chat), and the game
/// state the chat reads. Shared between the main and render threads, guarded by `lock`.
final class RoomScene: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let scene: SCNScene
    let robot: SCNNode
    let ball: SCNNode
    let butter: SCNNode
    let hand = HandState()

    private let walkSpeed: Float = 1.5   // m/s at full stick
    private let turnSpeed: Float = 8     // rad/s
    private let lock = NSLock()
    private var stick = SIMD2<Float>.zero
    private var holdRequest: HoldRequest?  // set from the main thread, handled on the render thread
    private var ballSpeed: Float = 0     // measured each frame; physicsBody.velocity goes stale
    private var cameraFloor = SIMD2<Float>(0, 2.8)  // where the camera is, on the floor plan
    private var voiceLevel: Float = 0    // how loud the robot is talking, 0...1, set by its voice

    private enum HoldRequest { case toggle, pickUp(Item) }

    /// How a walk ordered by the chat ended.
    enum WalkResult: Sendable { case reached, blocked, interrupted, timedOut }
    /// Where a walk ordered by the chat goes.
    enum WalkTarget: Sendable {
        /// A point on the floor (x, z).
        case point(SIMD2<Float>)
        /// Up to a thing, until it's within reach.
        case item(Item)
        /// To the player: in front of the camera, wherever it is, and kept inside the room.
        case player
    }
    private struct WalkOrder { let id: Int; let target: WalkTarget }
    private var nextOrderID = 0
    private var pendingOrder: WalkOrder?
    private var finishedOrders: [Int: (WalkResult, Float)] = [:]

    // Render-thread state
    private var lastTime: TimeInterval?
    private var stride: Float = 0        // 0 = standing, 1 = full walking swing
    private var stridePhase: Float = 0
    private var armLift: Float = 0       // 0 = arms down, 1 = arms forward carrying something
    private var held: Item?
    private var lastBallPosition: SIMD3<Float>?
    private var publishedReach: Set<Item> = []
    private var order: WalkOrder?
    private var orderStart = SIMD2<Float>.zero
    private var orderTime: Float = 0
    private var closestToGoal: Float = .infinity
    private var stallTime: Float = 0
    private var mouthGlow: Float = 0

    override init() {
        (scene, robot, ball, butter) = makeScene()
    }

    func node(_ item: Item) -> SCNNode {
        switch item {
        case .ball: ball
        case .butter: butter
        }
    }

    /// Joystick deflection in -1...1, screen axes (x right, y down). Set from the UI thread.
    var joystick: CGVector {
        get { lock.withLock { CGVector(dx: CGFloat(stick.x), dy: CGFloat(stick.y)) } }
        set { lock.withLock { stick = SIMD2(Float(newValue.dx), Float(newValue.dy)) } }
    }

    /// How loud the robot is talking right now, 0...1. Its mouth lights up to match.
    var mouthLevel: Float {
        get { lock.withLock { voiceLevel } }
        set { lock.withLock { voiceLevel = newValue } }
    }

    /// Pick up the nearest thing in reach, or drop what's held. Called from the UI.
    func toggleHold() {
        lock.withLock { holdRequest = .toggle }
    }

    // MARK: Actions for the chat (main thread)

    var robotFloorPosition: SIMD2<Float> {
        let p = robot.presentation.simdWorldPosition
        return SIMD2(p.x, p.z)
    }

    /// The way the robot's face points, on the floor. SceneKit's "front" is -z; the robot's face is +z.
    var robotFacing: SIMD2<Float> {
        let f = -robot.presentation.simdWorldFront
        return simd_normalize(SIMD2(f.x, f.z))
    }

    func floorPosition(of item: Item) -> SIMD2<Float> {
        let p = node(item).presentation.simdWorldPosition
        return SIMD2(p.x, p.z)
    }

    /// Walk somewhere and wait until the walk ends. Returns how it ended and how far the robot walked.
    @MainActor func walk(to target: WalkTarget) async -> (WalkResult, Float) {
        let id = lock.withLock {
            nextOrderID += 1
            pendingOrder = WalkOrder(id: nextOrderID, target: target)
            return nextOrderID
        }
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(50))
            if let result = lock.withLock({ finishedOrders.removeValue(forKey: id) }) { return result }
        }
        return (.timedOut, 0)
    }

    @MainActor func pickUp(_ item: Item) async -> String {
        if hand.held == item { return "You are already holding \(item.name)." }
        if let other = hand.held { return "Your hands are full: you are holding \(other.name)." }
        // The render thread decides whether it's in reach right now; `hand.inReach` is a copy
        // that can lag a frame behind.
        lock.withLock { holdRequest = .pickUp(item) }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if hand.held == item { return "Picked up \(item.name)." }
        }
        return "\(item.name.prefix(1).uppercased() + item.name.dropFirst()) is out of reach."
    }

    @MainActor func drop() async -> String {
        guard let item = hand.held else { return "Nothing happened: your hands are empty, so there was nothing to drop." }
        toggleHold()
        // Give it time to fall and settle before saying where it landed.
        try? await Task.sleep(for: .seconds(1.5))
        return "Dropped \(item.name). It landed on \(isOnTable(item) ? "the table" : "the floor")."
    }

    // MARK: Per-frame update

    // Runs every frame on SceneKit's render thread.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = Float(min(time - (lastTime ?? time), 1.0 / 20))
        lastTime = time
        let camera = renderer.pointOfView?.presentation.simdWorldPosition ?? SIMD3(0, 1.5, 2.8)
        let (input, request, newOrder) = lock.withLock { () -> (SIMD2<Float>, HoldRequest?, WalkOrder?) in
            defer { holdRequest = nil; pendingOrder = nil }
            cameraFloor = SIMD2(camera.x, camera.z)
            return (stick, holdRequest, pendingOrder)
        }
        let stickAmount = min(simd_length(input), 1)
        if let newOrder {
            finishOrder(.interrupted)
            order = newOrder
            let p = robot.presentation.simdWorldPosition
            orderStart = SIMD2(p.x, p.z)
            orderTime = 0
            closestToGoal = .infinity
            stallTime = 0
        }

        // Pick up or drop.
        var inReach = held == nil ? Set(Item.allCases.filter(isInReach)) : []
        switch request {
        case .toggle:
            if held != nil {
                drop()
            } else if let nearest = nearestInReach(inReach) {
                pickUp(nearest)
            }
        case let .pickUp(item):
            if held == nil, inReach.contains(item) { pickUp(item) }
        case nil:
            break
        }
        if held != nil { inReach = [] }
        if request != nil || inReach != publishedReach {
            publishedReach = inReach
            let held = held
            let nearest = nearestInReach(inReach)
            DispatchQueue.main.async { [hand] in
                hand.held = held
                hand.inReach = inReach
                hand.reachable = nearest
            }
        }

        // Stick directions follow the camera, flattened onto the floor.
        var forward = SIMD3<Float>(0, 0, -1)
        if let pov = renderer.pointOfView {
            let front = pov.presentation.simdWorldFront
            let flat = SIMD3<Float>(front.x, 0, front.z)
            if simd_length(flat) > 0.01 { forward = simd_normalize(flat) }
        }
        let right = SIMD3<Float>(-forward.z, 0, forward.x)
        let move = right * input.x - forward * input.y

        let robotPosition = robot.presentation.simdWorldPosition
        let robotFloor = SIMD2(robotPosition.x, robotPosition.z)

        // Where to walk this frame: the joystick wins; otherwise follow the chat's walk order.
        var walkDirection: SIMD3<Float>?
        var amount: Float = 0
        if stickAmount > 0.05 {
            finishOrder(.interrupted)
            walkDirection = simd_normalize(move)
            amount = stickAmount
        } else if let current = order {
            let goal: SIMD2<Float>
            var reached: Bool
            switch current.target {
            case let .point(point):
                goal = point
                reached = simd_length(goal - robotFloor) < 0.05
            case let .item(item):
                let p = node(item).presentation.simdWorldPosition
                goal = SIMD2(p.x, p.z)
                reached = isInReach(item)
            case .player:
                goal = playerSpot(from: robotFloor)
                reached = simd_length(goal - robotFloor) < 0.1
            }
            let toGoal = goal - robotFloor
            let remaining = simd_length(toGoal)
            let speed: Float = if case .item = current.target { 1 } else { min(1, max(0.2, remaining / 0.4)) }
            orderTime += dt
            // Blocked when the goal hasn't come 2 cm closer for half a second. (Pushing against a
            // wall makes the robot jitter, so frame-to-frame movement isn't real progress.)
            if remaining < closestToGoal - 0.02 {
                closestToGoal = remaining
                stallTime = 0
            } else {
                stallTime += dt
            }

            if reached {
                finishOrder(.reached)
            } else if stallTime > 0.5 {
                finishOrder(.blocked)
            } else if orderTime > 12 {
                finishOrder(.timedOut)
            } else {
                walkDirection = SIMD3(toGoal.x / remaining, 0, toGoal.y / remaining)
                amount = speed
            }
        }

        // The robot is a dynamic body: this sets its velocity and turn rate, and the physics
        // engine handles the rest, so walls, the table and the ball push back.
        if let body = robot.physicsBody {
            var velocity = body.velocity
            if let direction = walkDirection {
                velocity.x = direction.x * walkSpeed * amount
                velocity.z = direction.z * walkSpeed * amount

                // Turn toward the walking direction. The robot's face is +z; SceneKit's front is -z.
                let facing = -robot.presentation.simdWorldFront
                let heading = atan2(facing.x, facing.z)
                let turn = remainder(atan2(direction.x, direction.z) - heading, 2 * .pi)
                body.angularVelocity = SCNVector4(0, 1, 0, min(max(turn * 10, -turnSpeed), turnSpeed))
            } else {
                velocity.x = 0
                velocity.z = 0
                body.angularVelocity = SCNVector4(0, 1, 0, 0)
            }
            body.velocity = velocity
        }

        // Walking animation: legs and arms swing opposite each other, easing to rest when
        // stopped. While carrying, the arms reach forward around what's held instead.
        stride += (amount - stride) * min(1, 10 * dt)
        stridePhase += dt * (6 + 6 * amount)
        armLift += ((held != nil ? 1 : 0) - armLift) * min(1, 12 * dt)
        let swing = sin(stridePhase) * 0.6 * stride
        let armSwing = swing * (1 - armLift)
        let carryAngle = -1.45 * armLift
        robot.childNode(withName: "leftHip", recursively: false)?.eulerAngles.x = swing
        robot.childNode(withName: "rightHip", recursively: false)?.eulerAngles.x = -swing
        robot.childNode(withName: "leftShoulder", recursively: false)?.eulerAngles.x = carryAngle - armSwing
        robot.childNode(withName: "rightShoulder", recursively: false)?.eulerAngles.x = carryAngle + armSwing

        // The mouth glows and opens with the robot's voice, easing so it doesn't flicker.
        let level = lock.withLock { voiceLevel }
        mouthGlow += (level - mouthGlow) * min(1, 25 * dt)
        if let mouth = robot.childNode(withName: "mouth", recursively: false) {
            mouth.scale.y = 1 + 1.2 * mouthGlow
            mouth.geometry?.firstMaterial?.emission.contents = UIColor.cyan
            mouth.geometry?.firstMaterial?.emission.intensity = CGFloat(mouthGlow)
        }

        // Ball speed from how far it moved since the last frame.
        let ballPosition = ball.presentation.simdWorldPosition
        if let last = lastBallPosition, dt > 0 {
            let speed = simd_length(ballPosition - last) / dt
            lock.withLock { ballSpeed = speed }
        }
        lastBallPosition = ballPosition
    }

    /// Where to stand to be with the player: a metre in front of the camera, toward the robot,
    /// kept inside the room. The camera usually sits outside the room's open front.
    func playerSpot(from robot: SIMD2<Float>) -> SIMD2<Float> {
        let camera = lock.withLock { cameraFloor }
        let toRobot = robot - camera
        let length = simd_length(toRobot)
        let spot = length > 1 ? camera + toRobot / length : robot
        // Stay well back from the open front: carried things stick out about 0.6 m ahead.
        return SIMD2(min(max(spot.x, -2.3), 2.3), min(max(spot.y, -2.3), 1.4))
    }

    /// End the current walk order, if any, and hand its result to the waiting caller.
    private func finishOrder(_ result: WalkResult) {
        guard let current = order else { return }
        let p = robot.presentation.simdWorldPosition
        let walked = simd_length(SIMD2(p.x, p.z) - orderStart)
        lock.withLock { finishedOrders[current.id] = (result, walked) }
        order = nil
    }

    /// The thing is in front of the robot, close enough to grab, on the floor or the table.
    private func isInReach(_ item: Item) -> Bool {
        let p = node(item).presentation.worldPosition
        let local = robot.presentation.convertPosition(p, from: nil)
        let distance = (local.x * local.x + local.z * local.z).squareRoot()
        return local.z > 0.1 && distance < 1.1 && p.y < 1.6
    }

    private func nearestInReach(_ items: Set<Item>) -> Item? {
        let r = robot.presentation.simdWorldPosition
        return items.min { simd_distance(node($0).presentation.simdWorldPosition, r) < simd_distance(node($1).presentation.simdWorldPosition, r) }
    }

    private func pickUp(_ item: Item) {
        // Take it out of the physics world and put it in the robot's hands.
        let thing = node(item)
        thing.physicsBody = nil
        thing.removeFromParentNode()
        thing.transform = SCNMatrix4MakeTranslation(holdPoint.x, holdPoint.y, holdPoint.z)
        robot.addChildNode(thing)
        // What's held becomes part of the robot's collision shape, so it can't pass through walls.
        robot.transform = robot.presentation.transform
        robot.physicsBody = makeRobotBody(carrying: item)
        held = item
    }

    private func drop() {
        guard let item = held else { return }
        // Put it back in the world where the hands are, moving with the robot, and let it fall.
        let thing = node(item)
        let world = robot.presentation.convertTransform(SCNMatrix4MakeTranslation(holdPoint.x, holdPoint.y, holdPoint.z), to: nil)
        let velocity = robot.physicsBody?.velocity ?? SCNVector3Zero
        thing.removeFromParentNode()
        thing.transform = world
        scene.rootNode.addChildNode(thing)
        thing.physicsBody = makeBody(for: item)
        thing.physicsBody!.velocity = SCNVector3(velocity.x, 0, velocity.z)
        robot.transform = robot.presentation.transform
        robot.physicsBody = makeRobotBody(carrying: nil)
        held = nil
    }

    /// A plain-language snapshot of the room. Called on the main thread.
    func describeState() -> String {
        let r = robot.presentation.worldPosition
        var lines = [
            "- The room is 6 m wide, 6 m deep and 3 m tall: beige walls on the left, right and back, a wooden floor, and a ceiling with one lamp. The front of the room is open toward the player.",
            "- A wooden table, 0.8 m high, stands against the back wall on the right side of the room (as the player sees it). It is \(relative(tablePosition)).",
            "- You, the robot, are \(placeInRoom(r)), facing \(facing()). You are about 1.9 m tall.",
            "- You can pick up one thing at a time when it is right in front of you, and drop it again.",
        ]
        if let held = hand.held { lines.append("- You are holding \(held.name).") }
        for item in Item.allCases where item != hand.held {
            let p = node(item).presentation.worldPosition
            let what = item == .ball ? "The red ball (0.5 m across)" : "The butter (a yellow block)"
            lines.append("- \(what) is \(relative(p)), \(placeInRoom(p)), \(whereItIs(item)).")
        }
        return lines.joined(separator: "\n")
    }

    /// The facts the planner needs, as short yes/no answers. Distances are left out: they
    /// tempt the small model to measure out walks instead of using the walkTo moves.
    func planningNotes() -> String {
        let table = SIMD2(tablePosition.x, tablePosition.z)
        let nextToTable = simd_length(robotFloorPosition - table) < 1.2
        var lines = [
            "- You are \(placeInRoom(robot.presentation.worldPosition)), facing \(facing()).",
            "- The table stands against the back wall on the right side of the room.",
            "- The player is wherever the camera is.",
            "- You are next to the table: \(nextToTable ? "yes" : "no").",
            "- You are holding: \(hand.held.map(\.name) ?? "nothing").",
        ]
        for item in Item.allCases where item != hand.held {
            lines.append("- \(item.name.prefix(1).uppercased() + item.name.dropFirst()) is \(whereItIs(item)), within reach: \(hand.inReach.contains(item) ? "yes" : "no").")
        }
        return lines.joined(separator: "\n")
    }

    /// The same facts, for checking plans.
    func planningWorld() -> PlanCheck.World {
        var near: Set<PlanCheck.Spot> = []
        if simd_length(robotFloorPosition - SIMD2(tablePosition.x, tablePosition.z)) < 1.2 { near.insert(.table) }
        for item in hand.inReach { near.insert(.item(item)) }
        return PlanCheck.World(
            near: near,
            held: hand.held,
            onTable: Set(Item.allCases.filter { $0 != hand.held && isOnTable($0) }))
    }

    private func whereItIs(_ item: Item) -> String {
        let p = node(item).presentation.worldPosition
        if isOnTable(item) { return "on the table" }
        let height = p.y - halfHeight(item)
        if height > 0.05 { return "in the air" }
        if item == .ball, lock.withLock({ ballSpeed }) > 0.05 { return "rolling on the floor" }
        return "on the floor"
    }

    func isOnTable(_ item: Item) -> Bool {
        guard hand.held != item else { return false }
        let p = node(item).presentation.worldPosition
        let height = p.y - halfHeight(item)
        return abs(p.x - tablePosition.x) < Float(tableSize.width / 2) + 0.05
            && abs(p.z - tablePosition.z) < Float(tableSize.length / 2) + 0.05
            && height > tableHeight - 0.1 && height < tableHeight + 0.1
    }

    private static func m(_ value: Float) -> String { String(format: "%.1f m", abs(value)) }

    /// Distance and direction of a point from the robot's own point of view.
    private func relative(_ p: SCNVector3) -> String {
        // The robot faces +z, so its left is +x.
        let local = robot.presentation.convertPosition(p, from: nil)
        let distance = (local.x * local.x + local.z * local.z).squareRoot()
        return "\(Self.m(distance)) away from you: \(Self.m(local.x)) to your \(local.x > 0 ? "left" : "right") and \(Self.m(local.z)) \(local.z > 0 ? "in front of you" : "behind you")"
    }

    /// Where a point is, as the player sees the room.
    private func placeInRoom(_ p: SCNVector3) -> String {
        let side = p.x < -1 ? "on the left side" : p.x > 1 ? "on the right side" : "in the middle"
        let depth = p.z < -1 ? "near the back wall" : p.z > 1 ? "near the front" : "halfway back"
        return "\(side) of the room (as the player sees it), \(depth)"
    }

    /// Which way the robot's face points. SceneKit's "front" is -z; the robot's face is +z.
    private func facing() -> String {
        let f = -robot.presentation.simdWorldFront
        if abs(f.z) >= abs(f.x) {
            return f.z > 0 ? "the open front of the room, toward the player" : "the back wall"
        }
        return f.x > 0 ? "the right wall (as the player sees it)" : "the left wall (as the player sees it)"
    }
}

struct RoomSceneView: UIViewRepresentable {
    let room: RoomScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = room.scene
        view.delegate = room
        view.rendersContinuously = true
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X

        // Drag to orbit, pinch to zoom, two-finger drag to pan
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 0.7, 0)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

private func material(_ color: UIColor) -> SCNMaterial {
    let m = SCNMaterial()
    m.diffuse.contents = color
    m.lightingModel = .blinn
    return m
}

private func node(_ geometry: SCNGeometry, _ color: UIColor, at position: SCNVector3) -> SCNNode {
    geometry.materials = [material(color)]
    let n = SCNNode(geometry: geometry)
    n.position = position
    return n
}

private let ballRadius: CGFloat = 0.25
private let butterSize = (width: CGFloat(0.3), height: CGFloat(0.12), length: CGFloat(0.15))
/// Where a carried thing sits, in the robot's own space: in front of the chest, between the arms.
private let holdPoint = SCNVector3(0, 1.15, 0.55)
/// The table: centre of its footprint on the floor, and its size.
let tablePosition = SCNVector3(1.6, 0, -2.55)
private let tableSize = (width: CGFloat(1.4), length: CGFloat(0.7))
private let tableHeight: Float = 0.8

/// Half the height of a thing, from its centre down to what it rests on.
private func halfHeight(_ item: Item) -> Float {
    switch item {
    case .ball: Float(ballRadius)
    case .butter: Float(butterSize.height / 2)
    }
}

private func shape(for item: Item) -> SCNPhysicsShape {
    switch item {
    case .ball: SCNPhysicsShape(geometry: SCNSphere(radius: ballRadius))
    case .butter: SCNPhysicsShape(geometry: SCNBox(width: butterSize.width, height: butterSize.height, length: butterSize.length, chamferRadius: 0))
    }
}

private func makeBody(for item: Item) -> SCNPhysicsBody {
    let body = SCNPhysicsBody(type: .dynamic, shape: shape(for: item))
    switch item {
    case .ball:
        body.mass = 0.5
        body.restitution = 0.7
        body.friction = 0.5
        body.rollingFriction = 0.05
    case .butter:
        // A soft, heavy-ish block: it lands with a thud and doesn't slide far.
        body.mass = 0.25
        body.restitution = 0.05
        body.friction = 0.9
    }
    body.continuousCollisionDetectionThreshold = 0.1
    // A sleeping body ignores the robot walking into it, so keep it awake.
    body.allowsResting = false
    return body
}

/// A heavy dynamic body that can turn but never tip over, so it pushes the ball and is
/// stopped by walls and the table. One box covers the body, feet to head and arm to arm
/// (a shape built from the node tree would miss the limbs, which hang from pivot nodes);
/// a carried thing adds its own shape at the hands.
private func makeRobotBody(carrying item: Item?) -> SCNPhysicsBody {
    var shapes = [SCNPhysicsShape(geometry: SCNBox(width: 0.95, height: 1.8, length: 0.4, chamferRadius: 0))]
    var transforms = [NSValue(scnMatrix4: SCNMatrix4MakeTranslation(0, 0.9, 0))]
    if let item {
        shapes.append(shape(for: item))
        transforms.append(NSValue(scnMatrix4: SCNMatrix4MakeTranslation(holdPoint.x, holdPoint.y, holdPoint.z)))
    }
    let body = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(shapes: shapes, transforms: transforms))
    body.mass = 50
    body.friction = 0
    body.angularVelocityFactor = SCNVector3(0, 1, 0)
    body.allowsResting = false
    return body
}

private func makeScene() -> (SCNScene, SCNNode, SCNNode, SCNNode) {
    let scene = SCNScene()
    let root = scene.rootNode
    let roomSize: CGFloat = 6
    let wallHeight: CGFloat = 3

    // Gravity (SceneKit's default is already -9.8 m/s², set here explicitly)
    scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)

    // Room: floor, three walls and a ceiling, all static colliders
    let wall = UIColor(red: 0.86, green: 0.82, blue: 0.74, alpha: 1)
    let floor = UIColor(red: 0.55, green: 0.38, blue: 0.24, alpha: 1)
    let roomParts = [
        node(SCNBox(width: roomSize, height: 0.1, length: roomSize, chamferRadius: 0), floor, at: SCNVector3(0, -0.05, 0)),
        node(SCNBox(width: roomSize, height: wallHeight, length: 0.1, chamferRadius: 0), wall, at: SCNVector3(0, Float(wallHeight / 2), -Float(roomSize / 2))),
        node(SCNBox(width: 0.1, height: wallHeight, length: roomSize, chamferRadius: 0), wall, at: SCNVector3(-Float(roomSize / 2), Float(wallHeight / 2), 0)),
        node(SCNBox(width: 0.1, height: wallHeight, length: roomSize, chamferRadius: 0), wall, at: SCNVector3(Float(roomSize / 2), Float(wallHeight / 2), 0)),
        node(SCNBox(width: roomSize, height: 0.1, length: roomSize, chamferRadius: 0), wall, at: SCNVector3(0, Float(wallHeight), 0)),
    ]
    for part in roomParts {
        part.physicsBody = .static()
        part.physicsBody!.restitution = 0.6
        part.physicsBody!.friction = 0.6
        root.addChildNode(part)
    }

    // Invisible front wall, just in front of the camera, so the ball stays in view
    let frontWall = SCNNode()
    frontWall.position = SCNVector3(0, Float(wallHeight / 2), 2.3)
    frontWall.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: SCNBox(width: roomSize, height: wallHeight, length: 0.1, chamferRadius: 0)))
    root.addChildNode(frontWall)

    // Table against the back wall: a top on four legs, all static colliders
    root.addChildNode(makeTable())

    // Robot
    let robot = makeRobot(at: SCNVector3(-0.8, 0, 0))
    robot.physicsBody = makeRobotBody(carrying: nil)
    root.addChildNode(robot)

    // Ball: dropped from the air with a push toward the robot
    let ball = node(SCNSphere(radius: ballRadius), .systemRed, at: SCNVector3(1.0, 2.2, 0.6))
    ball.physicsBody = makeBody(for: .ball)
    ball.physicsBody!.velocity = SCNVector3(-1.6, 0, -0.4)
    root.addChildNode(ball)

    // Butter: a yellow block on the table, near its front edge so the robot can reach it
    let butter = node(SCNBox(width: butterSize.width, height: butterSize.height, length: butterSize.length, chamferRadius: 0.015),
                      UIColor(red: 1, green: 0.88, blue: 0.45, alpha: 1),
                      at: SCNVector3(1.3, tableHeight + Float(butterSize.height / 2) + 0.01, -2.35))
    butter.physicsBody = makeBody(for: .butter)
    root.addChildNode(butter)

    // Lights
    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light!.type = .ambient
    ambient.light!.intensity = 350
    root.addChildNode(ambient)

    let lamp = SCNNode()
    lamp.light = SCNLight()
    lamp.light!.type = .omni
    lamp.light!.intensity = 700
    lamp.position = SCNVector3(0, 2.8, 1.5)
    root.addChildNode(lamp)

    // Camera, looking into the room
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera!.projectionDirection = .horizontal
    camera.camera!.fieldOfView = 75
    camera.camera!.zNear = 0.05
    camera.position = SCNVector3(0, 1.5, 2.8)
    camera.look(at: SCNVector3(0, 0.7, 0))
    root.addChildNode(camera)

    return (scene, robot, ball, butter)
}

private func makeTable() -> SCNNode {
    let table = SCNNode()
    table.position = tablePosition
    let wood = UIColor(red: 0.42, green: 0.27, blue: 0.16, alpha: 1)
    let topThickness: CGFloat = 0.06
    let legHeight = CGFloat(tableHeight) - topThickness

    let top = node(SCNBox(width: tableSize.width, height: topThickness, length: tableSize.length, chamferRadius: 0.01), wood,
                   at: SCNVector3(0, tableHeight - Float(topThickness / 2), 0))
    var parts = [top]
    let insetX = Float(tableSize.width / 2) - 0.08
    let insetZ = Float(tableSize.length / 2) - 0.08
    for (x, z) in [(insetX, insetZ), (-insetX, insetZ), (insetX, -insetZ), (-insetX, -insetZ)] {
        parts.append(node(SCNBox(width: 0.07, height: legHeight, length: 0.07, chamferRadius: 0), wood,
                          at: SCNVector3(x, Float(legHeight / 2), z)))
    }
    for part in parts {
        part.physicsBody = .static()
        part.physicsBody!.restitution = 0.4
        part.physicsBody!.friction = 0.6
        table.addChildNode(part)
    }
    return table
}

private func makeRobot(at position: SCNVector3) -> SCNNode {
    let robot = SCNNode()
    robot.position = position
    let body = UIColor(white: 0.7, alpha: 1)
    let limbs = UIColor(white: 0.5, alpha: 1)

    // Legs and arms hang from hip and shoulder pivots so they can swing when walking.
    // The robot faces +z, so its own left side is +x.
    func limb(_ name: String, x: Float, pivotY: Float, size: CGFloat) -> SCNNode {
        let pivot = SCNNode()
        pivot.name = name
        pivot.position = SCNVector3(x, pivotY, 0)
        pivot.addChildNode(node(SCNBox(width: size, height: 0.6, length: size, chamferRadius: 0.02), limbs, at: SCNVector3(0, -0.3, 0)))
        return pivot
    }

    // Legs
    robot.addChildNode(limb("leftHip", x: 0.15, pivotY: 0.6, size: 0.18))
    robot.addChildNode(limb("rightHip", x: -0.15, pivotY: 0.6, size: 0.18))

    // Torso
    robot.addChildNode(node(SCNBox(width: 0.6, height: 0.7, length: 0.4, chamferRadius: 0.05), body, at: SCNVector3(0, 0.95, 0)))

    // Arms
    robot.addChildNode(limb("leftShoulder", x: 0.4, pivotY: 1.25, size: 0.14))
    robot.addChildNode(limb("rightShoulder", x: -0.4, pivotY: 1.25, size: 0.14))

    // Head
    robot.addChildNode(node(SCNBox(width: 0.45, height: 0.35, length: 0.35, chamferRadius: 0.05), body, at: SCNVector3(0, 1.5, 0)))

    // Eyes
    robot.addChildNode(node(SCNSphere(radius: 0.05), .cyan, at: SCNVector3(-0.1, 1.53, 0.18)))
    robot.addChildNode(node(SCNSphere(radius: 0.05), .cyan, at: SCNVector3(0.1, 1.53, 0.18)))

    // Mouth: dark when quiet; lights up and opens when the robot talks
    let mouth = node(SCNBox(width: 0.2, height: 0.04, length: 0.01, chamferRadius: 0.005), UIColor(white: 0.15, alpha: 1),
                     at: SCNVector3(0, 1.41, 0.177))
    mouth.name = "mouth"
    robot.addChildNode(mouth)

    // Antenna
    robot.addChildNode(node(SCNCylinder(radius: 0.02, height: 0.2), limbs, at: SCNVector3(0, 1.77, 0)))
    robot.addChildNode(node(SCNSphere(radius: 0.04), .systemRed, at: SCNVector3(0, 1.89, 0)))

    return robot
}

#Preview {
    RoomView()
}
