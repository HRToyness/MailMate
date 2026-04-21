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

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onUse: () -> Void = {}
    var onRerecord: () -> Void = {}
    var onCancel: () -> Void = {}

    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class DictationPanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let state = DictationState()

    func show() {
        self.window?.close()
        self.window = nil

        let view = DictationPanelView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MailMate — Dictate a reply", comment: "")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 660, height: 560))
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
            let cancel = self.state.onCancel
            self.window = nil
            cancel()
        }
    }
}

private struct DictationPanelView: View {
    @ObservedObject var state: DictationState

    var body: some View {
        VStack(alignment: .leading, spacing: MMSpace.md) {
            HStack(spacing: 12) {
                MMBrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictate a reply").font(MMFont.title)
                    headerSubtitle
                }
                Spacer()
            }

            bodySection
                .frame(maxHeight: .infinity)

            footerSection
        }
        .padding(MMSpace.lg)
        .frame(minWidth: 600, minHeight: 480)
        .mmPanelBackground()
    }

    @ViewBuilder
    private var headerSubtitle: some View {
        switch state.phase {
        case .idle:
            Text("Press record and speak in Dutch or English.")
                .font(MMFont.caption).foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .opacity(0.6 + 0.4 * Double(state.level))
                Text(timerString(state.elapsed))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                LevelMeter(level: state.level).frame(width: 140, height: 10)
            }
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(MMFont.caption).foregroundStyle(.secondary)
            }
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Writing reply…").font(MMFont.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Text("Reply ready — review, edit, and paste.")
                .font(MMFont.caption).foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg).font(MMFont.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        switch state.phase {
        case .idle, .recording:
            VStack {
                Spacer()
                RecordButton(isRecording: {
                    if case .recording = state.phase { return true } else { return false }
                }(), onTap: {
                    if case .recording = state.phase { state.onStop() } else { state.onStart() }
                })
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .transcribing, .generating, .ready, .error:
            VStack(alignment: .leading, spacing: MMSpace.sm) {
                if !state.transcript.isEmpty {
                    MMSectionLabel(text: "Transcript", icon: "waveform")
                    ScrollView {
                        Text(state.transcript)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 120)
                    .mmTextArea()
                }
                MMSectionLabel(text: "Cleaned reply", icon: "sparkles")
                ScrollView {
                    Text(state.reply.isEmpty ? "…" : state.reply)
                        .font(.body)
                        .textSelection(.enabled)
                        .foregroundStyle(state.reply.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .mmTextArea()
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        HStack {
            switch state.phase {
            case .idle, .recording, .transcribing, .generating:
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            case .ready:
                Button("Re-record", action: state.onRerecord)
                    .buttonStyle(MMGhostButtonStyle())
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Use this", action: state.onUse)
                    .buttonStyle(MMPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .error:
                Button("Re-record", action: state.onRerecord)
                    .buttonStyle(MMGhostButtonStyle())
                Spacer()
                Button("Cancel", action: state.onCancel)
                    .buttonStyle(MMGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func timerString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(isRecording
                          ? LinearGradient(colors: [.red, .pink], startPoint: .top, endPoint: .bottom)
                          : LinearGradient.mmBrand)
                    .frame(width: 108, height: 108)
                    .shadow(color: (isRecording ? Color.red : MMColor.indigo).opacity(0.45),
                            radius: 24, y: 6)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient.mmBrand)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}
