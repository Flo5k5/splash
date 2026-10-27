import SwiftUI

/// The look of the app's own buttons: plain, with a rounded highlight under the pointer, a little
/// deeper while pressed, as the composer's model and effort show it.
struct HoverStyle: ButtonStyle {
    /// Room between the label and the highlight's edge.
    var padding = EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
    var shape = AnyShape(.rect(cornerRadius: 7))

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, padding: padding, shape: shape)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let padding: EdgeInsets
        let shape: AnyShape
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(padding)
                .background(.quaternary.opacity(!enabled ? 0 : configuration.isPressed ? 1 : hovering ? 0.75 : 0), in: shape)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverStyle {
    static var hover: HoverStyle { HoverStyle() }
    /// The highlight on the label's own bounds, for a label that pads itself.
    static var hoverFlush: HoverStyle { HoverStyle(padding: EdgeInsets()) }
    /// The highlight across a row of a form, which keeps its text where the row's other text is.
    static var hoverRow: HoverStyle { HoverStyle(padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)) }
}

extension View {
    /// Undoes `hoverRow`'s room, so that the row's text stays in line with the form's.
    func hoverRowAligned() -> some View {
        padding(.horizontal, -8).padding(.vertical, -4)
    }
}
