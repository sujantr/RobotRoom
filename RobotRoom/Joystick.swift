import SwiftUI

/// An on-screen thumbstick. Reports its deflection in -1...1 (x right, y down),
/// and zero when released.
struct Joystick: View {
    var onChange: (CGVector) -> Void

    @State private var knob: CGSize = .zero
    private let radius: CGFloat = 60

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: 50, height: 50)
                .shadow(radius: 3)
                .offset(knob)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var offset = value.translation
                    let length = hypot(offset.width, offset.height)
                    if length > radius {
                        offset = CGSize(width: offset.width / length * radius, height: offset.height / length * radius)
                    }
                    knob = offset
                    onChange(CGVector(dx: offset.width / radius, dy: offset.height / radius))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.2)) { knob = .zero }
                    onChange(.zero)
                }
        )
    }
}
