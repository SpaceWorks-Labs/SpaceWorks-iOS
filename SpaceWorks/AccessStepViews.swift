import SwiftUI
import SpaceWorksAPI

/// "Choose your username" — blocking until the account has one (`handle_required`).
struct ChooseUsernameView: View {
    let auth: AuthState
    @State private var form: UsernameState?
    var body: some View {
        ScrollView {
            SWCard {
                Image(systemName: "at").font(.largeTitle).foregroundStyle(Color.swAccentInk).accessibilityHidden(true)
                Text("Choose your username").brandFont(.largeTitle, weight: .bold).accessibilityAddTraits(.isHeader)
                Text("Your username is how people find you. Pick one to keep using your makerspace.").foregroundStyle(Color.swMuted)
                if let form { UsernameFields(form: form) }
                if let error = auth.error { SWError(message: error) }
                Button("Sign out") { Task { await auth.signOut() } }.frame(minHeight: 48).disabled(auth.busy || form?.busy == true)
            }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }.background(Color.swBg).accessibilityIdentifier("choose-username")
            .task { if form == nil { form = auth.usernameForm() } }
    }
}

private struct UsernameFields: View {
    @Bindable var form: UsernameState
    var body: some View {
        Text("Username").brandFont(.headline)
        TextField("Username", text: $form.handle, prompt: Text("Username").foregroundColor(Color.swMuted))
            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
            .background(Color.swBg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.swOutline)).accessibilityIdentifier("username-field")
            .task(id: form.handle) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await form.checkAvailability()
            }
        if form.availability == true { Label("Available", systemImage: "checkmark.circle").foregroundStyle(Color.swAccentInk).accessibilityIdentifier("username-available") }
        if form.availability == false {
            Label(form.unavailableMessage, systemImage: "xmark.circle").foregroundStyle(Color.swDanger).accessibilityIdentifier("username-unavailable")
        }
        if let suggestion = form.suggestion, suggestion != form.trimmed {
            Button("Use \(suggestion)") { form.useSuggestion() }.frame(minHeight: 48).accessibilityIdentifier("username-suggestion")
        }
        if let error = form.error { SWError(message: error) }
        Button(form.busy ? "Saving…" : "Continue") { Task { await form.submit() } }
            .buttonStyle(SWPrimary()).disabled(!form.canSubmit).accessibilityIdentifier("username-continue")
    }
}

/// The staff step-up sheet: makerspace, then the authenticator (or enrolment), then staff tools.
struct StaffStepUpView: View {
    @Bindable var staff: StaffAccessState
    let done: () -> Void
    @State private var codesSaved = false
    var body: some View {
        NavigationStack {
            ScrollView {
                SWCard {
                    switch staff.step {
                    case .idle:
                        Text("Open staff tools").brandFont(.largeTitle, weight: .bold).accessibilityAddTraits(.isHeader)
                        Text("Staff tools need a separate staff sign-in for one makerspace, confirmed with your authenticator. Your member account stays signed in.")
                            .foregroundStyle(Color.swMuted)
                        Text("Makerspace").brandFont(.headline)
                        TextField("Makerspace", text: $staff.slug, prompt: Text("Makerspace short name").foregroundColor(Color.swMuted))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
                            .background(Color.swBg, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.swOutline)).accessibilityIdentifier("staff-makerspace")
                        if let error = staff.error { SWError(message: error) }
                        Button(staff.busy ? "Checking…" : "Continue") { Task { await staff.begin() } }
                            .buttonStyle(SWPrimary()).disabled(staff.busy).accessibilityIdentifier("staff-step-up-continue")
                    case .mfa:
                        Text(staff.enrollment == nil ? "Check your authenticator" : "Add extra security").brandFont(.largeTitle, weight: .bold)
                        if let enrollment = staff.enrollment {
                            Text("Staff tools need an authenticator. Add this account to your authenticator app, then enter its six-digit code.").foregroundStyle(Color.swMuted)
                            QRCodeView(value: enrollment.provisioning_uri)
                            Text(enrollment.secret).monospacedDigit().textSelection(.enabled)
                        } else {
                            Text("Enter the six-digit code from your authenticator app, or a recovery code.").foregroundStyle(Color.swMuted)
                        }
                        TextField("Authentication code", text: $staff.code, prompt: Text("Authentication code").foregroundColor(Color.swMuted))
                            .textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
                            .background(Color.swBg, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.swOutline)).accessibilityIdentifier("staff-mfa-code")
                        if let error = staff.error { SWError(message: error) }
                        Button(staff.busy ? "Verifying…" : "Verify") { Task { await staff.verify(); if staff.step == .idle, staff.target != nil { done() } } }
                            .buttonStyle(SWPrimary()).disabled(staff.busy).accessibilityIdentifier("staff-verify")
                        Button("Cancel") { staff.cancel() }.frame(minHeight: 48).disabled(staff.busy)
                    case .recoveryCodes:
                        Text("Save your recovery codes").brandFont(.largeTitle, weight: .bold)
                        Text("Keep these somewhere safe. Each code works once.").foregroundStyle(Color.swMuted)
                        ForEach(staff.recoveryCodes, id: \.self) { Text($0).monospacedDigit().textSelection(.enabled) }
                        Toggle("I've saved my recovery codes", isOn: $codesSaved).frame(minHeight: 48)
                        Button("Continue") { staff.confirmRecoveryCodes(); done() }.buttonStyle(SWPrimary()).disabled(!codesSaved)
                    }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.background(Color.swBg)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { staff.cancel(); done() }.disabled(staff.busy) } }
        }
    }
}
