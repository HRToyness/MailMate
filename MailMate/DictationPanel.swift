import AppKit
import SwiftUI

enum DictationPhase {
    case idle
    case recording
    case transcribing
    case generating
    case ready
    case error(String)
}

@MainActor
final class DictationState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var transcript: String = ""
    @Published var reply: String = ""

    // Intents — the orchestrator (ReplyDrafter) sets these closures so the
    // view can call back without holding a strong reference to the drafter.
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onUse: () -> Void = {}
    var onRerecord: () -> Void = {}
    var onCancel: () -> Void = {}

    // Mirrors from AudioRecorder (set by orchestrator).
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class DictationPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let state = DictationState()

    func show() {
        // Defensive: close any previous window from a prior run.
        self.window?.close()
        self.window = nil

        let view = DictationPanelView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MailMate — Dictate a reply"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 620, height: 520))
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
            let cancel = self.state.onCancel
            self.window = nil
            // Fire onCancel so the orchestrator cleans up recording/streaming.
            cancel()
        }
    }
}

private struct DictationPanelView: View {
    @ObservedObject var state: DictationState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            bodySection
                .frame(maxHeight: .infinity)
            footerSection
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 440)
    }

    @ViewBuilder
    private var headerSection: some View {
        switch state.phase {
        case .idle:
            Text("Press record and dictate your reply in Dutch or English.")
                .foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(0.6 + 0.4 * Double(state.level))
                Text(timerString(state.elapsed)).monospacedDigit()
                LevelMeter(level: state.level)
                    .frame(height: 14)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
        case .generating:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing reply…").foregroundStyle(.secondary)
            }
        case .ready:
            Text("Reply ready — review and use, or re-record.")
                .foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        switch state.phase {
        case .idle, .recording:
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    recordButton
                    Spacer()
                }
                Spacer()
            }
        case .transcribing, .generating, .ready, .error:
            VStack(alignment: .leading, spacing: 10) {
                if !state.transcript.isEmpty {
                    sectionLabel("Transcript")
                    ScrollView {
                        Text(state.transcript)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 100)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .cornerRadius(6)
                }
                sectionLabel("Cleaned reply")
                ScrollView {
                    Text(state.reply.isEmpty ? "…" : state.reply)
                        .font(.body)
                        .textSelection(.enabled)
                        .foregroundStyle(state.reply.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(6)
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        HStack {
            switch state.phase {
            case .idle:
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .keyboardShortcut(.cancelAction)
            case .recording:
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .keyboardShortcut(.cancelAction)
            case .transcribing, .generating:
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .keyboardShortcut(.cancelAction)
            case .ready:
                Button("Re-record", action: state.onRerecord)
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use this", action: state.onUse)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .error:
                Button("Re-record", action: state.onRerecord)
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var recordButton: some View {
        let isRecording = {
            if case .recording = state.phase { return true } else { return false }
        }()
        return Button(action: {
            isRecording ? state.onStop() : state.onStart()
        }) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.red.opacity(0.8))
                    .frame(width: 96, height: 96)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .foregroundStyle(.secondary)
            .tracking(1.3)
    }

    private func timerString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
