import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The message being written: its text and the images attached to it.
@MainActor @Observable
final class Draft {
    var text = ""
    private(set) var images: [Data] = []
    /// Asks the text field for the keyboard; counts the requests.
    private(set) var focusRequests = 0

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    func focus() { focusRequests += 1 }

    /// Attaches `images` in a form the server takes: at most 2048 pixels on the long side (its
    /// limit is about four million pixels), PNG when they have transparency and JPEG otherwise.
    func attach(_ images: [NSImage]) {
        self.images += images.compactMap(Self.encoded)
    }

    func remove(at index: Int) { images.remove(at: index) }

    /// Takes the message, leaving the draft empty.
    func take() -> (text: String, images: [Data]) {
        defer { text = ""; images = [] }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), images)
    }

    private static func encoded(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 2048 / Double(max(source.width, source.height)))
        let width = Int(Double(source.width) * scale), height = Int(Double(source.height) * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let opaque = source.alphaInfo == .none || source.alphaInfo == .noneSkipFirst || source.alphaInfo == .noneSkipLast
        return opaque
            ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            : bitmap.representation(using: .png, properties: [:])
    }
}

/// Where a message is written: the text, the images attached, the reasoning effort, and Send, or
/// Stop while a reply streams.
struct Composer: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var draft: Draft
    @State private var picking = false
    @State private var height: CGFloat = 22

    var body: some View {
        let images = state.server.acceptsImages
        VStack(alignment: .leading, spacing: 10) {
            if !draft.images.isEmpty {
                Attachments(draft: draft)
            }
            ComposerField(text: $draft.text, height: $height, focusRequests: draft.focusRequests,
                          placeholder: "Message Splash", submit: send, cancel: stop, acceptsImages: images,
                          attach: draft.attach)
                .frame(height: min(max(height, 22), 220))
            HStack(spacing: 12) {
                Button { picking = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!images)
                    .help(images ? "Attach Images" : "Images need a model that can see them")
                    .accessibilityLabel("Attach Images")
                Spacer()
                ModelMenu()
                if streaming {
                    Button { state.chats.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)) }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop")
                        .accessibilityLabel("Stop")
                        .buttonStyle(InkCircle())
                } else {
                    Button(action: send) { Image(systemName: "arrow.up") }
                        .help(help)
                        .accessibilityLabel("Send")
                        .disabled(!sendable)
                        .buttonStyle(InkCircle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(colorScheme == .dark ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.background),
                    in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            draft.attach(((try? result.get()) ?? []).compactMap(NSImage.init(contentsOf:)))
        }
    }

    /// Whether the open conversation's reply streams.
    private var streaming: Bool {
        state.chats.streaming != nil && state.chats.streaming == state.chats.current?.id
    }

    private var sendable: Bool {
        !draft.isEmpty && state.server.phase == .ready && state.chats.streaming == nil
            && (draft.images.isEmpty || state.server.acceptsImages)
    }

    private var help: String {
        if state.server.phase != .ready { return "Available once a model is running" }
        if !draft.images.isEmpty && !state.server.acceptsImages { return "This model can’t see images" }
        return "Send"
    }

    private func send() {
        guard sendable else { return }
        let message = draft.take()
        state.send(message.text, images: message.images)
    }

    /// Stops the open conversation's reply, the way Escape cancels; false when none streams.
    private func stop() -> Bool {
        guard streaming else { return false }
        state.chats.stop()
        return true
    }
}

/// The send and stop button: a circle in the label color, the composer's one solid element.
private struct InkCircle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.background)
            .frame(width: 28, height: 28)
            .background(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.2), in: .circle)
    }
}

