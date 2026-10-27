import AppKit
import SwiftUI

/// A choice of a `PopupMenu`.
struct PopupItem: Identifiable, Hashable {
    let id: String
    let title: String
    /// A line under the title.
    var detail: String?
    /// A word beside the title, such as Default.
    var badge: String?
    /// Set apart from the items before it by a line.
    var separated = false
}

/// A menu in Splash's own style: a rounded panel under the control that opens it, or over it,
/// with a header and its items, each a title, any detail under it and a badge, the chosen one
/// checked. It closes on a choice, a click elsewhere or Escape.
struct PopupMenu<Label: View>: View {
    var header: String?
    let items: [PopupItem]
    let chosen: String?
    var above = false
    let choose: (String) -> Void
    @ViewBuilder let label: () -> Label
    @State private var popup = Popup()

    var body: some View {
        Button {
            popup.toggle(above: above) {
                PopupList(header: header, items: items, chosen: chosen) { id in
                    popup.close()
                    choose(id)
                }
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(PopupAnchor(popup: popup))
    }
}

/// The panel of a `PopupMenu`, apart from the control.
struct PopupList: View {
    let header: String?
    let items: [PopupItem]
    let chosen: String?
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let header {
                Text(header)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 3)
            }
            ForEach(items) { item in
                if item.separated {
                    Divider().padding(.horizontal, 8).padding(.vertical, 4)
                }
                PopupRow(item: item, chosen: item.id == chosen) { choose(item.id) }
            }
        }
        .padding(5)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
    }
}

private struct PopupRow: View {
    let item: PopupItem
    let chosen: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.title)
                        if let badge = item.badge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .rect(cornerRadius: 5))
                        }
                    }
                    if let detail = item.detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                Image(systemName: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(chosen ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The open panel of a `PopupMenu`: a borderless child window of the control's, at its trailing
/// edge, under it or over it.
@MainActor
final class Popup {
    weak var anchor: NSView?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var resigned: NSObjectProtocol?

    func toggle(above: Bool, @ViewBuilder content: () -> some View) {
        if panel != nil { close() } else { show(above: above, content: content()) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        resigned.map(NotificationCenter.default.removeObserver)
        resigned = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    private func show(above: Bool, content: some View) {
        guard let anchor, let window = anchor.window else { return }
        let control = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let screen = window.screen?.visibleFrame ?? .infinite
        let origin = NSPoint(
            x: min(max(control.maxX - size.width, screen.minX + 8), screen.maxX - size.width - 8),
            y: above ? control.maxY + 6 : control.minY - 6 - size.height
        )
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        panel.invalidateShadow()
        self.panel = panel
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // A click on the control is its own: it closes the panel itself.
                if let self, event.window !== panel, !onAnchor(event) { close() }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.close()
                return nil
            },
        ].compactMap { $0 }
        resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

extension Popup {
    private func onAnchor(_ event: NSEvent) -> Bool {
        guard let anchor, event.window === anchor.window else { return false }
        return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }
}

/// The control's view, where its panel opens.
private struct PopupAnchor: NSViewRepresentable {
    let popup: Popup

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        popup.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        popup.anchor = view
    }
}
