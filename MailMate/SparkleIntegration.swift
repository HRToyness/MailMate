import AppKit
import Sparkle

/// Wraps Sparkle's SPUStandardUpdaterController so the rest of the app can
/// stay Sparkle-agnostic. Constructed lazily at first use and kept alive for
/// the app's lifetime. All delegate methods run on the main thread.
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // `startingUpdater: true` starts the background check loop using
        // SUFeedURL from Info.plist. We pass `self` as updater delegate for
        // log/telemetry hooks.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        Log.write("Sparkle updater started, feed=\(controller.updater.feedURL?.absoluteString ?? "<none>")")
    }

    /// Trigger a user-initiated update check (menu item handler).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Log.write("Sparkle appcast loaded: \(appcast.items.count) items")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.write("Sparkle found update: \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.write("Sparkle: no update available")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.write("Sparkle error: \(error.localizedDescription)")
    }
}
