import AppKit
import SwiftUI

/// Live state for the variant panel. Updated as the stream arrives.
@MainActor
final class VariantStreamState: ObservableObject {
    @Published var variants = ReplyVariants(short: "", standard: "", detailed: "")
    @Published var isStreaming = true
    @Published var errorMessage: String?

    @Published var editing: EditingSelection?

    struct EditingSelection: Equatable {
        let label: String
        var text: String
    }
}

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
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 960, height: 560))
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
    let onUse: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Group {
                if let editing = state.editing {
                    EditView(
                        label: editing.label,
                        initial: editing.text,
                        onUse: { edited in onUse(edited) },
                        onBack: { state.editing = nil }
                    )
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    PickView(state: state,
                             onEdit: { label, text in
                                 withAnimation(.snappy(duration: 0.25)) {
                                     state.editing = .init(label: label, text: text)
                                 }
                             },
                             onCancel: onCancel)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .mmPanelBackground()
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
        VStack(spacing: MMSpace.md) {
            HStack(spacing: 12) {
                MMBrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick a reply").font(MMFont.title)
                    Text("Short / Standard / Detailed — streaming")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 4)

            HStack(spacing: MMSpace.sm) {
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
                    Text("Generating… (press 1 / 2 / 3 to pick)")
                        .font(MMFont.caption).foregroundStyle(.secondary)
                } else {
                    Text("Press 1 / 2 / 3 to pick, edit if needed, then ⌘↩ to paste.")
                        .font(MMFont.caption).foregroundStyle(.secondary)
                }
                if let err = state.errorMessage {
                    MMPill(text: "error", color: .red)
                    Text(err).font(MMFont.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(MMSpace.lg)
    }
}

private struct VariantCard: View {
    let label: String
    let text: String
    let shortcut: String
    let isStreaming: Bool
    let onUse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MMSectionLabel(text: label)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(LinearGradient.mmBrand))
            }

            ScrollView {
                Text(text.isEmpty ? (isStreaming ? "…" : "(empty)") : text)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .mmTextArea()

            Button(action: onUse) {
                Text("Use this")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MMPrimaryButtonStyle())
            .keyboardShortcut(KeyEquivalent(Character(shortcut)), modifiers: [])
            .disabled(text.isEmpty)
            .opacity(text.isEmpty ? 0.5 : 1.0)
        }
        .mmCard()
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
        VStack(spacing: MMSpace.md) {
            HStack {
                MMSectionLabel(text: label)
                Spacer()
                Text("⌘↩ to paste · esc to go back")
                    .font(MMFont.caption).foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(.body))
                .padding(8)
                .mmTextArea()

            HStack {
                Button("← Back", action: onBack)
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Paste into Mail") { onUse(text) }
                    .buttonStyle(MMPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.isEmpty)
                    .opacity(text.isEmpty ? 0.5 : 1.0)
            }
        }
        .padding(MMSpace.lg)
    }
}
