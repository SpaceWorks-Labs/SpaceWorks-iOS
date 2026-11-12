import SwiftUI

/// First-run "Help improve" sheet: one switch per configured, not-yet-asked purpose. Shown once per
/// purpose set; never blocks sign-in (it is dismissible and every choice can change later in Profile).
struct TelemetryConsentSheet: View {
    let telemetry: Telemetry
    let done: () -> Void
    @State private var choices: [TelemetryPurpose: Bool] = [:]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Help improve \(Brand.appName)").brandFont(.title, weight: .bold).accessibilityAddTraits(.isHeader)
                    Text("Choose what this app may share to help fix problems and improve features. Everything is off until you turn it on. Your name, email and what you type are never sent.")
                        .foregroundStyle(Color.swMuted)
                    SWCard {
                        ForEach(telemetry.unaskedPurposes) { purpose in
                            TelemetryPurposeToggle(purpose: purpose, isOn: Binding(get: { choices[purpose] ?? false }, set: { choices[purpose] = $0 }))
                        }
                    }
                    Button("Allow all") { decide(true) }.buttonStyle(SWPrimary()).accessibilityIdentifier("telemetry-allow-all")
                    Button("Save choices") { save() }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("telemetry-save")
                    Button("Not now") { decide(false) }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("telemetry-not-now")
                    Text("You can change this any time in Profile → Privacy and analytics.").brandFont(.footnote).foregroundStyle(Color.swMuted)
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(Color.swBg)
        }
        .telemetryScreen(.consent_prompt)
    }
    private func decide(_ granted: Bool) {
        telemetry.setConsent(Dictionary(uniqueKeysWithValues: telemetry.unaskedPurposes.map { ($0, granted) })); done()
    }
    private func save() {
        telemetry.setConsent(Dictionary(uniqueKeysWithValues: telemetry.unaskedPurposes.map { ($0, choices[$0] ?? false) })); done()
    }
}

/// Profile → Privacy and analytics: the same switches at any time; changes apply immediately.
struct PrivacyAnalyticsView: View {
    let telemetry: Telemetry
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SWCard {
                    ForEach(telemetry.availablePurposes) { purpose in
                        TelemetryPurposeToggle(purpose: purpose, isOn: Binding(get: { telemetry.isGranted(purpose) },
                                                                               set: { telemetry.setConsent([purpose: $0]) }))
                    }
                }
                Text("Withdrawing stops collection now. It cannot delete what a provider already holds.").foregroundStyle(Color.swMuted)
                    .accessibilityIdentifier("telemetry-withdrawal-note")
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color.swBg).navigationTitle("Privacy and analytics").telemetryScreen(.privacy_analytics)
    }
}

private struct TelemetryPurposeToggle: View {
    let purpose: TelemetryPurpose
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(purpose.title).brandFont(.headline)
                Text(purpose.detail).brandFont(.subheadline).foregroundStyle(Color.swMuted)
            }
        }
        .tint(Color.swAccent).frame(minHeight: 48)
        .accessibilityIdentifier("telemetry-\(purpose.rawValue)")
    }
}

private struct TelemetryScreenModifier: ViewModifier {
    let screen: TelemetryScreen
    func body(content: Content) -> some View {
        content
            .onAppear { Telemetry.shared.enterScreen(screen) }
            .onDisappear { Telemetry.shared.leaveScreen(screen) }
    }
}

extension View {
    /// Records a `screen_view` with the route template and pauses replay on sensitive screens.
    func telemetryScreen(_ screen: TelemetryScreen) -> some View { modifier(TelemetryScreenModifier(screen: screen)) }
}

extension AppTab {
    var telemetryScreen: TelemetryScreen {
        switch self {
        case .home: return .home
        case .inventory: return .inventory
        case .activity: return .activity
        case .inbox: return .inbox
        case .profile: return .profile
        }
    }
}

extension MemberRoute {
    var telemetryScreen: TelemetryScreen {
        switch self {
        case .product: return .inventory_detail
        case .bookings: return .bookings
        case .spaces: return .spaces
        case .space: return .space_detail
        case .event: return .event_detail
        case .booking: return .booking_detail
        case .registration: return .event_ticket
        case .contact: return .profile_edit
        case .preferences: return .communication_preferences
        case .payments: return .payments
        case .payment: return .payment_detail
        case .staff: return .staff_tools
        case .account: return .account_security
        }
    }
}

extension MobileLink.Destination {
    /// The destination's route template, never its id or token.
    var telemetryKind: String {
        switch self {
        case .home: return "home"
        case .inventory: return "inventory"
        case .product: return "inventory_detail"
        case .activity: return "activity"
        case .inbox: return "inbox"
        case .profile: return "profile"
        case .bookings: return "bookings"
        case .booking: return "booking_detail"
        case .events: return "events"
        case .event: return "event_detail"
        case .registrations: return "event_ticket"
        case .spaces: return "spaces"
        case .space: return "space_detail"
        case .payments: return "payments"
        case .payment: return "payment_detail"
        }
    }
}

extension NativePaymentOutcome {
    var telemetryOutcome: String {
        switch self {
        case .awaitingServerConfirmation: return "pending"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .unavailable: return "unavailable"
        }
    }
}
