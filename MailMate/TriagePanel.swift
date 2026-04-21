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
        case .normal: return .accentColor
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

    // Populated from the original TriageMessage after parsing the model output:
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
        window.setContentSize(NSSize(width: 700, height: 560))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TRIAGE").font(.caption).foregroundStyle(.secondary).tracking(1.5)
                Spacer()
                switch state.phase {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading inbox…").font(.caption).foregroundStyle(.secondary)
                    }
                case .ready:
                    Text("\(state.entries.count) of \(state.sourceCount) unread")
                        .font(.caption).foregroundStyle(.secondary)
                case .error(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.entries) { entry in
                        EntryRow(entry: entry) { state.onSelect(entry) }
                    }
                    if case .ready = state.phase, state.entries.isEmpty {
                        Text("Nothing to triage.").foregroundStyle(.secondary).padding(20)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .cornerRadius(6)

            HStack {
                Button("Refresh") { state.onRefresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button("Close") { state.onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 420)
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
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.sender).font(.body).bold().lineLimit(1)
                        Text("—").foregroundStyle(.tertiary)
                        Text(entry.subject).font(.body).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(entry.priority.label.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(entry.priority.color)
                    }
                    Text(entry.summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text("Suggested:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.action)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
