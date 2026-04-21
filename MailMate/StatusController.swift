import AppKit
import SwiftUI

@MainActor
class StatusController: NSObject {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var providerObserver: NSObjectProtocol?

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        refreshStatusItem()

        let menu = NSMenu()

        let draftItem = NSMenuItem(
            title: "Draft 3 reply options…",
            action: #selector(draft),
            keyEquivalent: "r"
        )
        draftItem.keyEquivalentModifierMask = [.command, .shift]
        draftItem.target = self
        menu.addItem(draftItem)

        let dictateItem = NSMenuItem(
            title: "Dictate a reply…",
            action: #selector(dictate),
            keyEquivalent: "d"
        )
        dictateItem.keyEquivalentModifierMask = [.command, .shift]
        dictateItem.target = self
        menu.addItem(dictateItem)

        let summaryItem = NSMenuItem(
            title: "Summarize thread…",
            action: #selector(summarize),
            keyEquivalent: "s"
        )
        summaryItem.keyEquivalentModifierMask = [.command, .shift]
        summaryItem.target = self
        menu.addItem(summaryItem)

        let taskItem = NSMenuItem(
            title: "Dictate a task…",
            action: #selector(voiceTask),
            keyEquivalent: "t"
        )
        taskItem.keyEquivalentModifierMask = [.command, .shift]
        taskItem.target = self
        menu.addItem(taskItem)

        menu.addItem(.separator())

        let rulesItem = NSMenuItem(title: "Edit rules…",
                                   action: #selector(editRules),
                                   keyEquivalent: "")
        rulesItem.target = self
        menu.addItem(rulesItem)

        let overridesItem = NSMenuItem(title: "Edit per-client overrides…",
                                       action: #selector(editOverrides),
                                       keyEquivalent: "")
        overridesItem.target = self
        menu.addItem(overridesItem)

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MailMate",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu

        providerObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatusItem() }
        }

        NotificationCenter.default.addObserver(
            forName: .mailMateOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }
    }

    deinit {
        if let obs = providerObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func refreshStatusItem() {
        let kind = ProviderFactory.current
        let letter: String
        switch kind {
        case .anthropic: letter = "A"
        case .openai:    letter = "O"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: "envelope.badge",
            accessibilityDescription: "MailMate (\(kind.displayName))"
        )
        statusItem.button?.title = " \(letter)"
        statusItem.button?.toolTip = "MailMate — active provider: \(kind.displayName)"
    }

    @objc private func draft() {
        Task { @MainActor in
            await ReplyDrafter.shared.run()
        }
    }

    @objc private func dictate() {
        Task { @MainActor in
            await ReplyDrafter.shared.runDictation()
        }
    }

    @objc private func summarize() {
        Task { @MainActor in
            await ReplyDrafter.shared.runSummary()
        }
    }

    @objc private func voiceTask() {
        Task { @MainActor in
            await ReplyDrafter.shared.runVoiceTask()
        }
    }

    @objc private func editRules() {
        RulesLoader.openInEditor()
    }

    @objc private func editOverrides() {
        RulesLoader.openInEditor(overrides: true)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "MailMate Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
