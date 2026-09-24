import MWDATCamera
import SwiftUI

struct LiveView: View {
    let controller: GlassesController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewLayerView(layer: controller.previewLayer)
                .ignoresSafeArea()

            if controller.framesPerSecond == 0 && controller.renderedPerSecond == 0 {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                HStack(alignment: .top) {
                    DiagnosticsOverlay(controller: controller)
                    Spacer()
                    if case .recording(let startedAt) = controller.recordingState {
                        RecordingBadge(startedAt: startedAt, fromGlasses: controller.audioFromGlasses)
                    }
                }
                .padding()

                Spacer()

                if let photo = controller.unsolicitedPhoto {
                    VStack(spacing: 8) {
                        Text("Photo arrived from the glasses")
                            .font(.headline)
                        Text("This app did not request it — the hardware capture button reached us.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Dismiss") { controller.clearUnsolicitedPhoto() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal)
                }

                UploadStatusView(uploader: controller.imageUploader)
                    .padding(.horizontal)

                if let status = controller.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                }

                HStack {
                    ShutterButton(isBusy: controller.imageUploader.isUploading) {
                        controller.capturePhoto()
                    }
                    .frame(maxWidth: .infinity)

                    RecordButton(isRecording: controller.isRecording) {
                        Task {
                            if controller.isRecording {
                                await controller.stopRecording()
                            } else {
                                await controller.startRecording()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Balances the shutter so the record button stays centred.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await controller.startStreaming(resolution: AppSettings.videoQuality.resolution) }
        .onDisappear { controller.stopStreaming() }
    }
}

private struct DiagnosticsOverlay: View {
    let controller: GlassesController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("session: \(controller.sessionState.description)")
            Text("stream: \(String(describing: controller.streamState))")
            Text("devices: \(controller.devices.count)")
            Text("in:  \(controller.framesPerSecond, specifier: "%.1f") fps")
            Text("out: \(controller.renderedPerSecond, specifier: "%.1f") fps")
            Text("quality: \(AppSettings.videoQuality.title)")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 28)
                    .fill(.red)
                    .frame(width: isRecording ? 30 : 56, height: isRecording ? 30 : 56)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }
        }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct ShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 52, height: 52)
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(isBusy)
        .accessibilityLabel("Take a photo")
    }
}

/// Only speaks up once there is something to say: a capture with no bucket configured stays
/// silent rather than nagging on every shot.
private struct UploadStatusView: View {
    let uploader: ImageUploader

    var body: some View {
        switch uploader.status {
        case .idle, .notConfigured:
            EmptyView()
        case .uploading:
            badge {
                ProgressView().tint(.white).scaleEffect(0.7)
                Text("Uploading to cloud…").foregroundStyle(.white)
            }
        case .uploaded:
            badge {
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
                Text("Saved to cloud · \(uploader.authorPrefix)")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .failed(let message):
            badge {
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Button("Retry") { uploader.retry() }
                    .font(.footnote.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
        }
    }

    @ViewBuilder
    private func badge(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            if let capture = uploader.lastCapture {
                Image(uiImage: capture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            content()
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RecordingBadge: View {
    let startedAt: Date
    let fromGlasses: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt))
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Image(systemName: fromGlasses ? "eyeglasses" : "iphone")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
        }
    }
}
