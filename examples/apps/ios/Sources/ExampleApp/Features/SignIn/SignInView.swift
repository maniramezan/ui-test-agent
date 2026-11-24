import SwiftUI

struct SignInView: View {
    let session: SessionModel

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Sign in")
                .font(Theme.Typography.title)
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(ID.signInEmail)
            FieldProblem(text: session.fieldErrors["email"])
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(ID.signInPassword)
            FieldProblem(text: session.fieldErrors["password"])
            if let message = session.message {
                Text(message)
                    .font(Theme.Typography.detail)
                    .foregroundStyle(Theme.Palette.failure)
                    .accessibilityIdentifier(ID.signInError)
            }
            Button {
                Task {
                    await session.signIn(email: email, password: password)
                }
            } label: {
                SignInButtonLabel(busy: session.phase == .signingIn)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.phase == .signingIn)
            .accessibilityIdentifier(ID.signInSubmit)
            Spacer()
        }
        .padding(Theme.Spacing.large)
    }
}

private struct SignInButtonLabel: View {
    let busy: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            if busy {
                ProgressView()
            }
            Text("Sign in")
        }
        .frame(maxWidth: .infinity)
    }
}

/// A validation message under a field, absent when the field is fine.
struct FieldProblem: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.failure)
        }
    }
}
