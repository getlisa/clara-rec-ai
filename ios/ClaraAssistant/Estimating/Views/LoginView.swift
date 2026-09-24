import SwiftUI

/// Sign-in for the Estimates tab only. Recording, Clips and the glasses have never needed an
/// account and still don't — which is why this explains itself rather than presenting a bare
/// email/password form to a tester who has no idea what it wants.
struct LoginView: View {
    let session: AuthSession

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !session.isWorking
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(.tint)

                    Text("Estimates")
                        .font(.title2.bold())

                    Text("Build a quote by talking through the job, and attach photos straight from your glasses. Sign in with your Clara technician account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        // The login service compares case-sensitively against lowercase records,
                        // so an autocapitalising keyboard would produce 401s nobody can explain.
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { submit() } }
                }
                .textFieldStyle(.roundedBorder)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    if session.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Sign in").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)

                Text("Signing out here doesn't affect recording or your saved clips.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        focused = nil
        errorMessage = nil
        Task {
            do {
                try await session.signIn(email: email, password: password)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
