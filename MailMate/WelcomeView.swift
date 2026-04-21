import AppKit
import SwiftUI

extension Notification.Name {
    static let mailMateOpenSettings = Notification.Name("com.toynessit.MailMate.openSettings")
}

/// First-run welcome shown once, gated by UserDefaults key `welcome_seen`.
@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    static let shared = WelcomeController()

    private var window: NSWindow?

    static var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: "welcome_seen")
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: "welcome_seen")
    }

    /// Show the welcome window if it hasn't been seen yet. Returns true if
    /// shown.
    @discardableResult
    static func showIfFirstRun() -> Bool {
        guard !hasBeenSeen else { return false }
        shared.show()
        return true
    }

    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = WelcomeView(
            onOpenSettings: { [weak self] in
                self?.close()
                NotificationCenter.default.post(name: .mailMateOpenSettings, object: nil)
            },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("Welcome to MailMate", comment: "")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        Self.markSeen()
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            Self.markSeen()
            self?.window = nil
        }
    }
}

private struct WelcomeView: View {
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MMBrandGlyph(size: 64)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to MailMate").font(.title2).bold()
                    Text("AI replies for Mail.app, with voice dictation.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Two ways to use it")
                .font(.headline)

            HStack(alignment: .top, spacing: 14) {
                welcomeFeature(
                    icon: "text.bubble",
                    title: "Draft 3 reply options",
                    body: "Select a message in Mail, click the menu bar icon → Draft 3 reply options (⌘⇧R). You get Short / Standard / Detailed variants side by side. Press 1, 2, or 3 to pick, tweak if needed, then ⌘↩ to paste."
                )
                welcomeFeature(
                    icon: "mic.fill",
                    title: "Dictate a reply",
                    body: "Select a message, click Dictate a reply (⌘⇧D), press record, and say what you want to say in plain Dutch or English. MailMate transcribes and cleans it into a proper reply."
                )
            }

            Divider()

            Text("Before your first reply")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                bullet("Paste your API key(s) in Settings (Anthropic and/or OpenAI).")
                bullet("Voice dictation requires an OpenAI key (Whisper).")
                bullet("Grant Automation, Accessibility, and Microphone permission when macOS prompts — each is a one-time click.")
                bullet("Menu bar icon: envelope badge. The letter next to it shows the active provider (A/O).")
            }
            .font(.body)

            Spacer(minLength: 0)

            HStack {
                Button("Later") { onClose() }
                    .buttonStyle(MMGhostButtonStyle())
                Spacer()
                Button("Open Settings") { onOpenSettings() }
                    .buttonStyle(MMPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 460)
        .mmPanelBackground()
    }

    @ViewBuilder
    private func welcomeFeature(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(title).font(.subheadline).bold()
            }
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}
