import AppKit
import Foundation
import Observation

/// What the app's window and menus show: the runtime, the server, downloads, the models and the
/// conversations.
@MainActor @Observable
final class AppState {
    /// The window's two parts: the Server, where models download, start and change, and the Chat
    /// with the model that runs. The window opens on the Server.
    enum Section: Hashable { case server, chat }

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
    var section = Section.server
    /// The launch options the next start uses.
    var options = ServeSettings.current() {
        didSet { options.save() }
    }
    /// Set once the app quits: nothing starts any more.
    private(set) var quitting = false

    init(runtime: Runtime, chats: ChatStore = ChatStore()) {
        self.runtime = runtime
        self.chats = chats
        server = Server(runtime: runtime)
        installer = Installer(runtime: runtime)
        catalog = Catalog(contentsOf: runtime.suggestedModels)
        installer.installed = { [weak self] in self?.didInstall($0) }
        refresh()
    }

    /// Whether the app runs on this Mac and has done its checks: the window then shows the Server
    /// and the Chat.
    var available: Bool { launched && blocker == nil }

    /// Whether models can start and download.
    var ready: Bool { available && !quitting }

    /// What runs, in the words the menus and the Chat use.
    var status: String {
        let name = server.model.map(displayName(of:)) ?? ""
        switch server.phase {
        case .stopped: return "No model running"
        case .starting: return "Loading \(name) into memory…"
        case .stopping:
            guard let next = server.next else { return "Stopping \(name)…" }
            return next == server.model ? "Restarting \(name)…" : "Switching to \(displayName(of: next))…"
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

    /// The model picked on the Server screen: the last one picked if it is still on this Mac, else
    /// the first one that is.
    var selection: String? {
        get {
            access(keyPath: \.selection)
            let picked = UserDefaults.standard.string(forKey: Preference.model)
            return picked.flatMap { isInstalled($0) ? $0 : nil } ?? installed.first?.id
        }
        set { withMutation(keyPath: \.selection) { UserDefaults.standard.set(newValue, forKey: Preference.model) } }
    }

    /// Whether the model that runs would start otherwise with the options set now.
    var optionsChanged: Bool {
        guard server.phase == .ready, let model = server.model else { return false }
        return server.settings.differs(from: options, model: model)
    }

    /// The name to show for model `id`; its variant tells installed variants of a model apart.
    func displayName(of id: String) -> String {
        let name = catalog.name(of: id)
        guard installed.filter({ catalog.name(of: $0.id) == name }).count > 1 else { return name }
        return "\(name) (\(Catalog.variant(of: id)))"
    }

    /// Checks this Mac and the app's location, stops what the app left running last time, and
    /// then, in the background, installs the models the Hugging Face cache holds.
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
        Task { await installCached() }
    }

    /// Installs, without downloading, the models other tools or a source checkout of Splash left
    /// in the Hugging Face cache that Splash serves; the installer leaves out the rest.
    private func installCached() async {
        let runtime = runtime
        await Task.detached { runtime.installCached() }.value
        refresh()
    }

    /// Starts `model` with the launch options, stopping the one that runs first.
    func start(_ model: String) {
        guard ready else { return }
        selection = model
        chats.stop()
        server.start(model, settings: options)
    }

    func stop() {
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
        return ChatTarget(url: server.settings.url, model: model, acceptsImages: server.acceptsImages, effort: effort,
                          apiKey: server.settings.apiKey)
    }

    /// The reasoning effort messages to the model that runs ask for, as chosen for it; empty for
    /// its default.
    var effort: String {
        get {
            access(keyPath: \.effort)
            let efforts = UserDefaults.standard.dictionary(forKey: Preference.efforts) as? [String: String]
            return server.model.flatMap { efforts?[$0] } ?? ""
        }
        set {
            guard let model = server.model else { return }
            withMutation(keyPath: \.effort) {
                var efforts = UserDefaults.standard.dictionary(forKey: Preference.efforts) as? [String: String] ?? [:]
                efforts[model] = newValue.isEmpty ? nil : newValue
                UserDefaults.standard.set(efforts, forKey: Preference.efforts)
            }
        }
    }

    func copyAPIAddress() {
        let settings = server.running ? server.settings : options
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(settings.url.appending(path: "v1").absoluteString, forType: .string)
    }

    /// The models installed here, the suggested ones first in the list's order, then the model files
    /// on this Mac the user added.
    func refresh() {
        let rank = { (id: String) in self.catalog.variants.firstIndex { $0.id == id } ?? Int.max }
        installed = runtime.installedModels().sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
            + localModels.map(InstalledModel.local)
    }

    private var localModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: Preference.localModels) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Preference.localModels) }
    }

    /// Adds model files on this Mac, a GGUF file or a model's folder, and picks them: Start has
    /// Splash prepare them, and says why if it cannot serve them.
    func addLocal(_ url: URL) {
        if !localModels.contains(url.path) { localModels.append(url.path) }
        refresh()
        selection = url.path
    }

    /// Takes model files off the list; the files stay where they are.
    func removeLocal(_ path: String) {
        localModels.removeAll { $0 == path }
        refresh()
    }

    func isInstalled(_ model: String) -> Bool {
        installed.contains { $0.id == model }
    }

    /// Picks the model downloaded, for the user to start.
    private func didInstall(_ model: String) {
        refresh()
        selection = model
        if NSApp?.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Whether the app at `bundle` runs from the disk image or a translocated copy: its path then
    /// changes on every launch and its volume may go away while a model runs.
    static func mustMoveToApplications(_ bundle: URL) -> Bool {
        guard bundle.pathExtension == "app" else { return false }
        return bundle.path.contains("/AppTranslocation/")
            || (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }
}
