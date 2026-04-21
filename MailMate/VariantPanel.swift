import AppKit
import SwiftUI

/// Live state for the variant panel. Updated as the stream arrives.
@MainActor
final class VariantStreamState: ObservableObject {
    @Published var variants = ReplyVariants(short: "", standard: "", detailed: "")
    @Published var isStreaming = true
    @Published var errorMessage: String?

    /// When non-nil, the panel switches to edit mode showing this text in an
    /// editable text area. Setting back to nil returns to the cards.
    @Published var editing: EditingSelection?

    struct EditingSelection: Equatable {
        let label: String
        var text: String
    }
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
        self.window?.close()
        self.window = nil

        self.onPick = onPick
        self.onClose = onClose
        self.pickMade = false

        let view = VariantPickerView(
            state: state,
            onUse: { [weak self] text in
                self?.pickMade = true
                self?.onPick?(text)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MailMate — pick a reply", comment: "")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 900, height: 500))
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let closeHandler = self.onClose
            self.window = nil
            self.onPick = nil
            self.onClose = nil
            if !self.pickMade {
                closeHandler?()
            }
        }
    }
}

private struct VariantPickerView: View {
    @ObservedObject var state: VariantStreamState
    /// Called with the final text when the user commits a pick (either
    /// directly from a card or after editing).
    let onUse: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        if let editing = state.editing {
            EditView(
                label: editing.label,
                initial: editing.text,
                onUse: { edited in onUse(edited) },
                onBack: { state.editing = nil }
            )
        } else {
            PickView(state: state,
                     onEdit: { label, text in
                         state.editing = .init(label: label, text: text)
                     },
                     onCancel: onCancel)
        }
    }
}

private struct PickView: View {
    @ObservedObject var state: VariantStreamState
    let onEdit: (String, String) -> Void
    let onCancel: () -> Void

    private var cards: [(label: String, text: String, key: String)] {
        [
            ("Short",    state.variants.short,    "1"),
            ("Standard", state.variants.standard, "2"),
            ("Detailed", state.variants.detailed, "3"),
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(cards.indices, id: \.self) { idx in
                    VariantCard(
                        label: cards[idx].label,
                        text: cards[idx].text,
                        shortcut: cards[idx].key,
                        isStreaming: state.isStreaming,
                        onUse: { onEdit(cards[idx].label, cards[idx].text) }
                    )
                }
            }
            HStack(spacing: 8) {
                if state.isStreaming {
                    ProgressView().controlSize(.small)
                    Text("Generating… (press 1/2/3 to pick)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Press 1/2/3 to pick, edit if needed, then ⌘↩ to paste.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .frame(minWidth: 600, minHeight: 380)
    }
}

private struct VariantCard: View {
    let label: String
    let text: String
    let shortcut: String
    let isStreaming: Bool
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                Text(shortcut)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

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

            Button(action: onUse) {
                Text("Use this")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: [])
            .disabled(text.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditView: View {
    let label: String
    let initial: String
    let onUse: (String) -> Void
    let onBack: () -> Void

    @State private var text: String

    init(label: String, initial: String, onUse: @escaping (String) -> Void, onBack: @escaping () -> Void) {
        self.label = label
        self.initial = initial
        self.onUse = onUse
        self.onBack = onBack
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(label.uppercased())
                    .font(.caption).foregroundStyle(.secondary).tracking(1.5)
                Spacer()
                Text("⌘↩ to paste · esc to go back")
                    .font(.caption).foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(.body))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(6)

            HStack {
                Button("← Back", action: onBack)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Paste into Mail") { onUse(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 380)
    }
}
