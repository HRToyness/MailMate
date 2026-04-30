// Compiled only when Sparkle isn't on the import path — keeps the
// "Check for updates…" menu item wired up in builds that ship without
// the updater (e.g. an Xcode build without vendor/ configured).
#if !canImport(Sparkle)
import AppKit

/// No-op stub used when vendor/Sparkle.framework is not present at build
/// time. Keeps the rest of the codebase compiling and the "Check for
/// updates…" menu item visible — it just shows a notice.
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Auto-update not compiled in"
        alert.informativeText = "This build of MailMate was compiled without Sparkle. Download the latest release manually from https://hrtoyness.github.io/MailMate/"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
#endif
