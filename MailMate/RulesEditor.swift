import AppKit
import SwiftUI

/// A simple built-in editor for the user's rules and per-client overrides.
@MainActor
final class RulesEditor: NSObject, NSWindowDelegate {
    static let shared = RulesEditor()

    enum Kind {
        case base, overrides

        var fileURL: URL {
            switch self {
            case .base: return RulesLoader.rulesFileURL
            case .overrides: return RulesLoader.overridesFileURL
            }
        }

        var windowTitle: String {
            switch self {
            case .base: return NSLocalizedString("MailMate — Rules", comment: "")
            case .overrides: return NSLocalizedString("MailMate — Per-client overrides", comment: "")
            }
        }

        var headerText: String {
            switch self {
            case .base:
                return NSLocalizedString("Markdown. These rules are sent to the model as part of every request.", comment: "")
            case .overrides:
                return NSLocalizedString("Per-sender rule overrides. Each \"## <pattern>\" section replaces the base rules when the sender matches. First match wins.", comment: "")
            }
        }

        var defaultText: String {
            switch self {
            case .base: return RulesLoader.defaultRules
            case .overrides: return RulesLoader.defaultOverrides
            }
        }
    }

    private var window: NSWindow?

    func show(editing kind: Kind = .base) {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let state = RulesEditorState(kind: kind)
        let view = RulesEditorView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = kind.windowTitle
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 560))
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.window = nil
        }
    }
}

@MainActor
final class RulesEditorState: ObservableObject {
    let kind: RulesEditor.Kind
    @Published var text: String
    @Published var status: String = ""
    @Published var dirty: Bool = false

    private var suppressDirty = false

    init(kind: RulesEditor.Kind) {
        self.kind = kind
        let url = kind.fileURL
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            self.text = existing
        } else {
            self.text = kind.defaultText
        }
        self.suppressDirty = true
        self.dirty = false
        self.suppressDirty = false
    }

    func markChanged() {
        if suppressDirty { return }
        dirty = true
        status = ""
    }

    func save() {
        do {
            try text.write(to: kind.fileURL, atomically: true, encoding: .utf8)
            dirty = false
            status = "Saved"
            Log.write("\(kind.windowTitle) saved (len=\(text.count))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.status == "Saved" { self?.status = "" }
            }
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            Log.write("Rules save failed: \(error.localizedDescription)")
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([kind.fileURL])
    }

    func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset to the built-in defaults?"
        alert.informativeText = "This replaces the current content. Your current text will be lost."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            suppressDirty = false
            text = kind.defaultText
            dirty = true
            status = ""
        }
    }
}

private struct RulesEditorView: View {
    @ObservedObject var state: RulesEditorState

    var body: some View {
        VStack(spacing: 0) {
            Text(state.kind.headerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            TextEditor(text: $state.text)
                .font(.system(.body, design: .monospaced))
                .onChange(of: state.text) { _, _ in state.markChanged() }
                .padding(.horizontal, 12)

            Divider()

            HStack(spacing: 8) {
                Button("Reveal in Finder") { state.revealInFinder() }
                Button("Reset to defaults…") { state.resetToDefaults() }
                Spacer()
                if !state.status.isEmpty {
                    Text(state.status)
                        .font(.caption)
                        .foregroundStyle(state.status.hasPrefix("Save failed") ? .red : .green)
                }
                Button("Save") { state.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.dirty)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}
