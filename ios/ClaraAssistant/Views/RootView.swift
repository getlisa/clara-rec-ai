import MWDATCore
import SwiftUI

struct RootView: View {
    @State private var controller = GlassesController.shared

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(controller: controller)
                    .navigationTitle("Clara-Assistant")
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                ClipsView()
                    .navigationTitle("Clips")
            }
            .tabItem { Label("Clips", systemImage: "video") }

            NavigationStack {
                SettingsView(controller: controller)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            controller.startObserving()
            controller.refreshDeviceInfos()
        }
    }
}

struct HomeView: View {
    let controller: GlassesController

    private var isConnected: Bool {
        controller.deviceInfos.contains(where: \.isEligible)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 88, weight: .thin))
                    .foregroundStyle(.tint)
                    .padding(.top, 8)

                Text("Record what you see and hear through your Meta Glasses.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                NavigationLink {
                    LiveView(controller: controller)
                } label: {
                    FeatureCard(
                        title: "Start Streaming",
                        subtitle: "See live view from glasses",
                        systemImage: "video.fill",
                        enabled: isConnected
                    )
                }
                .buttonStyle(.plain)

                if !isConnected {
                    Text(controller.registrationState == .registered
                         ? "Glasses are not connected. Open Settings to check their status."
                         : "Connect your glasses in Settings to get started.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding()
        }
        .onAppear { controller.refreshDeviceInfos() }
    }
}

struct FeatureCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        .opacity(enabled ? 1 : 0.5)
    }
}
