import AppKit
import SwiftUI

/// The app's motion, in three meanings, and the one place SwiftUI's durations and curves are named
/// (AppKit's twins, a popup's fade and the scroll to options opened, keep the same values):
/// - `quick`, touch and feedback: hover and press, a field's ring, a check, the mark's color, a
///   reply's actions coming into view;
/// - `settle`, a change of state or shape: a disclosure, rows and sections coming and going, the
///   control bar's stage, the switch between the Server and the Chat, figures that change;
/// - `glide`, travel: a scroll to the latest message or to options opened, the mark taking its
///   pose as a model becomes ready.
///
/// What appears fades in within `settle`; nothing slides in but the switch's pill. Nothing loops
/// while a reply streams, as drawing shares the GPU with the model: the reply's counters change once
/// a second without rolling, and only the engine's figures, every 2 s, roll. The swap of the Server
/// and the Chat, streaming text, the composer's height and a popup's opening don't move. With
/// Reduce Motion changes of state and travel happen at once, figures fade, and the mark keeps its
/// pose.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let quick = Animation.easeOut(duration: 0.12)
    static var settle: Animation? { reduced ? nil : .smooth(duration: 0.24) }
    static var glide: Animation? { reduced ? nil : .smooth(duration: 0.4) }
    static var number: ContentTransition { reduced ? .opacity : .numericText() }
}
