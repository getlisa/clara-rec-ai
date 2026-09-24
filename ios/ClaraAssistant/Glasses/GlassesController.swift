import AVFoundation
import CoreMedia
import MWDATCamera
import MWDATCore
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class GlassesController {

    enum RecordingState: Equatable {
        case idle
        case recording(startedAt: Date)
    }

    /// A known device plus the two properties that decide whether a session can open on it.
    struct DeviceInfo: Identifiable {
        let id: UUID
        let name: String
        let linkState: LinkState
        let compatibility: Compatibility

        var isEligible: Bool {
            linkState == .connected && compatibility == .compatible
        }

        var summary: String {
            let link: String
            switch linkState {
            case .connected: link = "connected"
            case .connecting: link = "connecting"
            case .disconnected: link = "disconnected"
            }
            return "\(link) · \(compatibility.displayString)"
        }
    }

    private(set) var registrationState: RegistrationState = .unavailable
    private(set) var devices: [DeviceIdentifier] = []
    private(set) var deviceInfos: [DeviceInfo] = []
    private(set) var sessionState: DeviceSessionState = .stopped
    private(set) var streamState: StreamState = .stopped
    private(set) var framesPerSecond: Double = 0
    /// Frames actually drawn. Diverging from framesPerSecond means the picture is frozen
    /// while frames still arrive — a rendering fault, not a Bluetooth one.
    private(set) var renderedPerSecond: Double = 0
    private(set) var recordingState: RecordingState = .idle
    private(set) var audioFromGlasses = false
    private(set) var statusMessage: String?
    private(set) var activeDevice: DeviceIdentifier?
    /// Glasses camera permission, granted through the Meta AI app — the iOS equivalent of the
    /// Android build's Wearables permission request.
    private(set) var cameraPermission: PermissionStatus?

    private let wearables = Wearables.shared
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []
    private var deviceTokens: [any AnyListenerToken] = []

    /// Held for the app's lifetime. A freshly constructed selector reports activeDevice == nil
    /// until it resolves asynchronously, so building one per use always looks like
    /// "no eligible device".
    private var autoSelector: AutoDeviceSelector?
    private var activeDeviceTask: Task<Void, Never>?

    private let recorder = RecordingWriter()
    private let microphone = MicrophoneCapture()

    /// Still photos captured from the live stream, and their upload to S3.
    let imageUploader = ImageUploader()

    /// Where a `captureStill()` has got to, for callers that show progress. Waking the glasses
    /// and reaching `.streaming` over Bluetooth takes seconds, so this is not a formality.
    enum CaptureStatus: Equatable {
        case idle
        /// Opening a session because nothing was streaming — the slow case.
        case preparing
        case capturing
    }

    private(set) var captureStatus: CaptureStatus = .idle

    /// A photo the glasses sent that this app never requested. Stays nil unless the hardware
    /// capture button turns out to reach us — shown in the live view so the answer is visible
    /// without a debug console.
    private(set) var unsolicitedPhoto: UIImage?

    func clearUnsolicitedPhoto() { unsolicitedPhoto = nil }

    /// Resolved by `handle(photo:)` when the JPEG arrives.
    private var pendingCapture: CheckedContinuation<Data?, Never>?
    private var captureTimeout: Task<Void, Never>?
    /// True when `captureStill()` opened the session itself and must close it again. Never set
    /// when the Live view owns the stream — tearing that down would kill someone's preview.
    private var ownsTransientSession = false

    /// Compressed frames are handed straight to this layer, which decodes and draws them on
    /// the hardware path. Decoding to UIImage per frame and re-rendering a SwiftUI Image is
    /// far more expensive and cannot keep up at 24fps.
    let previewLayer = AVSampleBufferDisplayLayer()

    private let frameRateMeter = FrameRateMeter()
    private let previewNeedsKeyframe = AtomicFlag(true)
    private let notReadyStreak = AtomicCounter()

    /// ~1s at 24fps. Below this, back-pressure is normal and self-corrects.
    private static let notReadyLimit = 24

    private static let logger = Logger(subsystem: "ai.justclara.ClaraAssistant", category: "Glasses")

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    /// Shared instance: SwiftUI re-evaluates `@State` initializers on every view
    /// re-creation, so constructing a controller there would spawn one per render.
    static let shared = GlassesController()

    private var hasStarted = false

    private init() {}

    /// Registering SDK listeners is deliberately not done in init: listener callbacks mutate
    /// observed state, which re-renders the view, which would build another controller.
    func startObserving() {
        guard !hasStarted else { return }
        hasStarted = true

        registrationState = wearables.registrationState
        devices = wearables.devices
        observeWearables()

        let selector = AutoDeviceSelector(wearables: wearables)
        autoSelector = selector
        activeDeviceTask = Task { [weak self] in
            for await identifier in selector.activeDeviceStream() {
                await MainActor.run {
                    self?.activeDevice = identifier
                    Self.logger.info(
                        "DIAG activeDevice -> \(String(describing: identifier), privacy: .public)"
                    )
                }
            }
        }

        Task { await refreshCameraPermission() }
    }

    // MARK: - Glasses camera permission

    func refreshCameraPermission() async {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            cameraPermission = status
            Self.logger.info("DIAG cameraPermission=\(String(describing: status), privacy: .public)")
        } catch let error as PermissionError {
            Self.logger.error("DIAG cameraPermission check failed: \(error.description, privacy: .public)")
            statusMessage = "Camera permission check failed: \(error.description)"
        } catch {
            Self.logger.error("DIAG cameraPermission check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the Meta AI app so the user can grant the glasses camera to this app.
    func requestCameraPermission() async {
        do {
            let status = try await wearables.requestPermission(.camera)
            cameraPermission = status
            Self.logger.info("DIAG cameraPermission requested -> \(String(describing: status), privacy: .public)")
        } catch let error as PermissionError {
            Self.logger.error("DIAG cameraPermission request failed: \(error.description, privacy: .public)")
            statusMessage = "Camera permission request failed: \(error.description)"
        } catch {
            statusMessage = "Camera permission request failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Registration

    func register() async {
        do {
            try await wearables.startRegistration()
        } catch {
            statusMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    func unregister() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            statusMessage = "Unregistration failed: \(error.localizedDescription)"
        }
    }

    private func observeWearables() {
        tokens.append(wearables.addRegistrationStateListener { [weak self] state in
            Task { @MainActor in self?.registrationState = state }
        })
        tokens.append(wearables.addDevicesListener { [weak self] devices in
            Task { @MainActor in
                self?.devices = devices
                self?.refreshDeviceInfos()
            }
        })
        refreshDeviceInfos()
    }

    /// Link state changes as the glasses wake, fold, or hand off between phones, so the
    /// list is rebuilt on every change rather than read once.
    func refreshDeviceInfos() {
        // Without clearing, every refresh stacks another listener per device and each
        // callback re-enters this method.
        deviceTokens.removeAll()

        var infos: [DeviceInfo] = []
        for identifier in devices {
            guard let device = wearables.deviceForIdentifier(identifier) else { continue }
            infos.append(
                DeviceInfo(
                    id: device.deviceUUID,
                    name: device.nameOrId(),
                    linkState: device.linkState,
                    compatibility: device.compatibility()
                )
            )
            deviceTokens.append(device.addLinkStateListener { [weak self] _ in
                Task { @MainActor in self?.rebuildInfosOnly() }
            })
        }
        deviceInfos = infos
        logDeviceDiagnostics()
    }

    private func rebuildInfosOnly() {
        deviceInfos = devices.compactMap { identifier in
            guard let device = wearables.deviceForIdentifier(identifier) else { return nil }
            return DeviceInfo(
                id: device.deviceUUID,
                name: device.nameOrId(),
                linkState: device.linkState,
                compatibility: device.compatibility()
            )
        }
    }

    // MARK: - Streaming

    func startStreaming(resolution: StreamingResolution = .medium, frameRate: UInt = 24) async {
        guard session == nil else { return }
        statusMessage = nil

        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            if status != .granted {
                let requested = try await wearables.requestPermission(.camera)
                guard requested == .granted else {
                    statusMessage = "Camera permission denied on the glasses"
                    return
                }
            }
        } catch let error as PermissionError {
            Self.logger.error("Permission error: \(error.description, privacy: .public)")
            statusMessage = "Permission check failed: \(error.description)"
            return
        } catch {
            statusMessage = "Permission check failed: \(error.localizedDescription)"
            return
        }

        logDeviceDiagnostics()

        // Prefer the device we already know is connected and compatible. The auto selector
        // resolves asynchronously, so using it immediately yields noEligibleDevice.
        let selector: any DeviceSelector
        if let identifier = eligibleDeviceIdentifier() {
            Self.logger.info("Using SpecificDeviceSelector for \(String(describing: identifier), privacy: .public)")
            selector = SpecificDeviceSelector(device: identifier)
        } else if let auto = autoSelector, await waitForActiveDevice(auto, timeout: 15) {
            Self.logger.info("Using AutoDeviceSelector, active=\(String(describing: auto.activeDevice), privacy: .public)")
            selector = auto
        } else {
            statusMessage = "Glasses are not ready yet. Make sure they are on and worn, then try again."
            return
        }

        do {
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session

            tokens.append(session.statePublisher.listen { [weak self] state in
                Diag.log("stream", "session → \(state.description)")
                Task { @MainActor in self?.sessionState = state }
            })

            try session.start()

            // addCamera throws .sessionIdle unless the session has actually reached
            // .started, which happens asynchronously after start() returns.
            guard await Self.waitForStarted(session, timeout: 20) else {
                statusMessage = "Glasses did not connect (session \(session.state.description))"
                stopStreaming()
                return
            }

            // hvc1 delivers compressed HEVC, which records as passthrough with no re-encode.
            let config = StreamConfiguration(
                videoCodec: .hvc1,
                resolution: resolution,
                frameRate: frameRate
            )
            guard let camera = try session.addCamera(config: config) else {
                statusMessage = "Could not add camera to session"
                stopStreaming()
                return
            }
            self.camera = camera

            let stream = camera.stream
            tokens.append(stream.statePublisher.listen { [weak self] state in
                Diag.log("stream", "state → \(String(describing: state))")
                Task { @MainActor in self?.streamState = state }
            })
            tokens.append(stream.errorPublisher.listen { [weak self] error in
                Diag.log("stream", "error → \(error.description)")
                Task { @MainActor in self?.statusMessage = "Stream error: \(error.description)" }
            })
            tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                self?.handle(frame: frame)
            })
            // capturePhoto() only asks; the image itself arrives here, asynchronously.
            tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor in self?.handle(photo: photo) }
            })

            stream.start()
        } catch let error as DeviceSessionError {
            // .description carries the specific case; localizedDescription is generic.
            Self.logger.error("Session error: \(error.description, privacy: .public)")
            statusMessage = "Failed to start stream: \(error.description)"
            stopStreaming()
        } catch {
            Self.logger.error("Stream start failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to start stream: \(error.localizedDescription)"
            stopStreaming()
        }
    }

    /// Identifier of a device that is connected and compatible, if any.
    private func eligibleDeviceIdentifier() -> DeviceIdentifier? {
        devices.first { identifier in
            guard let device = wearables.deviceForIdentifier(identifier) else { return false }
            return device.linkState == .connected && device.compatibility() == .compatible
        }
    }

    private func waitForActiveDevice(_ selector: AutoDeviceSelector, timeout: TimeInterval) async -> Bool {
        if selector.activeDevice != nil { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await identifier in selector.activeDeviceStream() where identifier != nil {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func logDeviceDiagnostics() {
        Self.logger.info(
            """
            DIAG registration=\(String(describing: self.registrationState), privacy: .public) \
            deviceCount=\(self.devices.count, privacy: .public) \
            activeDevice=\(String(describing: self.activeDevice), privacy: .public) \
            cameraPermission=\(String(describing: self.cameraPermission), privacy: .public)
            """
        )
        for identifier in devices {
            guard let device = wearables.deviceForIdentifier(identifier) else {
                Self.logger.error("DIAG device \(String(describing: identifier), privacy: .public) -> nil")
                continue
            }
            Self.logger.info(
                """
                DIAG device name=\(device.nameOrId(), privacy: .public) \
                link=\(String(describing: device.linkState), privacy: .public) \
                compat=\(device.compatibility().displayString, privacy: .public) \
                type=\(device.deviceType().rawValue, privacy: .public) \
                display=\(device.supportsDisplay(), privacy: .public)
                """
            )
        }
    }

    /// The session reaches .started asynchronously; adding a capability before then fails.
    private static func waitForStarted(_ session: DeviceSession, timeout: TimeInterval) async -> Bool {
        if session.state == .started { return true }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in session.stateStream() {
                    Self.logger.info("Session state: \(state.description, privacy: .public)")
                    if state == .started { return true }
                    if state == .stopped { return false }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: - Photo capture

    /// Asks the glasses for a still off the running stream. The JPEG arrives later, via the
    /// photo listener installed in `startStreaming`.
    func capturePhoto() {
        guard let camera else {
            statusMessage = "Start the stream before taking a photo"
            return
        }
        guard camera.stream.capturePhoto(format: .jpeg) else {
            statusMessage = "The glasses refused the photo request"
            return
        }
        statusMessage = "Capturing photo…"
    }

    private func handle(photo: PhotoData) {
        guard photo.format == .jpeg else {
            // Only .jpeg is ever requested; HEIC would need transcoding before upload.
            statusMessage = "Unexpected photo format from the glasses"
            resumeCapture(nil)
            return
        }
        // A `captureStill()` caller is waiting for these bytes; the live view's shutter is not,
        // and still goes to the S3 uploader.
        if pendingCapture != nil {
            statusMessage = nil
            resumeCapture(photo.data)
            return
        }

        // Nobody asked for this one. The only way that can happen is the glasses producing a
        // photo on their own — which is the open question about the hardware capture button.
        // Announced loudly and on screen: routed silently to the uploader it would be invisible
        // whenever S3 is unconfigured, making a working button look exactly like a dead one.
        Diag.log("stream", "UNSOLICITED photo from the glasses (\(photo.data.count) bytes)")
        statusMessage = "📸 Unsolicited photo from glasses — \(photo.data.count / 1024) KB"
        unsolicitedPhoto = UIImage(data: photo.data)

        imageUploader.uploadIfNeeded(jpeg: photo.data)
    }

    /// Captures a still from anywhere in the app, opening a short-lived camera session when
    /// nothing is streaming.
    ///
    /// The Live view owns the long-lived session and tears it down in `onDisappear`, so from any
    /// other tab `camera` is nil and `capturePhoto()` has nothing to ask. The Android build hit
    /// the same wall and answered it with prepare-then-capture; this is that, as one call.
    ///
    /// Returns the JPEG exactly as the glasses produced it — no decode, no re-encode. Callers that
    /// are going to upload it should run it through `JPEGOrientation.normalized(_:)` first.
    func captureStill(timeout: TimeInterval = 8) async -> Data? {
        // One at a time: a second request would strand the first continuation.
        guard pendingCapture == nil, captureStatus == .idle else { return nil }

        if camera == nil {
            Diag.log("capture", "no live stream — opening a short-lived session")
            captureStatus = .preparing
            await startStreaming(resolution: AppSettings.videoQuality.resolution)
            guard camera != nil else {
                Diag.log("capture", "session did not open: \(statusMessage ?? "no reason given")")
                captureStatus = .idle
                return nil
            }
            ownsTransientSession = true
        } else {
            Diag.log("capture", "reusing the live view's stream")
        }

        guard await waitForStreaming(timeout: timeout) else {
            statusMessage = "The glasses camera did not start in time"
            finishCapture()
            return nil
        }

        captureStatus = .capturing
        let jpeg = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            pendingCapture = continuation

            // The SDK can accept the request and then never deliver — without this the caller
            // would await forever and the shutter would stay stuck.
            captureTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.statusMessage = "The glasses did not return a photo"
                self?.resumeCapture(nil)
            }

            if camera?.stream.capturePhoto(format: .jpeg) != true {
                statusMessage = "The glasses refused the photo request"
                resumeCapture(nil)
            }
        }

        Diag.log("capture", jpeg.map { "got \($0.count) bytes of JPEG" } ?? "no photo returned")
        finishCapture()
        return jpeg
    }

    private func resumeCapture(_ data: Data?) {
        guard let continuation = pendingCapture else { return }
        pendingCapture = nil
        captureTimeout?.cancel()
        captureTimeout = nil
        continuation.resume(returning: data)
    }

    /// Closes only what `captureStill()` opened.
    private func finishCapture() {
        captureStatus = .idle
        guard ownsTransientSession else { return }
        ownsTransientSession = false
        stopStreaming()
    }

    /// The stream reaches `.streaming` asynchronously after `start()`; capturing before it does
    /// is refused.
    private func waitForStreaming(timeout: TimeInterval) async -> Bool {
        guard let camera else { return false }
        if camera.stream.state == .streaming { return true }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if camera.stream.state == .streaming { return true }
        }
        return camera.stream.state == .streaming
    }

    func stopStreaming() {
        if isRecording {
            Task { await stopRecording() }
        }
        camera?.stop()
        camera = nil
        session?.stop()
        session = nil
        tokens.removeAll()
        observeWearables()
        streamState = .stopped
        framesPerSecond = 0
        renderedPerSecond = 0
    }

    /// Runs on the SDK's delivery thread. Recording and decoding happen here rather than on
    /// the main actor: hopping every frame through `Task { @MainActor }` gives no ordering
    /// guarantee between tasks, so frames could reach the writer out of order, and it stops
    /// writing entirely once the app is backgrounded.
    private nonisolated func handle(frame: VideoFrame) {
        let sampleBuffer = frame.sampleBuffer

        recorder.appendVideo(sampleBuffer)
        let didRender = enqueueForPreview(sampleBuffer)

        if let rates = frameRateMeter.tick(rendered: didRender) {
            let renderer = previewLayer.sampleBufferRenderer
            Self.logger.info(
                """
                PREVIEW received=\(rates.received, privacy: .public) \
                rendered=\(rates.rendered, privacy: .public) \
                status=\(renderer.status.rawValue, privacy: .public) \
                ready=\(renderer.isReadyForMoreMediaData, privacy: .public) \
                needsFlush=\(renderer.requiresFlushToResumeDecoding, privacy: .public) \
                needsKeyframe=\(self.previewNeedsKeyframe.value, privacy: .public) \
                error=\(renderer.error?.localizedDescription ?? "none", privacy: .public)
                """
            )
            Task { @MainActor [weak self] in
                self?.framesPerSecond = rates.received
                self?.renderedPerSecond = rates.rendered
            }
        }
    }

    /// Enqueues a copy for display, returning whether the frame actually reached the renderer.
    /// The copy exists so setting the "display immediately" attachment cannot disturb the
    /// buffer already handed to the recorder.
    @discardableResult
    private nonisolated func enqueueForPreview(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let renderer = previewLayer.sampleBufferRenderer

        // The renderer fails — and stays failed — when the system takes decoder resources
        // away, e.g. on backgrounding. Only a flush clears it; without this the picture
        // freezes on the last frame indefinitely.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            Self.logger.error(
                """
                Preview renderer stalled (status=\(renderer.status.rawValue, privacy: .public) \
                needsFlush=\(renderer.requiresFlushToResumeDecoding, privacy: .public)): \
                \(renderer.error?.localizedDescription ?? "none", privacy: .public) — flushing
                """
            )
            renderer.flush()
            previewNeedsKeyframe.set(true)
            notReadyStreak.reset()
        }

        // A decoder cannot start mid-GOP: the first buffer it sees must be a keyframe, or
        // it discards everything until one arrives and the screen stays black.
        if previewNeedsKeyframe.value {
            guard RecordingWriter.isKeyframe(sampleBuffer) else { return false }
            previewNeedsKeyframe.set(false)
            Self.logger.info("Preview resynced at keyframe")
        }

        guard renderer.isReadyForMoreMediaData else {
            // Back-pressure is normal for a frame or two. A sustained streak means the queue
            // is wedged, and silently dropping forever would look identical to a freeze.
            if notReadyStreak.increment() >= Self.notReadyLimit {
                Self.logger.error("Preview not ready for \(Self.notReadyLimit, privacy: .public) frames — flushing")
                renderer.flush()
                previewNeedsKeyframe.set(true)
                notReadyStreak.reset()
            }
            return false
        }
        notReadyStreak.reset()

        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        ) == noErr, let copy else { return false }

        // Stream timestamps are not on the layer's timebase, so ask it to draw on arrival.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        renderer.enqueue(copy)
        return true
    }

    // MARK: - Recording

    func startRecording() async {
        guard !isRecording else { return }

        let granted = await MicrophoneCapture.requestPermission()
        if !granted {
            statusMessage = "Microphone denied — recording video only"
        }

        if granted {
            // Started before arming so audio is already flowing when the first keyframe
            // opens the file; buffers arriving before then are simply dropped.
            do {
                try microphone.start { [weak self] buffer in
                    self?.recorder.appendAudio(buffer)
                }
                audioFromGlasses = microphone.isUsingBluetoothInput
            } catch {
                Self.logger.error("Microphone failed: \(error.localizedDescription, privacy: .public)")
                statusMessage = "Microphone unavailable — recording video only"
            }
        }

        recorder.prepareToStart(audioFormat: microphone.captureFormat)
        recordingState = .recording(startedAt: Date())
    }

    func stopRecording() async {
        guard isRecording else { return }

        recorder.prepareToStop()
        microphone.stop()
        recordingState = .idle
        audioFromGlasses = false

        let result = await recorder.stop()
        switch result {
        case .completed(let url):
            do {
                try await PhotoLibrarySaver.save(videoAt: url)
                statusMessage = "Saved to Photos"
            } catch {
                statusMessage = "Recorded, but saving failed: \(error.localizedDescription)"
            }
        case .nothingRecorded:
            statusMessage = "Nothing was recorded"
        case .failed(let reason):
            statusMessage = "Recording failed: \(reason)"
        }
    }

}

/// Small lock-guarded flag shared between the frame-delivery thread and the main actor.
final class AtomicFlag {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        storage = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Bool) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}

/// Lock-guarded counter shared with the frame-delivery thread.
final class AtomicCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

/// Measures the delivered frame rate. Called from the frame-delivery thread; returns a value
/// about once a second rather than on every frame, so the UI is not updated 24 times a second.
final class FrameRateMeter {
    private let lock = NSLock()
    private var windowStart = Date()
    private var count = 0
    private var renderedCount = 0

    func tick(rendered didRender: Bool) -> (received: Double, rendered: Double)? {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if didRender { renderedCount += 1 }
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1.0 else { return nil }
        let rates = (Double(count) / elapsed, Double(renderedCount) / elapsed)
        count = 0
        renderedCount = 0
        windowStart = Date()
        return rates
    }
}
