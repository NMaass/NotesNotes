import ResonoteKit
import SwiftUI

/// Sign in: Continue with Spotify, or an email one-time code, in a stock grouped form.
/// Whatever the person was doing continues afterward (`AppModel.requireAuth`).
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    private enum Step { case email, code }
    private enum Field: Hashable { case email, code }

    @State private var step: Step = .email
    @State private var email = ""
    /// The address the current code went to; frozen so typing never reflows the other step.
    @State private var sentTo = ""
    @State private var code = ""
    @State private var devCode: String?
    @State private var error: String?
    @State private var failures = 0
    @State private var isBusy = false
    @State private var busyLabel = "Sending…"
    @State private var work: Task<Void, Never>?
    /// A verified sign-in as someone other than the person whose unsynced changes are on
    /// this iPhone, waiting for the person to choose.
    @State private var handover: Handover?
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Handover: Equatable {
        var token: String
        var bundle: ProfileBundle
        var lostChanges: Int
        var previousHandle: String
    }

    var body: some View {
        NavigationStack {
            Form {
                if step == .email {
                    emailStep
                } else {
                    codeStep
                }
                Section {
                } footer: {
                    agreement
                }
            }
            .navigationTitle(step == .email ? "Sign In" : "Enter Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy {
                        ProgressView()
                    } else {
                        Button(step == .email ? "Next" : "Verify", action: primaryAction)
                            .disabled(handover != nil || (step == .email ? !email.contains("@") : code.count != 6))
                    }
                }
            }
        }
        .interactiveDismissDisabled(isBusy || handover != nil)
        .confirmationDialog(handoverTitle, isPresented: handoverIsPresented, titleVisibility: .visible, presenting: handover) { pending in
            Button("Sign in as @\(pending.bundle.profile.handle)", role: .destructive) {
                handover = nil
                finishSignIn(token: pending.token, bundle: pending.bundle)
            }
            Button("Cancel", role: .cancel) { cancelHandover() }
        } message: { pending in
            Text("They will be removed from this iPhone. Unpublished words stay in @\(pending.previousHandle)'s drafts here. To send them, sign in as @\(pending.previousHandle) instead.")
        }
        .sensoryFeedback(.error, trigger: failures)
        .onAppear { focus = .email }
        .onDisappear { work?.cancel() }
    }

    // MARK: Steps

    /// Spotify first (one tap, no code), then email with a one-time code.
    @ViewBuilder
    private var emailStep: some View {
        if !model.sessionExpired {
            Section {
                SpotifySignInButton(title: "Continue with Spotify")
            }
        }
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit(primaryAction)
        } header: {
            Text("Continue with email")
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if model.sessionExpired, let handle = model.profile?.handle {
                Text("Use the email for @\(handle) to send what's waiting on this iPhone.")
            } else {
                Text("We'll email you a 6-digit code. No password needed.")
            }
        }
    }

    @ViewBuilder
    private var codeStep: some View {
        Section {
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title3.monospacedDigit())
                .focused($focus, equals: .code)
                .onChange(of: code) { previous, value in codeChanged(from: previous, to: value) }
        } header: {
            Text("Enter the 6-digit code we sent to \(sentTo)")
                .textCase(nil)
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let devCode {
                Text("Development server: your code is \(devCode)")
            }
        }
        Section {
            Button("Resend Code", action: requestCode)
                .disabled(isBusy)
            Button("Use a Different Email", action: useDifferentEmail)
        }
    }

    /// What continuing agrees to, with both documents a tap away.
    private var agreement: some View {
        Text(Self.agreementText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let agreementText: AttributedString = {
        func link(_ title: String, _ url: URL) -> AttributedString {
            var text = AttributedString(title)
            text.link = url
            return text
        }
        var text = AttributedString("By continuing, you agree to the ")
        text += link("Terms of Use", ResonoteLinks.terms)
        text += AttributedString(" and ")
        text += link("Privacy Policy", ResonoteLinks.privacy)
        text += AttributedString(".")
        return text
    }()

    // MARK: Actions

    private func primaryAction() {
        switch step {
        case .email: requestCode()
        case .code: submitCode()
        }
    }

    private func requestCode() {
        guard !isBusy else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            fail("Enter an email address.")
            return
        }
        run(label: "Sending…") { await sendCode(to: address) }
    }

    private func submitCode() {
        guard !isBusy, code.count == 6 else { return }
        let address = sentTo
        let enteredCode = code
        run(label: "Working…") { await verify(email: address, code: enteredCode) }
    }

    /// One request at a time; the label swaps in place and the button keeps its size.
    private func run(label: String, _ operation: @escaping @MainActor () async -> Void) {
        error = nil
        busyLabel = label
        isBusy = true
        work = Task {
            await operation()
            isBusy = false
        }
    }

    private func sendCode(to address: String) async {
        do {
            let response = try await model.api.requestCode(email: address)
            guard !Task.isCancelled else { return }
            guard response.ok else {
                fail(response.error ?? "Could not send a code.")
                return
            }
            email = address
            sentTo = address
            devCode = response.devCode
            code = response.devCode ?? ""
            withAnimation(reduceMotion ? nil : RN.Motion.quick) { step = .code }
            focus = .code
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            fail(Self.message(for: error, fallback: "Could not send a code."))
        }
    }

    private func verify(email address: String, code enteredCode: String) async {
        do {
            let response = try await model.api.verify(email: address, code: enteredCode)
            guard !Task.isCancelled else { return }
            guard response.ok, let token = response.token, let bundle = response.bundle else {
                fail(response.error ?? "Sign-in didn't finish. Request a fresh code and try again.")
                return
            }
            // Another account than the one whose changes haven't synced: ask before they go.
            let lost = await model.unsyncedChangesLost(signingInAs: bundle.profile.id)
            guard !Task.isCancelled else {
                model.discardSession(token: token)
                return
            }
            if lost > 0, let previous = model.profile?.handle {
                handover = Handover(token: token, bundle: bundle, lostChanges: lost, previousHandle: previous)
                return
            }
            finishSignIn(token: token, bundle: bundle)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            fail(Self.message(for: error, fallback: "The code could not be verified."))
        }
    }

    private func finishSignIn(token: String, bundle: ProfileBundle) {
        let presentedByRouter = router.sheet == .signIn
        model.completeSignIn(token: token, bundle: bundle)
        // The pending intent may have presented something else; only close our own sheet.
        if presentedByRouter, router.sheet == .signIn { router.sheet = nil }
    }

    private var handoverTitle: String {
        guard let handover else { return "" }
        return "\(JournalCopy.count(handover.lostChanges, "change")) made as @\(handover.previousHandle) haven't synced"
    }

    private var handoverIsPresented: Binding<Bool> {
        Binding(
            get: { handover != nil },
            set: { presented in
                guard !presented, let pending = handover else { return }
                // Dismissed without a choice counts as Cancel, once the buttons have had their turn.
                Task { @MainActor in
                    if handover?.token == pending.token { cancelHandover() }
                }
            }
        )
    }

    /// Keeps this iPhone as it was: the new session is ended, and the person can use the
    /// email for the account whose changes are waiting.
    private func cancelHandover() {
        guard let pending = handover else { return }
        handover = nil
        model.discardSession(token: pending.token)
        useDifferentEmail()
        fail("Use the email for @\(pending.previousHandle) to keep its changes.")
    }

    private func codeChanged(from previous: String, to value: String) {
        let digits = String(value.filter(\.isNumber).prefix(6))
        if digits != value {
            code = digits
            return
        }
        // Continue as soon as the sixth digit arrives (typed or autofilled), but not
        // for a development code the app filled in itself.
        if digits.count == 6, previous.count < 6, digits != devCode {
            submitCode()
        }
    }

    private func useDifferentEmail() {
        work?.cancel()
        code = ""
        devCode = nil
        error = nil
        step = .email
        focus = .email
    }

    private func cancel() {
        work?.cancel()
        model.cancelSignIn()
        if router.sheet == .signIn { router.sheet = nil }
    }

    private func fail(_ message: String) {
        error = message
        failures += 1
    }

    /// The server's own words where it gave them.
    private static func message(for error: any Error, fallback: String) -> String {
        switch error as? APIError {
        case .unauthorized?:
            // A 401 from verify means the code was wrong or expired.
            "That code did not match. Request a fresh one."
        case let apiError?:
            apiError.errorDescription ?? fallback
        case nil:
            fallback
        }
    }
}
