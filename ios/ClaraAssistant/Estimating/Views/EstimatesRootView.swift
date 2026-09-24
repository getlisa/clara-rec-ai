import SwiftUI

/// The Estimates tab's root, and the app's only authentication gate.
///
/// Everything else in Clara-Assistant works signed out, so the gate lives here rather than in
/// front of the whole app: the next TestFlight build must not lock existing testers out of
/// recording because they have no estimating account.
struct EstimatesRootView: View {
    @State private var session = AuthSession.shared

    var body: some View {
        Group {
            if session.isRestoring {
                // Reading the Keychain is fast, but flashing the login form at someone who is
                // already signed in looks like being logged out.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.isAuthenticated {
                EstimatesListView()
            } else {
                LoginView(session: session)
                    .navigationTitle("Estimates")
            }
        }
        .task { if session.isRestoring { session.restore() } }
    }
}
