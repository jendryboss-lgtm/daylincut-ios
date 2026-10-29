import Foundation
@testable import ClipForge

enum Fixtures {
    static func clip(_ seconds: Double, speed: Double = 1, transition: TransitionType = .none, transitionDuration: Double = 0.5) -> Clip {
        var c = Clip(mediaKind: .video, fileName: "test-\(UUID().uuidString).mov", sourceDuration: seconds, speed: speed)
        c.transition = Transition(type: transition, duration: transitionDuration)
        return c
    }
}