/// The model that answers and how much it thinks, as Claude's composer shows them: its name, then
/// its effort, which a click changes, as its template tells efforts apart (its levels, or thinking
/// on or off), its default marked. A model that decides itself shows its name alone. Models
/// themselves change on the Server screen.
private struct ModelMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.server.phase == .ready, let model = state.server.model {
            let name = Text(state.displayName(of: model)).foregroundStyle(.secondary)
            if let reasoning = state.server.reasoning, let thinks = reasoning.thinks {
                let levels = !reasoning.efforts.isEmpty
                // The choice that leaves the effort to the model: its default, by name where it has one.
                let initial = !thinks ? "none" : levels ? reasoning.default ?? "" : "on"
                let choices = (levels ? reasoning.efforts.reversed() : ["on"])
                    + (levels && reasoning.default == nil && thinks ? [""] : []) + ["none"]
                let chosen = state.effort.isEmpty ? initial : !levels && state.effort != "none" ? "on" : state.effort
                Menu {
                    Picker("Thinking", selection: Binding(get: { chosen }, set: { choice in
                        // On, for a model whose thinking is only on or off, is any effort but none.
                        state.effort = choice == initial ? "" : choice == "on" ? "medium" : choice
                    })) {
                        ForEach(choices, id: \.self) { choice in
                            Text(choice == initial ? "\(Self.title(choice)) (Default)" : Self.title(choice)).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        name
                        Text(Self.title(chosen)).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("How much the model thinks before it answers")
                .accessibilityLabel(state.displayName(of: model))
                .accessibilityValue(Self.title(chosen))
            } else {
                name.font(.callout).lineLimit(1)
            }
        }
    }

    /// An effort's name.
    private static func title(_ effort: String) -> String {
        switch effort {
        case "": "Default"
        case "on": "Thinking"
        case "none": "No Thinking"
        case "xhigh": "Extra High"
        default: effort.capitalized
        }
    }
}

private struct Attachments: View {
    let draft: Draft

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(draft.images.enumerated()), id: \.offset) { index, data in
                    ZStack(alignment: .topTrailing) {
                        if let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                        Button { draft.remove(at: index) } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove Image")
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

/// The message's text view: Return sends and Shift-Return starts a new line, and Escape stops the
/// reply, after the input method has finished what it composes; pasted and dropped images attach
/// when the model sees images.
private struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusRequests: Int
    let placeholder: String
    let submit: () -> Void
    let cancel: () -> Bool
    let acceptsImages: Bool
    let attach: ([NSImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: the height is measured with its layout manager.
        let view = MessageTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.placeholder = placeholder
        view.font = .systemFont(ofSize: 15)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.field = self
        guard let view = scroll.documentView as? MessageTextView else { return }
        if view.string != text {
            // A change made here, sending the message, is no edit to undo.
            view.string = text
            context.coordinator.undo.removeAllActions()
            context.coordinator.measure(view)
        }
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var field: ComposerField
        var focusRequests = 0
        /// The field's own edits, which a message sent clears.
        let undo = UndoManager()

        init(_ field: ComposerField) {
            self.field = field
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            field.text = view.string
            measure(view)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    field.submit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return field.cancel()
            default:
                return false
            }
        }

        func measure(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            // Not while SwiftUI updates the view, which measures too.
            DispatchQueue.main.async { [self] in if field.height != height { field.height = height } }
        }
    }
}

private final class MessageTextView: NSTextView {
    weak var coordinator: ComposerField.Coordinator?
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 15),
                                                         .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // A plain-text view turns Paste off for a clipboard of image data alone.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), !images(in: .general).isEmpty { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if attach(from: .general) { return }
        pasteAsPlainText(sender)
    }

    // A text view takes only text it can read; images it takes here, when the model sees them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        images(in: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        images(in: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        attach(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /// Attaches the images `pasteboard` holds; false when it holds none to attach.
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        let images = images(in: pasteboard)
        guard !images.isEmpty else { return false }
        coordinator?.field.attach(images)
        return true
    }

    /// The images `pasteboard` holds, image files too, when the model sees images; none for text
    /// that comes with a picture of itself, as copied rich text does.
    private func images(in pasteboard: NSPasteboard) -> [NSImage] {
        guard coordinator?.field.acceptsImages == true else { return [] }
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL]) ?? []
        if !files.isEmpty { return files.compactMap(NSImage.init(contentsOf:)) }
        guard pasteboard.string(forType: .string) == nil else { return [] }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
    }
}
