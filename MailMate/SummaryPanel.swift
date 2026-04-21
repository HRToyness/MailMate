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
        window.title = "MailMate — thread summary"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 640, height: 480))
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
        VStack(spacing: 10) {
            HStack {
                Text("SUMMARY").font(.caption).foregroundStyle(.secondary).tracking(1.5)
                Spacer()
                if state.isStreaming {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(.caption).foregroundStyle(.secondary)
                }
                if let err = state.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            ScrollView {
                Text(state.text.isEmpty ? "…" : state.text)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .foregroundStyle(state.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(6)

            HStack {
                Button("Copy") { state.onCopy() }
                    .disabled(state.text.isEmpty)
                Spacer()
                Button("Close") { state.onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 360)
    }
}
