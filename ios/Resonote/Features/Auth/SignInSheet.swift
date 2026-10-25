import ResonoteKit
import SwiftUI

/// Email one-time-code sign in. Both steps share one container sized to the
/// larger of the two, so nothing jumps between them, and whatever the person was
/// doing continues afterward (`AppModel.requireAuth`).
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

    private static let labels = ["Send code", "Sending…", "Continue", "Working…"]

    private struct Handover: Equatable {
        var token: String
        var bundle: ProfileBundle
        var lostChanges: Int
        var previousHandle: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RN.Space.l) {
                    ZStack(alignment: .topLeading) {
                        emailStep
                            .opacity(step == .email ? 1 : 0)
                            .allowsHitTesting(step == .email)
                            .accessibilityHidden(step != .email)
                        codeStep
                            .opacity(step == .code ? 1 : 0)
                            .allowsHitTesting(step == .code)
                            .accessibilityHidden(step != .code)
                    }
                    VStack(alignment: .leading, spacing: RN.Space.s) {
                        ReservedErrorRow(message: error)
                        Button(action: primaryAction) {
                            StableLabel(primaryLabel, among: Self.labels)
                        }
                        .buttonStyle(.solid)
                        .disabled(isBusy || handover != nil || (step == .code && code.count != 6))
                        agreement
                    }
                }
                .padding(.horizontal, RN.Space.gutter)
                .padding(.top, RN.Space.l)
                .padding(.bottom, RN.Space.xl)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(RN.Palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
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

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            if model.sessionExpired, let handle = model.profile?.handle {
                // The changes waiting on this iPhone go out only with the same account.
                heading("Sign in again", "Use the email for @\(handle) to send what's waiting on this iPhone.")
            } else {
                heading("Keep your place", "Sign in without a password. Your current action will continue afterward.")
            }
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Text("Email")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RN.Palette.prose)
                TextField("Email", text: $email, prompt: Text("you@example.com"))
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focus, equals: .email)
                    .onSubmit(primaryAction)
                    .modifier(SignInFieldStyle())
            }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            heading("Check your email", "Enter the six-digit code sent to \(sentTo).")
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Text("One-time code")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RN.Palette.prose)
                TextField("One-time code", text: $code, prompt: Text("000000"))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .tracking(4)
                    .focused($focus, equals: .code)
                    .onChange(of: code) { previous, value in codeChanged(from: previous, to: value) }
                    .modifier(SignInFieldStyle())
                if let devCode {
                    Text("Development server: your code is \(devCode)")
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.blue)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: RN.Space.l) { secondaryActions }
                VStack(alignment: .leading, spacing: RN.Space.m) { secondaryActions }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }

    /// Going back always works (it cancels a request in flight); a new code waits for the current one.
    @ViewBuilder
    private var secondaryActions: some View {
        Button("Use a different email", action: useDifferentEmail)
        Button("Send a new code", action: requestCode)
            .disabled(isBusy)
    }

    /// What continuing agrees to, with both documents a tap away.
    private var agreement: some View {
        Text(Self.agreementText)
            .font(.footnote)
            .foregroundStyle(RN.Palette.muted)
            .tint(RN.Palette.rustText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, RN.Space.xs)
    }

    private static let agreementText: AttributedString = {
        func link(_ title: String, _ url: URL) -> AttributedString {
            var text = AttributedString(title)
            text.link = url
            text.underlineStyle = .single
            return text
        }
        var text = AttributedString("By continuing, you agree to Resonote's ")
        text += link("Terms of use", ResonoteLinks.terms)
        text += AttributedString(", including no objectionable content or abusive behavior, and its ")
        text += link("Privacy policy", ResonoteLinks.privacy)
        text += AttributedString(".")
        return text
    }()

    private func heading(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Text(title)
                .font(RN.Typography.title)
                .foregroundStyle(RN.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(RN.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryLabel: String {
        if isBusy { return busyLabel }
        return step == .email ? "Send code" : "Continue"
    }

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
        withAnimation(reduceMotion ? nil : RN.Motion.quick) { step = .email }
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

/// The text field look used on both steps.
private struct SignInFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, RN.Space.m)
            .frame(minHeight: 50)
            .background(RN.Palette.fill, in: RoundedRectangle(cornerRadius: RN.Radius.input))
            .overlay(RoundedRectangle(cornerRadius: RN.Radius.input).strokeBorder(RN.Palette.lineStrong))
    }
}
