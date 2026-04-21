import AppKit
import Combine
import EventKit
import Foundation
import SwiftUI

struct ExtractedTask {
    var title: String
    var notes: String
    var dueDate: Date?
    var listName: String?
}

@MainActor
final class TaskCaptureState: ObservableObject {
    enum Phase {
        case idle
        case recording
        case transcribing
        case extracting
        case ready
        case saving
        case saved(reminderID: String)
        case error(String)
    }
    @Published var phase: Phase = .idle
    @Published var transcript: String = ""
    @Published var task: ExtractedTask = .init(title: "", notes: "", dueDate: nil)
    @Published var availableLists: [String] = []
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onSave: () -> Void = {}
    var onRerecord: () -> Void = {}
    var onCancel: () -> Void = {}
}

@MainActor
final class TaskCapturePanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let state = TaskCaptureState()

    func show() {
        self.window?.close()
        self.window = nil

        let view = TaskCapturePanelView(state: state)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = NSLocalizedString("MailMate — Dictate a task", comment: "")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 600, height: 560))
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

@MainActor
final class TaskCapture {
    private let eventStore = EKEventStore()
    private var panel: TaskCapturePanel?
    private var recorder: AudioRecorder?
    private var observers: Set<AnyCancellable> = []
    private var cleanupDone = false
    private var client: ReplyProvider?
    private var notifier: ((String) -> Void) = { _ in }

