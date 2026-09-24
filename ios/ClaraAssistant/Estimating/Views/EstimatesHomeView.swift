import SwiftUI

/// Placeholder for the quote list, which needs copilot-server — currently returning 504 from the
/// staging gateway.
///
/// It is not idle scaffolding: it proves the two things that had to be true before the list can be
/// built. That the signed-in identity the server will see is the one we think it is, and that a
/// glasses capture works *from this tab* — where, until `captureStill()`, there was no camera
/// session at all. Replace it with `EstimatesListView` in Phase 3.
struct EstimatesHomeView: View {
    let session: AuthSession

    @State private var controller = GlassesController.shared
    @State private var capture: CaptureResult?
    @State private var captureError: String?

    private struct CaptureResult {
        let image: UIImage
        let originalBytes: Int
        let normalizedBytes: Int
        let originalOrientation: UInt32?
        let wasRotated: Bool
    }

    var body: some View {
        List {
            Section("Signed in") {
                LabeledContent("Name", value: session.user?.displayName ?? "—")
                LabeledContent("Email", value: session.claims?.email ?? session.user?.email ?? "—")
                LabeledContent("Role", value: session.claims?.role ?? "—")
                LabeledContent("Company") {
                    Text(session.claims?.companyId.map(String.init) ?? "—")
                        .monospacedDigit()
                }
                if let expiry = session.claims?.expiresAt {
                    LabeledContent("Token expires") {
                        Text(expiry, format: .relative(presentation: .named))
                            .foregroundStyle(session.claims?.isExpired == true ? .red : .secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await runCapture() }
                } label: {
                    HStack {
                        Label(captureButtonTitle, systemImage: "camera.viewfinder")
                        Spacer()
                        if controller.captureStatus != .idle { ProgressView() }
                    }
                }
                .disabled(controller.captureStatus != .idle)

                if let capture {
                    Image(uiImage: capture.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    LabeledContent("EXIF orientation") {
                        Text(capture.originalOrientation.map(String.init) ?? "none")
                            .monospaced()
                            .foregroundStyle(capture.wasRotated ? .orange : .green)
                    }
                    LabeledContent("Rotation applied", value: capture.wasRotated ? "Yes" : "Not needed")
                    LabeledContent("Size") {
                        Text("\(capture.originalBytes / 1024) KB → \(capture.normalizedBytes / 1024) KB")
                            .monospacedDigit()
                    }
                }

                if let captureError {
                    Label(captureError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Glasses capture")
            } footer: {
                Text("Takes a photo without opening the live view. If the EXIF orientation is anything but 1, the proposal PDF would print it sideways — so it gets rotated before upload.")
            }

            Section {
                Label("Quote list needs copilot-server", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("The staging API gateway is returning 504. Estimates load once it is back.")
            }

            Section {
                Button("Sign out", role: .destructive) {
                    Task { await session.signOut() }
                }
                .disabled(session.isWorking)
            }
        }
    }

    private var captureButtonTitle: String {
        switch controller.captureStatus {
        case .preparing: return "Waking the glasses…"
        case .capturing: return "Capturing…"
        case .idle: return "Take a photo with the glasses"
        }
    }

    private func runCapture() async {
        captureError = nil
        capture = nil

        guard let jpeg = await controller.captureStill() else {
            captureError = controller.statusMessage ?? "No photo came back from the glasses."
            return
        }

        let orientation = JPEGOrientation.orientation(of: jpeg)
        let normalized = JPEGOrientation.normalized(jpeg)
        Diag.log(
            "capture",
            "EXIF orientation=\(orientation.map(String.init) ?? "none") "
                + "rotated=\(normalized.count != jpeg.count) "
                + "\(jpeg.count)B → \(normalized.count)B"
        )
        guard let image = UIImage(data: normalized) else {
            captureError = "The glasses returned data that isn't a readable JPEG."
            return
        }

        capture = CaptureResult(
            image: image,
            originalBytes: jpeg.count,
            normalizedBytes: normalized.count,
            originalOrientation: orientation,
            wasRotated: normalized.count != jpeg.count
        )
    }
}
