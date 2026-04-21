import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProviderFactory.runMigrationsIfNeeded()
        Task { @MainActor in
            ReplyDrafter.shared.requestNotificationAuthorization()
        }
        statusController = StatusController()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Show the welcome window on first run.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            WelcomeController.showIfFirstRun()
        }
    }

    @objc func draftAIReply(_ pboard: NSPasteboard,
                            userData: String,
                            error: NSErrorPointer) {
        Task { @MainActor in
            await ReplyDrafter.shared.run()
        }
    }

    @objc func dictateAIReply(_ pboard: NSPasteboard,
                              userData: String,
                              error: NSErrorPointer) {
        Task { @MainActor in
            await ReplyDrafter.shared.runDictation()
        }
    }

    @objc func summarizeThread(_ pboard: NSPasteboard,
                               userData: String,
                               error: NSErrorPointer) {
        Task { @MainActor in
            await ReplyDrafter.shared.runSummary()
        }
    }

    @objc func voiceTask(_ pboard: NSPasteboard,
                         userData: String,
                         error: NSErrorPointer) {
        Task { @MainActor in
            await ReplyDrafter.shared.runVoiceTask()
        }
    }

    @objc func triageInbox(_ pboard: NSPasteboard,
                           userData: String,
                           error: NSErrorPointer) {
        Task { @MainActor in
            await ReplyDrafter.shared.runTriage()
        }
    }
}
