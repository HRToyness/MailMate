import AppKit
import Foundation
import SwiftUI

enum TriagePriority: String, Decodable {
    case urgent, normal, low, spam

    var label: String {
        switch self {
        case .urgent: return NSLocalizedString("Urgent", comment: "")
        case .normal: return NSLocalizedString("Normal", comment: "")
        case .low:    return NSLocalizedString("Low",    comment: "")
        case .spam:   return NSLocalizedString("Spam",   comment: "")
        }
    }

    var color: Color {
        switch self {
        case .urgent: return .red
        case .normal: return MMColor.indigo
        case .low:    return .secondary
        case .spam:   return .secondary
        }
    }
}

struct TriageEntry: Identifiable, Decodable {
    var id: String { messageID }
    let index: Int
    let priority: TriagePriority
    let summary: String
    let action: String

    var sender: String = ""
    var subject: String = ""
    var messageID: String = ""

    enum CodingKeys: String, CodingKey { case index, priority, summary, action }
}

@MainActor
final class TriageState: ObservableObject {
    enum Phase {
        case loading
        case ready
        case error(String)
    }
    @Published var phase: Phase = .loading
    @Published var entries: [TriageEntry] = []
    @Published var sourceCount: Int = 0
    var onRefresh: () -> Void = {}
    var onSelect: (TriageEntry) -> Void = { _ in }
    var onClose: () -> Void = {}
}

@MainActor
final class TriagePanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let state = TriageState()

    func show() {
        self.window?.close()
        self.window = nil

        let view = TriagePanelView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MailMate — Inbox triage", comment: "")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 720, height: 600))
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

private struct TriagePanelView: View {
    @ObservedObject var state: TriageState

    var body: some View {
        VStack(alignment: .leading, spacing: MMSpace.md) {
            HStack(spacing: 12) {
                MMBrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inbox triage").font(MMFont.title)
                    switch state.phase {
                    case .loading:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading your inbox…")
                                .font(MMFont.caption).foregroundStyle(.secondary)
                        }
                    case .ready:
                        Text("\(state.entries.count) of \(state.sourceCount) unread messages")
                            .font(MMFont.caption).foregroundStyle(.secondary)
                    case .error(let msg):
                        Text(msg).font(MMFont.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                Spacer()
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.entries) { entry in
                        EntryRow(entry: entry) { state.onSelect(entry) }
                    }
                    if case .ready = state.phase, state.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Nothing to triage.").foregroundStyle(.secondary)
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(2)
            }

            HStack {
                Button("Refresh") { state.onRefresh() }
                    .buttonStyle(MMPrimaryButtonStyle(compact: true))
                    .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button("Close") { state.onClose() }
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(MMSpace.lg)
        .frame(minWidth: 600, minHeight: 460)
        .mmPanelBackground()
    }
}

private struct EntryRow: View {
    let entry: TriageEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(entry.priority.color)
                    .frame(width: 10, height: 10)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.sender)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(entry.subject)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        MMPill(text: entry.priority.label, color: entry.priority.color)
                    }
                    Text(entry.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(entry.action)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 7)
            }
            .mmCard(padding: 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
