import AppKit
import SwiftUI

/// Splash's mark, as the app icon draws it (app/AppIcon.icon/Assets/mark.svg): a circle cut by two
/// lines at 45°, its pieces slid along them, up and to the right. `gap` is the width of the cuts in
/// radii, which a small mark widens to keep them in sight; `spread` how far the pieces are slid,
/// from 0, lined up as one circle, to 1, the icon's pose. The mark keeps its size at every spread.
struct SplashMark: Shape {
    var gap = 24.0 / 272
    var spread = 1.0

    var animatableData: Double {
        get { spread }
        set { spread = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let mark = pieces(spread: spread)
        // Placed as the icon's pose fits rect, centred.
        let bounds = pieces(spread: 1).boundingRect
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return mark.applying(CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }

    /// The pieces of a circle of radius 1 about the origin.
    private func pieces(spread: Double) -> Path {
        // Where each piece starts and ends across the cuts, and how far along them it slides in the
        // icon's pose; in radii, as the icon's 272-point circle has them. The middle one slides
        // alike at every spread.
        let pieces: [(low: Double, high: Double, slide: Double)] = [
            (-2, -100.0 / 272, -22.0 / 272), (-100.0 / 272, 70.0 / 272, 14.0 / 272), (70.0 / 272, 2, 50.0 / 272),
        ]
        let middle = pieces[1].slide
        let along = CGPoint(x: sqrt(0.5), y: -sqrt(0.5)), across = CGPoint(x: sqrt(0.5), y: sqrt(0.5))
        let point = { (s: Double, t: Double) in CGPoint(x: across.x * s + along.x * t, y: across.y * s + along.y * t) }
        let circle = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
        var mark = Path()
        for piece in pieces {
            let low = piece.low > -1 ? piece.low + gap / 2 : piece.low
            let high = piece.high < 1 ? piece.high - gap / 2 : piece.high
            let band = Path { band in
                band.addLines([point(low, -2), point(high, -2), point(high, 2), point(low, 2)])
                band.closeSubpath()
            }
            let slide = middle + spread * (piece.slide - middle)
            mark.addPath(circle.intersection(band), transform: CGAffineTransform(translationX: along.x * slide, y: along.y * slide))
        }
        return mark
    }

    /// The mark as the menu bar shows the app: in the menu bar's own color, lined up and faint
    /// until a model serves.
    static func menuBarImage(serving: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.withAlphaComponent(serving ? 1 : 0.45).setFill()
            NSBezierPath(cgPath: SplashMark(gap: 0.18, spread: serving ? 1 : 0).path(in: rect.insetBy(dx: 1, dy: 1)).cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension ShapeStyle where Self == LinearGradient {
    /// The mark's colors, as the app icon has them; the mark's alone.
    static var splash: LinearGradient {
        LinearGradient(colors: [Color(.displayP3, red: 0.180, green: 0.788, blue: 1),
                                Color(.displayP3, red: 0.231, green: 0.357, blue: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// What the server does, as the mark shows it (`StatusMark`).
enum MarkLook: Equatable {
    case off, loading, on, asleep, failed
}

/// The server's state in the mark, in a slot of its own size: lined up and grey while nothing runs,
/// its pieces sliding apart and back along the cuts while a model loads into memory, in the icon's
/// pose and colors while one serves, faint while it sleeps; a warning sign when it failed. It
/// moves only while weights load, never while the model answers. The words beside it say what it
/// shows.
struct StatusMark: View {
    let look: MarkLook
    /// When the load began, where the slide starts lined up.
    let since: Date
    var size: CGFloat = 14

    var body: some View {
        Group {
            if look == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: size - 1))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: look != .loading || Motion.reduced)) { context in
                    let spread = spread(at: context.date)
                    let gap = size < 24 ? 0.18 : 24.0 / 272
                    ZStack {
                        SplashMark(gap: gap, spread: spread)
                            .fill(look == .off ? HierarchicalShapeStyle.tertiary : .secondary)
                            .opacity(look == .on || look == .asleep ? 0 : 1)
                        SplashMark(gap: gap, spread: spread)
                            .fill(.splash)
                            .opacity(look == .on ? 1 : look == .asleep ? 0.4 : 0)
                    }
                    .frame(width: size, height: size)
                }
            }
        }
        .frame(width: size + 2, height: size + 2)
        .animation(Motion.glide ?? Motion.quick, value: look)
        .accessibilityHidden(true)
    }

    /// How far apart the pieces are at `date`: out and back every 1.6 s while loading, in the
    /// icon's pose while serving, lined up otherwise; in the pose throughout with Reduce Motion.
    private func spread(at date: Date) -> Double {
        if Motion.reduced { return 1 }
        switch look {
        case .loading:
            let wave = sin(Double.pi * date.timeIntervalSince(since) / 1.6)
            return 0.85 * wave * wave
        case .on, .asleep: return 1
        case .off, .failed: return 0
        }
    }
}
