import AVFoundation
import Foundation

enum AudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case recorderSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Enable in System Settings → Privacy & Security → Microphone."
        case .recorderSetupFailed(let msg):
            return "Recorder setup failed: \(msg)"
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    private enum Phase { case idle, recording, finished }

    /// Normalized audio level in 0...1 (from dBFS peak power).
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var startDate: Date?
    private(set) var outputURL: URL?
    private var phase: Phase = .idle

    /// Requests microphone permission if not already granted.
    /// Returns true if permission is (or was already) granted.
    static func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() throws {
        guard phase == .idle else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailmate-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: tmp, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.prepareToRecord(), rec.record() else {
                throw AudioRecorderError.recorderSetupFailed("record() returned false")
            }
            recorder = rec
            outputURL = tmp
            startDate = Date()
            isRecording = true
            phase = .recording
            Log.write("Recording started at \(tmp.path)")

            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                // Timer added to RunLoop.main, so this fires on main — safe to
                // assume MainActor isolation and call the isolated tick() directly.
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } catch let err as AudioRecorderError {
            throw err
        } catch {
            throw AudioRecorderError.recorderSetupFailed(error.localizedDescription)
        }
    }

    /// Stops recording and returns the URL of the written audio file. No-op if
    /// already stopped or cancelled.
    @discardableResult
    func stop() -> URL? {
        guard phase == .recording else { return outputURL }
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        phase = .finished
        let url = outputURL
        Log.write("Recording stopped: \(url?.path ?? "<none>") duration=\(elapsed)s")
        return url
    }

    /// Cancel and delete the recording. Idempotent.
    func cancel() {
        guard phase != .finished || outputURL != nil else { return }
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        recorder = nil
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        outputURL = nil
        level = 0
        elapsed = 0
        phase = .finished
        Log.write("Recording cancelled")
    }

    private func tick() {
        guard let rec = recorder else { return }
        rec.updateMeters()
        let dB = rec.averagePower(forChannel: 0)
        let clamped = max(-60, min(0, dB))
        level = (clamped + 60) / 60
        if let start = startDate {
            elapsed = Date().timeIntervalSince(start)
        }
    }
}
