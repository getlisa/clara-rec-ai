import AVFoundation
import os

/// Captures microphone audio for recording.
///
/// The Meta SDK exposes no audio stream, so glasses audio is reached the same way any
/// Bluetooth headset is: the session allows the Hands-Free Profile, and iOS routes input to
/// the glasses when they are connected. Capture follows whatever the current route is, so
/// it falls back to the phone mic when the glasses are absent.
final class MicrophoneCapture {

    /// Whether audio is currently coming from the glasses rather than the phone.
    private(set) var isUsingBluetoothInput = false

    /// Format audio is actually captured in. HFP negotiates 8/16 kHz, so this must be used
    /// to declare the recording's audio track rather than assuming a rate.
    private(set) var captureFormat: AVAudioFormat?

    // Built on demand: an AVAudioEngine per instance is expensive, and the recorder is
    // constructed long before anything is recorded.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var isRunning = false
    private var routeObserver: NSObjectProtocol?

    private static let logger = Logger(subsystem: "ai.justclara.ClaraAssistant", category: "Microphone")

    /// Calls [onBuffer] on an audio thread for every captured buffer.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        // .allowBluetoothHFP is what makes the glasses microphone reachable at all.
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.allowBluetoothHFP, .mixWithOthers]
        )
        try session.setActive(true)

        updateRouteFlag()
        observeRouteChanges()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Tap in the hardware's own format: HFP negotiates a low sample rate (8/16 kHz)
        // and forcing a different format here fails at runtime.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicrophoneCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Input format unavailable"])
        }

        // The tap delivers non-interleaved Float32, which the AAC encoder refuses
        // ("cannot encode media"). Convert to interleaved Int16 mono, which it accepts,
        // keeping the hardware sample rate so nothing is resampled.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw NSError(domain: "MicrophoneCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build audio converter"])
        }
        self.converter = converter
        captureFormat = targetFormat

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: buffer.frameLength
            ) else { return }
            do {
                try converter.convert(to: converted, from: buffer)
                onBuffer(converted)
            } catch {
                Self.logger.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        Self.logger.info(
            "Microphone started: \(format.sampleRate, privacy: .public) Hz, bluetooth=\(self.isUsingBluetoothInput, privacy: .public)"
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil

        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeRouteChanges() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.updateRouteFlag()
        }
    }

    private func updateRouteFlag() {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        isUsingBluetoothInput = inputs.contains { $0.portType == .bluetoothHFP }
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
