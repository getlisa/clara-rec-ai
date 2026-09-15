import AVFoundation
import CoreMedia
import os

/// Writes the glasses camera stream to a QuickTime file.
///
/// Video is written as passthrough: the glasses deliver HEVC sample buffers, so the video
/// input is created with no output settings and the compressed samples are muxed as-is.
/// Nothing is decoded or re-encoded.
final class RecordingWriter {

    enum StopResult {
        case completed(URL)
        case nothingRecorded
        case failed(String)
    }

    private struct State {
        var writer: AVAssetWriter
        var videoInput: AVAssetWriterInput
        var audioInput: AVAssetWriterInput?
        var outputURL: URL
        /// Source timestamp of the first written frame; everything is rebased against it
        /// so the file's timeline starts at zero.
        var firstVideoPTS: CMTime?
        var lastVideoPTS: CMTime?
        var lastVideoDTS: CMTime?
        var audioFramesWritten: Int64 = 0
        var finished = false
        var startedAt: Date
    }

    private let lock = NSLock()
    private var state: State?
    private var shouldAcceptNewFrames = false
    /// Capture format of the microphone, or nil to record video only. The AAC track must be
    /// declared at the rate audio actually arrives at.
    private var audioFormat: AVAudioFormat?
    private var audioDisabled = false

    /// Arms recording. The file is not opened until the first keyframe arrives, so the
    /// video track starts on a decodable frame.
    func prepareToStart(audioFormat: AVAudioFormat?) {
        lock.lock()
        self.shouldAcceptNewFrames = true
        self.audioFormat = audioFormat
        self.audioDisabled = false
        lock.unlock()
    }

    func prepareToStop() {
        lock.lock()
        shouldAcceptNewFrames = false
        lock.unlock()
    }

