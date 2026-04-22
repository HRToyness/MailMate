import AppKit
import SwiftUI

@MainActor
final class RulesProposalState: ObservableObject {
    enum Phase {
        case loading
        case ready
        case error(String)
    }
    @Published var phase: Phase = .loading
    @Published var proposedRules: String = ""
    @Published var scannedCount: Int = 0
    @Published var saveError: String?
    @Published var savedFlash: String?

    var onReplace: () -> Void = {}
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
}

@MainActor
final class RulesProposalPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let state = RulesProposalState()

    func show() {
        self.window?.close()
        self.window = nil

        let view = RulesProposalView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MailMate — Rules from your sent mail", comment: "")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 680, height: 620))
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cb = self.state.onClose
            self.window = nil
            cb()
        }
    }
}

private struct RulesProposalView: View {
    @ObservedObject var state: RulesProposalState

    var body: some View {
        VStack(alignment: .leading, spacing: MMSpace.md) {
            HStack(spacing: 12) {
                MMBrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rules from your sent mail").font(MMFont.title)
                    subtitle
                }
                Spacer()
            }

            MMSectionLabel(text: "Proposed rules.md", icon: "sparkles")

            TextEditor(text: $state.proposedRules)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .mmTextArea()

            footer
        }
        .padding(MMSpace.lg)
        .frame(minWidth: 560, minHeight: 480)
        .mmPanelBackground()
    }

    @ViewBuilder
    private var subtitle: some View {
        switch state.phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.scannedCount == 0
                     ? "Reading your sent folder…"
                     : "Analyzing \(state.scannedCount) sent emails…")
                    .font(MMFont.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Text("Based on \(state.scannedCount) recent sent messages. Review, edit, and save.")
                .font(MMFont.caption).foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg).font(MMFont.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Copy to clipboard") { state.onCopy() }
                .buttonStyle(MMGhostButtonStyle())
                .disabled(state.proposedRules.isEmpty)
            Spacer()
            if let flash = state.savedFlash {
                Text(flash).font(MMFont.caption).foregroundStyle(.green)
            }
            if let err = state.saveError {
                Text(err).font(MMFont.caption).foregroundStyle(.red)
            }
            Button("Close") { state.onClose() }
                .buttonStyle(MMGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Replace my rules…") { state.onReplace() }
                .buttonStyle(MMPrimaryButtonStyle())
                .disabled(state.proposedRules.isEmpty)
                .opacity(state.proposedRules.isEmpty ? 0.5 : 1.0)
        }
    }
}