    static func ensureRemindersPermission() async -> Bool {
        let store = EKEventStore()
        if #available(macOS 14, *) {
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                Log.write("Reminders permission error: \(error.localizedDescription)")
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { granted, _ in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    func start(client: ReplyProvider, notifier: @escaping (String) -> Void) async {
        self.client = client
        self.notifier = notifier
        cleanupDone = false

        let panel = TaskCapturePanel()
        self.panel = panel

        let rec = AudioRecorder()
        self.recorder = rec
        observers.removeAll()
        rec.$level.sink { [weak panel] v in panel?.state.level = v }.store(in: &observers)
        rec.$elapsed.sink { [weak panel] v in panel?.state.elapsed = v }.store(in: &observers)

        panel.state.availableLists = eventStore.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .map { $0.title }
        panel.state.task.listName = panel.state.availableLists.first

        panel.state.onStart = { [weak self] in self?.beginRecording() }
        panel.state.onStop = { [weak self] in
            Task { @MainActor in await self?.stopAndProcess() }
        }
        panel.state.onRerecord = { [weak self] in self?.rerecord() }
        panel.state.onSave = { [weak self] in
            Task { @MainActor in await self?.saveTask() }
        }
        panel.state.onCancel = { [weak self] in self?.cleanup(closeWindow: true) }

        panel.show()
    }

    private func beginRecording() {
        guard let rec = recorder, let state = panel?.state else { return }
        do {
            try rec.start()
            state.phase = .recording
        } catch {
            state.phase = .error(error.localizedDescription)
        }
    }

    private func stopAndProcess() async {
        guard let rec = recorder, let panel, let client else { return }
        let state = panel.state
        guard case .recording = state.phase else { return }
        guard let url = rec.stop() else {
            state.phase = .error("No recording captured.")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        state.phase = .transcribing
        let whisper: WhisperClient
        do { whisper = try WhisperClient.make() }
        catch { state.phase = .error(error.localizedDescription); return }

        let transcript: String
        do { transcript = try await whisper.transcribe(audioURL: url) }
        catch {
            Log.write("Whisper error: \(error.localizedDescription)")
            state.phase = .error(error.localizedDescription)
            return
        }
        state.transcript = transcript

        if transcript.isEmpty {
            state.phase = .error("No speech detected.")
            return
        }

        state.phase = .extracting
        let extracted: ExtractedTask
        do {
            extracted = try await Self.extractTask(from: transcript, using: client)
        } catch {
            Log.write("Task extraction error: \(error.localizedDescription)")
            state.phase = .error(error.localizedDescription)
            return
        }

        var merged = extracted
        if merged.listName == nil { merged.listName = state.task.listName }
        state.task = merged
        state.phase = .ready
    }

    private func rerecord() {
        guard let panel else { return }
        panel.state.transcript = ""
        panel.state.task = .init(title: "", notes: "", dueDate: nil,
                                  listName: panel.state.task.listName)
        panel.state.phase = .idle
        recorder?.cancel()
        let fresh = AudioRecorder()
        recorder = fresh
        observers.removeAll()
        fresh.$level.sink { [weak panel] v in panel?.state.level = v }.store(in: &observers)
        fresh.$elapsed.sink { [weak panel] v in panel?.state.elapsed = v }.store(in: &observers)
    }

    private func saveTask() async {
        guard let panel else { return }
        let state = panel.state
        state.phase = .saving

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = state.task.title.isEmpty ? "Untitled task" : state.task.title
        if !state.task.notes.isEmpty { reminder.notes = state.task.notes }
        if let due = state.task.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        if let listName = state.task.listName,
           let list = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) {
            reminder.calendar = list
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        do {
            try eventStore.save(reminder, commit: true)
            Log.write("Reminder saved: \(reminder.title ?? "") in \(reminder.calendar.title)")
            state.phase = .saved(reminderID: reminder.calendarItemIdentifier)
            notifier("Task saved to Reminders.")
            try? await Task.sleep(nanoseconds: 800_000_000)
            cleanup(closeWindow: true)
        } catch {
            Log.write("Reminder save error: \(error.localizedDescription)")
            state.phase = .error(error.localizedDescription)
        }
    }

    private func cleanup(closeWindow: Bool) {
        if cleanupDone { return }
        cleanupDone = true
        recorder?.cancel()
        recorder = nil
        observers.removeAll()
        if closeWindow { panel?.close() }
        panel = nil
        client = nil
    }

    // MARK: - Prompt the model to extract structured task fields

    private static func extractTask(from transcript: String, using client: ReplyProvider) async throws -> ExtractedTask {
        let system = """
        Extract a single task from the user's colloquial dictation. Respond with ONE valid JSON object, no code fence, no commentary. Schema:
        {
          "title": "short, imperative (e.g. 'Call Jan about proposal')",
          "notes": "additional context from the dictation; empty string if none",
          "due": "ISO 8601 datetime if the user mentioned a specific day/time (e.g. 2026-04-25T09:00:00); empty string if none"
        }

        Use the current date when resolving relative references like "tomorrow" or "Friday". If ambiguous, leave "due" empty.

        Current date/time: \(ISO8601DateFormatter().string(from: Date()))
        """
        let user = transcript
        let raw = try await client.oneShot(system: system, user: user)
        return try parseExtracted(raw)
    }

    static func parseExtracted(_ raw: String) throws -> ExtractedTask {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json fences if the model added them despite the instruction.
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fall back to using the whole transcript as the title.
            return ExtractedTask(title: raw, notes: "", dueDate: nil)
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notes = (obj["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dueString = (obj["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let due: Date? = {
            guard !dueString.isEmpty else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: dueString) { return d }
            // Try without seconds.
            f.formatOptions = [.withFullDate, .withFullTime, .withTimeZone, .withColonSeparatorInTime]
            if let d = f.date(from: dueString) { return d }
            // Try date-only.
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            return day.date(from: dueString)
        }()
        return ExtractedTask(title: title.isEmpty ? "Untitled task" : title,
                             notes: notes,
                             dueDate: due)
    }
}

// MARK: - View

private struct TaskCapturePanelView: View {
    @ObservedObject var state: TaskCaptureState

    var body: some View {
        VStack(alignment: .leading, spacing: MMSpace.md) {
            HStack(spacing: 12) {
                MMBrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictate a task").font(MMFont.title)
                    header
                }
                Spacer()
            }

            Group {
                switch state.phase {
                case .idle, .recording:
                    VStack {
                        Spacer()
                        HStack { Spacer(); recordButton; Spacer() }
                        Spacer()
                    }
                case .transcribing, .extracting:
                    VStack(alignment: .leading, spacing: MMSpace.sm) {
                        if !state.transcript.isEmpty {
                            MMSectionLabel(text: "Transcript", icon: "waveform")
                            Text(state.transcript)
                                .font(.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .mmTextArea()
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                case .ready, .saving, .saved, .error:
                    TaskFormView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .padding(MMSpace.lg)
        .frame(minWidth: 560, minHeight: 480)
        .mmPanelBackground()
    }

    @ViewBuilder
    private var header: some View {
        switch state.phase {
        case .idle:
            Text("Press record and say what you want to do.")
                .font(MMFont.caption).foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(String(format: "%02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(LinearGradient.mmBrand)
                            .frame(width: geo.size.width * CGFloat(state.level))
                    }
                }
                .frame(width: 140, height: 8)
            }
        case .transcribing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Transcribing…").font(MMFont.caption).foregroundStyle(.secondary) }
        case .extracting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Extracting task…").font(MMFont.caption).foregroundStyle(.secondary) }
        case .ready:
            Text("Review the task, then Save.").font(MMFont.caption).foregroundStyle(.secondary)
        case .saving:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…").font(MMFont.caption).foregroundStyle(.secondary) }
        case .saved:
            Text("Saved.").font(MMFont.caption).foregroundStyle(.green)
        case .error(let msg):
            Text(msg).font(MMFont.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch state.phase {
            case .idle, .recording, .transcribing, .extracting, .saving, .saved:
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
                Button("Save to Reminders", action: state.onSave)
                    .buttonStyle(MMPrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
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

    private var recordButton: some View {
        let isRecording = {
            if case .recording = state.phase { return true } else { return false }
        }()
        return Button(action: { isRecording ? state.onStop() : state.onStart() }) {
            ZStack {
                Circle()
                    .fill(isRecording
                          ? LinearGradient(colors: [.red, .pink], startPoint: .top, endPoint: .bottom)
                          : LinearGradient.mmBrand)
                    .frame(width: 104, height: 104)
                    .shadow(color: (isRecording ? Color.red : MMColor.indigo).opacity(0.4),
                            radius: 22, y: 6)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TaskFormView: View {
    @ObservedObject var state: TaskCaptureState
    @State private var hasDue: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MMSectionLabel(text: "Task", icon: "checkmark.circle")

            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $state.task.title)
                    .textFieldStyle(.roundedBorder)

                TextField("Notes (optional)", text: $state.task.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                Toggle("Has due date", isOn: $hasDue)
                    .onChange(of: hasDue) { _, new in
                        if new, state.task.dueDate == nil {
                            state.task.dueDate = Date().addingTimeInterval(86_400)
                        } else if !new {
                            state.task.dueDate = nil
                        }
                    }
                    .onAppear { hasDue = state.task.dueDate != nil }

                if hasDue {
                    DatePicker("Due",
                               selection: Binding(get: { state.task.dueDate ?? Date() },
                                                  set: { state.task.dueDate = $0 }),
                               displayedComponents: [.date, .hourAndMinute])
                }

                if !state.availableLists.isEmpty {
                    Picker("List", selection: Binding(get: { state.task.listName ?? "" },
                                                      set: { state.task.listName = $0.isEmpty ? nil : $0 })) {
                        ForEach(state.availableLists, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            }
            .mmCard()
        }
    }
}
