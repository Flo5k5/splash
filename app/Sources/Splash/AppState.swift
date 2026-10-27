import AppKit
import Foundation
import Observation

/// What the app's window and menus show: the runtime, the server, downloads, the models and the
/// conversations.
@MainActor @Observable
final class AppState {
    /// What fills the window: the chats, once a model is on this Mac; the welcome until then.
    enum Screen: Hashable { case launching, blocked, models, chat }

    /// Why the app cannot run models here.
    struct Blocker: Equatable {
        let title: String
        let symbol: String
        let message: String
    }

    let runtime: Runtime
    let server: Server
    let installer: Installer
    let catalog: Catalog
    let chats: ChatStore
    /// The message being written, kept while the window shows something else.
    let draft = Draft()
    private(set) var installed: [InstalledModel] = []
    private(set) var blocker: Blocker?
    /// Whether the checks of `launch` are done; nothing starts before.
    private(set) var launched = false
    /// The models, as a sheet over the chat.
    var showingModels = false
    /// Set once the app quits: nothing starts any more.
    private(set) var quitting = false
    /// A model that downloaded while another one ran, to switch to.
    private(set) var downloaded: String?

    init(runtime: Runtime, chats: ChatStore = ChatStore()) {
        self.runtime = runtime
        self.chats = chats
        server = Server(runtime: runtime)
        installer = Installer(runtime: runtime)
        catalog = Catalog(contentsOf: runtime.suggestedModels)
        installer.installed = { [weak self] in self?.didInstall($0) }
        refresh()
    }

    var screen: Screen {
        if blocker != nil { return .blocked }
        if !launched { return .launching }
        return installed.isEmpty && !server.running ? .models : .chat
    }

    /// Whether models can start and download.
    var ready: Bool { launched && blocker == nil && !quitting }

    /// What runs, in the words the menus use.
    var status: String {
        let name = server.model.map(displayName(of:)) ?? ""
        switch server.phase {
        case .stopped: return "No model running"
        case .starting: return "Starting \(name)…"
        case .stopping: return server.next.map { "Starting \(displayName(of: $0))…" } ?? "Stopping \(name)…"
        case .ready: return "\(name) · \(server.asleep ? "Sleeping" : "Running")"
        case .failed: return "\(name) ran into a problem"
        }
    }

    /// The download under way, in the words the menus use.
    var downloadStatus: String? {
        guard let model = installer.model else { return nil }
        let name = displayName(of: model)
        guard let progress = installer.progress else { return "Downloading \(name)…" }
        return "Downloading \(name) · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
    }

    /// The model the next start would start: the one running or starting, else the last one.
    var lastModel: String? {
        (server.next ?? server.model ?? UserDefaults.standard.string(forKey: Preference.lastModel))
            .flatMap { isInstalled($0) ? $0 : nil }
    }

    /// The name to show for model `id`; its variant tells installed variants of a model apart.
    func displayName(of id: String) -> String {
        let name = catalog.name(of: id)
        guard installed.filter({ catalog.name(of: $0.id) == name }).count > 1 else { return name }
        return "\(name) (\(Catalog.variant(of: id)))"
    }

    /// Checks this Mac and the app's location, stops what the app left running last time, and
    /// starts the last model if it ran until the app quit.
    func launch() async {
        defer { launched = true }
        let runtime = runtime
        if let reason = await Task.detached(operation: { runtime.unsupportedReason() }).value {
            blocker = Blocker(title: "This Mac Can’t Run Splash", symbol: "exclamationmark.triangle", message: reason)
            return
        }
        if Self.mustMoveToApplications(Bundle.main.bundleURL) {
            blocker = Blocker(title: "Move Splash to Applications", symbol: "externaldrive",
                              message: "Splash can’t run from the disk image. Drag it to your Applications folder, then open it from there.")
            return
        }
        await installer.stopLeftover()
        await server.stopLeftover()
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Preference.startOnOpen), defaults.bool(forKey: Preference.resume),
           let model = defaults.string(forKey: Preference.lastModel), isInstalled(model) {
            launched = true
            start(model)
        }
    }

    func start(_ model: String) {
        guard ready else { return }
        showingModels = false
        downloaded = nil
        chats.stop()
        server.start(model)
    }

    /// Stops the model the user asked to stop: it no longer starts when Splash opens.
    func stop() {
        UserDefaults.standard.set(false, forKey: Preference.resume)
        chats.stop()
        server.stop()
    }

    func download(_ model: String) {
        guard ready else { return }
        installer.install(model)
    }

    /// Stops the download and the model for the app to quit, and starts nothing after.
    func quit() {
        quitting = true
        chats.stop()
        installer.cancel()
        server.stop()
    }

    /// Sends a message to the running model.
    func send(_ text: String, images: [Data]) {
        target.map { chats.send(text, images: images, to: $0) }
    }

    /// Asks the running model again for the open conversation's last answer.
    func retry() {
        target.map(chats.retry(with:))
    }

    private var target: ChatTarget? {
        guard server.phase == .ready, let model = server.model else { return nil }
        return ChatTarget(url: server.settings.url, model: model, acceptsImages: server.acceptsImages, effort: effort)
    }

    /// The reasoning effort messages ask for; empty for the model's own default.
    var effort: String {
        get { access(keyPath: \.effort); return UserDefaults.standard.string(forKey: Preference.effort) ?? "" }
        set { withMutation(keyPath: \.effort) { UserDefaults.standard.set(newValue, forKey: Preference.effort) } }
    }

    /// The models over the chat; before a model is installed they are the window itself.
    func showModels() {
        if screen == .chat { showingModels = true }
    }

    func copyAPIAddress() {
        let settings = server.running ? server.settings : ServeSettings.current()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(settings.url.appending(path: "v1").absoluteString, forType: .string)
    }

    /// The models installed here, the suggested ones first in the list's order.
    func refresh() {
        let rank = { (id: String) in self.catalog.variants.firstIndex { $0.id == id } ?? Int.max }
        installed = runtime.installedModels().sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
    }

    func isInstalled(_ model: String) -> Bool {
        installed.contains { $0.id == model }
    }

    private func didInstall(_ model: String) {
        refresh()
        if server.running {
            downloaded = model
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        } else {
            start(model)
        }
    }

    /// Whether the app at `bundle` runs from the disk image or a translocated copy: its path then
    /// changes on every launch and its volume may go away while a model runs.
    static func mustMoveToApplications(_ bundle: URL) -> Bool {
        guard bundle.pathExtension == "app" else { return false }
        return bundle.path.contains("/AppTranslocation/")
            || (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }
}
