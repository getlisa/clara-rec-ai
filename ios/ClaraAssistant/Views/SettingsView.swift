import MWDATCore
import SwiftUI

struct SettingsView: View {
    let controller: GlassesController

    @AppStorage(AppSettings.videoQualityKey) private var videoQuality = VideoQuality.medium.rawValue
    @State private var isWorking = false

    private var isRegistered: Bool { controller.registrationState == .registered }

    var body: some View {
        Form {
            Section("Glasses") {
                if isRegistered {
                    Button(role: .destructive) {
                        Task {
                            isWorking = true
                            await controller.unregister()
                            isWorking = false
                        }
                    } label: {
                        Label("Disconnect my glasses", systemImage: "eyeglasses.slash")
                    }
                } else {
                    Button {
                        Task {
                            isWorking = true
                            await controller.register()
                            isWorking = false
                        }
                    } label: {
                        Label("Connect my glasses", systemImage: "eyeglasses")
                    }
                }

                LabeledContent("Status") {
                    Text(registrationLabel)
                        .foregroundStyle(isRegistered ? .green : .secondary)
                }
            }
            .disabled(isWorking)

            Section("Connected devices") {
                if controller.deviceInfos.isEmpty {
                    Text("No glasses known to the SDK. Pair them to this iPhone in the Meta AI app, with Developer Mode enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.deviceInfos) { info in
                        HStack(spacing: 10) {
                            Image(systemName: info.isEligible ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(info.isEligible ? .green : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                Text(info.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button("Refresh") { controller.refreshDeviceInfos() }
            }

            Section {
                LabeledContent("Glasses camera") {
                    Text(cameraPermissionLabel)
                        .foregroundStyle(controller.cameraPermission == .granted ? .green : .orange)
                }

                if controller.cameraPermission != .granted {
                    Button {
                        Task { await controller.requestCameraPermission() }
                    } label: {
                        Label("Grant camera access", systemImage: "camera")
                    }
                }

                Button("Re-check") {
                    Task { await controller.refreshCameraPermission() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("The glasses camera is granted through the Meta AI app, separately from iOS permissions.")
            }

            Section {
                Picker("Video quality", selection: $videoQuality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(VideoQuality(rawValue: videoQuality)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Camera")
            } footer: {
                Text("The glasses stream over Bluetooth, so higher quality needs a stronger link and may drop frames.")
            }

            Section {
                LabeledContent("Recordings", value: "Saved to the \(PhotoLibrarySaver.albumName) album in Photos")
                LabeledContent("Audio") {
                    Text("Glasses microphone when connected, otherwise the phone's")
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("About")
            }

            if let status = controller.statusMessage {
                Section("Last message") {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { controller.refreshDeviceInfos() }
    }

    private var cameraPermissionLabel: String {
        switch controller.cameraPermission {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case nil: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private var registrationLabel: String {
        switch controller.registrationState {
        case .registered: return "Connected"
        case .registering: return "Connecting…"
        case .available: return "Not connected"
        case .unavailable: return "Meta AI app unavailable"
        @unknown default: return "Unknown"
        }
    }
}
