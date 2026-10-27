import Foundation
import Observation

/// What the app's windows and menus show: the runtime, the server, downloads and the models.
@MainActor @Observable
final class AppState {
    enum Tab: Hashable { case chat, models }

    let runtime: Runtime
    let server: Server
    let installer: Installer
    let catalog: Catalog
    private(set) var installed: [InstalledModel] = []
    /// Why the app cannot run models here, if it cannot.
    private(set) var blocker: String?
    var tab = Tab.models
    /// Set once the app quits: nothing starts any more.
    private(set) var quitting = false

    init(runtime: Runtime) {
        self.runtime = runtime
        server = Server(runtime: runtime)
        installer = Installer(runtime: runtime)
        catalog = Catalog(contentsOf: runtime.suggestedModels)
        installer.installed = { [weak self] in self?.didInstall($0) }
        refresh()
    }

    /// Checks this Mac and the app's location, stops what the app left running last time, and
    /// starts the last model if it served then.
    func launch() async {
        let runtime = runtime
        if let reason = await Task.detached(operation: { runtime.unsupportedReason() }).value {
            blocker = reason
            return
        }
        if Self.mustMoveToApplications {
            blocker = "Move Splash to your Applications folder, then open it from there."
            return
        }
        await server.stopLeftover()
        let defaults = UserDefaults.standard
        // Unless the user started a model meanwhile.
        if defaults.bool(forKey: Preference.startOnOpen), defaults.bool(forKey: Preference.lastModelServed),
           let model = defaults.string(forKey: Preference.lastModel), isInstalled(model),
           !server.running, server.model == nil {
            start(model)
        }
    }

    func start(_ model: String) {
        guard !quitting else { return }
        server.start(model)
        tab = .chat
    }

    /// Stops the download and the model for the app to quit, and starts nothing after.
    func quit() {
        quitting = true
        installer.cancel()
        server.stop()
    }

    func refresh() {
        installed = runtime.installedModels()
    }

    func isInstalled(_ model: String) -> Bool {
        installed.contains { $0.id == model }
    }

    private func didInstall(_ model: String) {
        refresh()
        if !server.running { start(model) }
    }

    /// Run from the disk image or a translocated copy, the app's path changes on every launch and
    /// its volume may go away while a model runs.
    private static var mustMoveToApplications: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        return bundle.path.contains("/AppTranslocation/")
            || (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }
}
