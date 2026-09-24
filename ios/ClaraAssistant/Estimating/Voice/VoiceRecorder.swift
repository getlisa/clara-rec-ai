import AVFoundation
import Observation

/// Records a short voice note for transcription.
///
/// Deliberately separate from `MicrophoneCapture`, which serves glasses recording and owns a
/// long-lived `.playAndRecord` session. This one takes the session only while recording and hands
/// it back, so dictating into the estimate chat cannot disturb a recording in progress.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        case denied
        case recording
    }

    private(set) var state: State = .idle
    private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var fileURL: URL?

    var isRecording: Bool { state == .recording }

    /// AAC in an m4a container — what iOS records natively, and a mime type the transcriber takes
    /// as-is. No re-encoding on the client.
    private static let mimeType = "audio/m4a"

    func start() async {
        guard state != .recording else { return }

        guard await requestPermission() else {
            state = .denied
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("estimate-note-\(UUID().uuidString).m4a")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)

            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
            recorder.isMeteringEnabled = true
            recorder.record()

            self.recorder = recorder
            self.fileURL = url
            state = .recording
            startMetering()
            Diag.log("voice", "recording started")
        } catch {
            Diag.log("voice", "could not start: \(error.localizedDescription)")
            state = .idle
        }
    }

    /// Stops and returns the recording, ready to send. Nil when nothing usable was captured.
    func stop() -> (data: Data, mimeType: String)? {
        defer {
            levelTimer?.invalidate()
            levelTimer = nil
            recorder = nil
            state = .idle
            level = 0
            // Hand the session back so glasses recording is unaffected.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        guard let recorder, let url = fileURL else { return nil }
        recorder.stop()

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            Diag.log("voice", "stopped with no audio")
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        Diag.log("voice", "recorded \(data.count) bytes")
        return (data, Self.mimeType)
    }

    func cancel() {
        recorder?.stop()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        levelTimer?.invalidate()
        levelTimer = nil
        recorder = nil
        state = .idle
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // -60 dB reads as silence, 0 dB as full scale.
                let power = recorder.averagePower(forChannel: 0)
                self.level = max(0, min(1, (power + 60) / 60))
            }
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
