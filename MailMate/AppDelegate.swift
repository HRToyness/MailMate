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
}
