import AppKit
import SwiftUI

@MainActor
final class SummaryState: ObservableObject {
    @Published var text: String = ""
    @Published var isStreaming: Bool = true
    @Published var errorMessage: String?
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
}

@MainActor
final class SummaryPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(state: SummaryState, onClose: @escaping () -> Void) {
        self.window?.close()
        self.window = nil
        self.onClose = onClose

        state.onCopy = { [weak self] in self?.copyToClipboard(state.text) }
        state.onClose = { [weak self] in self?.close() }

        let view = SummaryView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MailMate — thread summary", comment: "")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 640, height: 500))
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
            let cb = self.onClose
            self.window = nil
            self.onClose = nil
            cb?()
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private struct SummaryView: View {
    @ObservedObject var state: SummaryState

    var body: some View {
        VStack(alignment: .leading, spacing: MMSpace.md) {
            HStack(spacing: 12) {
                MMBrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thread summary").font(MMFont.title)
                    HStack(spacing: 6) {
                        if state.isStreaming {
                            ProgressView().controlSize(.small)
                            Text("Summarizing…").font(MMFont.caption).foregroundStyle(.secondary)
                        } else if let err = state.errorMessage {
                            Text(err).font(MMFont.caption).foregroundStyle(.red).lineLimit(1)
                        } else {
                            Text("Ready.").font(MMFont.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            MMSectionLabel(text: "Summary", icon: "text.alignleft")

            ScrollView {
                Text(state.text.isEmpty ? "…" : state.text)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .foregroundStyle(state.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .mmTextArea()

            HStack {
                Button("Copy") { state.onCopy() }
                    .buttonStyle(MMPrimaryButtonStyle())
                    .disabled(state.text.isEmpty)
                    .opacity(state.text.isEmpty ? 0.5 : 1.0)
                Spacer()
                Button("Close") { state.onClose() }
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(MMSpace.lg)
        .frame(minWidth: 560, minHeight: 420)
        .mmPanelBackground()
    }
}
