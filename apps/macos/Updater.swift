import Foundation
import Sparkle

/// Sparkle updates for release builds. A build without a feed and public key in
/// its Info.plist (a development build) has no updater. Updates are checked
/// daily and installed only when the user agrees.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    let isConfigured: Bool
    @Published private(set) var automaticChecks = false
    private var controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        isConfigured = feed != nil && !key.isEmpty
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticChecks = controller.updater.automaticallyChecksForUpdates
    }

    func check() { controller?.checkForUpdates(nil) }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticChecks = updater.automaticallyChecksForUpdates
    }
}
