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
            title: NSLocalizedString("Draft 3 reply options…", comment: ""),
            action: #selector(draft),
            keyEquivalent: "r"
        )
        draftItem.keyEquivalentModifierMask = [.command, .shift]
        draftItem.target = self
        menu.addItem(draftItem)

        let dictateItem = NSMenuItem(
            title: NSLocalizedString("Dictate a reply…", comment: ""),
            action: #selector(dictate),
            keyEquivalent: "d"
        )
        dictateItem.keyEquivalentModifierMask = [.command, .shift]
        dictateItem.target = self
        menu.addItem(dictateItem)

        let summaryItem = NSMenuItem(
            title: NSLocalizedString("Summarize thread…", comment: ""),
            action: #selector(summarize),
            keyEquivalent: "s"
        )
        summaryItem.keyEquivalentModifierMask = [.command, .shift]
        summaryItem.target = self
        menu.addItem(summaryItem)

        let taskItem = NSMenuItem(
            title: NSLocalizedString("Dictate a task…", comment: ""),
            action: #selector(voiceTask),
            keyEquivalent: "t"
        )
        taskItem.keyEquivalentModifierMask = [.command, .shift]
        taskItem.target = self
        menu.addItem(taskItem)

        let triageItem = NSMenuItem(
            title: NSLocalizedString("Triage inbox…", comment: ""),
            action: #selector(triage),
            keyEquivalent: "i"
        )
        triageItem.keyEquivalentModifierMask = [.command, .shift]
        triageItem.target = self
        menu.addItem(triageItem)

        menu.addItem(.separator())

        let rulesItem = NSMenuItem(title: NSLocalizedString("Edit rules…", comment: ""),
                                   action: #selector(editRules),
                                   keyEquivalent: "")
        rulesItem.target = self
        menu.addItem(rulesItem)

        let overridesItem = NSMenuItem(title: NSLocalizedString("Edit per-client overrides…", comment: ""),
                                       action: #selector(editOverrides),
                                       keyEquivalent: "")
        overridesItem.target = self
        menu.addItem(overridesItem)

        let proposalItem = NSMenuItem(title: NSLocalizedString("Generate rules from sent mail…", comment: ""),
                                      action: #selector(proposeRules),
                                      keyEquivalent: "")
        proposalItem.target = self
        menu.addItem(proposalItem)

        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""),
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit MailMate", comment: ""),
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

    @objc private func triage() {
        Task { @MainActor in
            await ReplyDrafter.shared.runTriage()
        }
    }

    @objc private func editRules() {
        RulesLoader.openInEditor()
    }

    @objc private func editOverrides() {
        RulesLoader.openInEditor(overrides: true)
    }

    @objc private func proposeRules() {
        Task { @MainActor in
            await ReplyDrafter.shared.runRulesProposal()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("MailMate Settings", comment: "")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
