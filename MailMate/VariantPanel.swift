import AppKit
import SwiftUI

/// Live state for the variant panel. Updated as the stream arrives.
@MainActor
final class VariantStreamState: ObservableObject {
    @Published var variants = ReplyVariants(short: "", standard: "", detailed: "")
    @Published var isStreaming = true
    @Published var errorMessage: String?
}

/// Floating panel that shows three reply variants. Cards fill in live as the
/// stream arrives. The window delegate fires `onClose` whenever the window
/// closes (× button, Cancel, or a `close()` call) so callers can cancel any
/// in-flight work.
@MainActor
final class VariantPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onPick: ((String) -> Void)?
    private var onClose: (() -> Void)?
    private var pickMade = false

    func show(state: VariantStreamState,
              onPick: @escaping (String) -> Void,
              onClose: @escaping () -> Void) {
        // Defensive: close any previous window from a prior run.
        self.window?.close()
        self.window = nil

        self.onPick = onPick
        self.onClose = onClose
        self.pickMade = false

        let view = VariantPickerView(
            state: state,
            onPick: { [weak self] text in
                self?.pickMade = true
                self?.onPick?(text)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MailMate — pick a reply"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 900, height: 460))
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    // NSWindowDelegate
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let closeHandler = self.onClose
            self.window = nil
            self.onPick = nil
            self.onClose = nil
            // If the window was closed without picking (× or Cancel), notify the caller.
            if !self.pickMade {
                closeHandler?()
            }
        }
    }
}

private struct VariantPickerView: View {
    @ObservedObject var state: VariantStreamState
    let onPick: (String) -> Void
    let onCancel: () -> Void

    private var cards: [(label: String, text: String)] {
        [
            ("Short", state.variants.short),
            ("Standard", state.variants.standard),
            ("Detailed", state.variants.detailed),
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(cards.indices, id: \.self) { idx in
                    VariantCard(
                        label: cards[idx].label,
                        text: cards[idx].text,
                        isStreaming: state.isStreaming,
                        onPick: { onPick(cards[idx].text) }
                    )
                }
            }
            HStack(spacing: 8) {
                if state.isStreaming {
                    ProgressView().controlSize(.small)
                    Text("Generating…").font(.caption).foregroundStyle(.secondary)
                }
                if let err = state.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 360)
    }
}

private struct VariantCard: View {
    let label: String
    let text: String
    let isStreaming: Bool
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .tracking(1.5)

            ScrollView {
                Text(text.isEmpty ? (isStreaming ? "…" : "(empty)") : text)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(6)

            Button("Use this", action: onPick)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(text.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