    var startedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return state?.startedAt
    }

    private static let logger = Logger(subsystem: "ai.justclara.ClaraAssistant", category: "Recording")
    private static let fallbackFrameRate: CMTimeScale = 24

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != nil
    }

    /// Starts a recording using [formatDescription] from the first keyframe, which carries the
    /// HEVC parameter sets the passthrough video track needs. Caller holds no lock.
    private func start(formatDescription: CMFormatDescription, audioFormat: AVAudioFormat?) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clara_\(Int(Date().timeIntervalSince1970)).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // No output settings: samples are already compressed, so they pass straight through.
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "RecordingWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioFormat {
            // Declaring a rate the samples do not actually have plays the audio back at the
            // wrong speed — Bluetooth HFP captures at 8/16 kHz, not 44.1.
            //
            // No explicit bitrate: AAC's valid range scales with sample rate, and a fixed
            // value legal at 44.1 kHz (64 kbps) is rejected at 16 kHz as unsupported output
            // settings. Letting the encoder choose keeps the combination valid at any rate.
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: Int(audioFormat.channelCount),
                AVSampleRateKey: audioFormat.sampleRate,
            ]

            if audioFormat.channelCount == 1 {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
                settings[AVChannelLayoutKey] = Data(
                    bytes: &layout,
                    count: MemoryLayout<AudioChannelLayout>.size
                )
            }
            Self.logger.info(
                "Audio track: \(audioFormat.sampleRate, privacy: .public) Hz, \(audioFormat.channelCount, privacy: .public) ch"
            )
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                Self.logger.error("Cannot add audio input; recording video only")
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "RecordingWriter", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)

        lock.lock()
        state = State(
            writer: writer,
            videoInput: videoInput,
            audioInput: audioInput,
            outputURL: url,
            startedAt: Date()
        )
        lock.unlock()
    }

    /// Safe to call from the SDK's frame-delivery thread.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let notStarted = state == nil
        let armed = shouldAcceptNewFrames
        let wantsAudio = audioFormat
        lock.unlock()

        if notStarted {
            // Opening on a P-frame yields a clip that plays black until the next keyframe.
            guard armed, Self.isKeyframe(sampleBuffer),
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            do {
                try start(formatDescription: format, audioFormat: wantsAudio)
            } catch {
                Self.logger.error("Could not start writer: \(error.localizedDescription, privacy: .public)")
                lock.lock()
                shouldAcceptNewFrames = false
                lock.unlock()
                return
            }
        }

        lock.lock()
        defer { lock.unlock() }
        guard var current = state, !current.finished else { return }

        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sourceDTS = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        guard sourcePTS.isValid else { return }

        if current.firstVideoPTS == nil {
            current.firstVideoPTS = sourcePTS
        }
        guard let first = current.firstVideoPTS else { return }

        guard current.videoInput.isReadyForMoreMediaData, current.writer.status != .failed else {
            state = current
            return
        }

        // Frames carry no duration; without one the sample table is empty and the file is
        // not seekable.
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || duration <= .zero {
            duration = CMTime(value: 1, timescale: Self.fallbackFrameRate)
        }

        // Rebase onto the recording origin, then force strictly increasing timestamps —
        // a backwards DTS fails the writer outright.
        var dts = CMTimeSubtract(sourceDTS.isValid ? sourceDTS : sourcePTS, first)
        if let last = current.lastVideoDTS {
            let floor = CMTimeAdd(last, duration)
            if dts < floor { dts = floor }
        }
        if dts < .zero { dts = .zero }

        var pts = CMTimeSubtract(sourcePTS, first)
        if pts < dts { pts = dts }

        let isSync = Self.isKeyframe(sampleBuffer)

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        ) == noErr, let retimed else {
            state = current
            return
        }

        // The SDK omits sync-sample flags. Without them AVAssetWriter builds no keyframe
        // index, producing a file that plays in AVPlayer but shows a blank thumbnail in
        // Photos.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(retimed, createIfNecessary: true)
            as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_NotSync] = !isSync
            first[kCMSampleAttachmentKey_DependsOnOthers] = !isSync
        }

        if current.videoInput.append(retimed) {
            current.lastVideoDTS = dts
            current.lastVideoPTS = pts
        } else {
            Self.logger.error(
                "Video append failed: \(current.writer.error?.localizedDescription ?? "unknown", privacy: .public)"
            )
        }
        state = current
    }

    /// Appends audio timed by accumulated sample count, which is inherently monotonic and
    /// cannot overlap a previous buffer.
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = state, !current.finished, !audioDisabled,
              let audioInput = current.audioInput,
              audioInput.isReadyForMoreMediaData,
              current.writer.status == .writing else { return }

        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0, buffer.frameLength > 0 else { return }

        let pts = CMTime(value: current.audioFramesWritten, timescale: CMTimeScale(sampleRate))
        if let sampleBuffer = Self.makeAudioSampleBuffer(from: buffer, presentationTime: pts) {
            if audioInput.append(sampleBuffer) {
                current.audioFramesWritten += Int64(buffer.frameLength)
            } else {
                // Stop feeding audio rather than let repeated failures take the writer down;
                // a silent video is better than a lost recording.
                audioDisabled = true
                let nsError = current.writer.error as NSError?
                let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
                let asbd = buffer.format.streamDescription.pointee
                Self.logger.error(
                    """
                    AUDIOFAIL domain=\(nsError?.domain ?? "nil", privacy: .public) \
                    code=\(nsError?.code ?? 0, privacy: .public) \
                    underlying=\(underlying?.domain ?? "nil", privacy: .public)/\(underlying?.code ?? 0, privacy: .public) \
                    formatID=\(asbd.mFormatID, privacy: .public) \
                    flags=\(asbd.mFormatFlags, privacy: .public) \
                    rate=\(asbd.mSampleRate, privacy: .public) \
                    ch=\(asbd.mChannelsPerFrame, privacy: .public) \
                    bits=\(asbd.mBitsPerChannel, privacy: .public) \
                    bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public) \
                    framesPerPacket=\(asbd.mFramesPerPacket, privacy: .public) \
                    frames=\(buffer.frameLength, privacy: .public) \
                    pts=\(pts.seconds, privacy: .public)
                    """
                )
            }
        }
        state = current
    }

    func stop() async -> StopResult {
        lock.lock()
        shouldAcceptNewFrames = false
        guard var current = state, !current.finished else {
            lock.unlock()
            return .nothingRecorded
        }
        current.finished = true
        state = current
        lock.unlock()

        current.videoInput.markAsFinished()
        current.audioInput?.markAsFinished()

        await current.writer.finishWriting()

        lock.lock()
        state = nil
        lock.unlock()

        guard current.lastVideoPTS != nil else {
            try? FileManager.default.removeItem(at: current.outputURL)
            return .nothingRecorded
        }
        if current.writer.status == .completed {
            return .completed(current.outputURL)
        }
        return .failed(current.writer.error?.localizedDescription ?? "Writer did not complete")
    }

    // MARK: - Helpers

    /// Detects an HEVC keyframe by inspecting NAL unit types, because the SDK's buffers carry
    /// no sync-sample attachments — relying on those would treat every frame as a keyframe.
    ///
    /// Buffers are in HVCC form: each NAL unit is a 4-byte big-endian length followed by the
    /// unit, whose header encodes the type in bits 1-6. Types 16-21 (BLA/IDR/CRA) are
    /// random-access points.
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        var offset = 0

        while offset + 4 < totalLength {
            var lengthBigEndian: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(
                dataBuffer, atOffset: offset, dataLength: 4, destination: &lengthBigEndian
            ) == kCMBlockBufferNoErr else { return false }

            let nalLength = Int(UInt32(bigEndian: lengthBigEndian))
            offset += 4
            guard nalLength > 0, offset + nalLength <= totalLength else { return false }

            var header: UInt8 = 0
            guard CMBlockBufferCopyDataBytes(
                dataBuffer, atOffset: offset, dataLength: 1, destination: &header
            ) == kCMBlockBufferNoErr else { return false }

            let nalUnitType = (header >> 1) & 0x3F
            if nalUnitType >= 16 && nalUnitType <= 21 { return true }

            offset += nalLength
        }
        return false
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        // Frames from the SDK may carry no duration. Without one the sample table is
        // zero-length and the resulting file is not seekable.
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || duration <= .zero {
            duration = CMTime(value: 1, timescale: 24)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        return status == noErr ? retimed : nil
    }

    /// Builds a sample buffer from interleaved Int16 PCM.
    ///
    /// The data block is sized from `frameLength` and the per-sample size is declared
    /// explicitly. Deriving it from `mutableAudioBufferList` instead sizes the block by frame
    /// *capacity*, so the byte count disagrees with the sample count and the encoder rejects
    /// the buffer outright.
    private static func makeAudioSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        guard let samples = buffer.int16ChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var asbd = buffer.format.streamDescription.pointee
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let dataSize = frames * bytesPerFrame

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }

        guard CMBlockBufferReplaceDataBytes(
            with: samples[0],
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataSize
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
