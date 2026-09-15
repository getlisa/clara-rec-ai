import MWDATCore
import SwiftUI

@main
struct ClaraAssistantApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Failed to configure Wearables SDK: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // The Meta AI app returns here after the glasses registration flow.
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
        }
    }
}
