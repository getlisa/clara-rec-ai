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

                if let status = controller.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                }

                RecordButton(isRecording: controller.isRecording) {
                    Task {
                        if controller.isRecording {
                            await controller.stopRecording()
                        } else {
                            await controller.startRecording()
                        }
                    }
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
