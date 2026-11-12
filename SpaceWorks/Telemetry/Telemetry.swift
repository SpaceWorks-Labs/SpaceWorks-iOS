import CryptoKit
import Foundation
import Observation
import SpaceWorksAPI

/// Consent purposes (docs/TELEMETRY.md). Every purpose is off until the person turns it on.
enum TelemetryPurpose: String, CaseIterable, Codable, Identifiable {
    case analytics, replay, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .analytics: return String(localized: "Usage analytics")
        case .replay: return String(localized: "Session replay")
        case .diagnostics: return String(localized: "Crash and performance reports")
        }
    }
    var detail: String {
        switch self {
        case .analytics: return String(localized: "Which screens and features are used, never your name or what you type.")
        case .replay: return String(localized: "Masked recordings of how screens are used. Text, inputs and images are hidden; sign-in, payment and code screens are never recorded.")
        case .diagnostics: return String(localized: "Crash, freeze and speed reports, with addresses and IDs removed.")
        }
    }
}

/// Typed event list shared with Android: snake_case names, string/number/bool properties only.
enum TelemetryEvent: Equatable {
    enum SignInMethod: String { case password, google, apple, oidc, phone, passkey }
    enum SignOutScope: String { case device, everywhere }
    case appOpen, onboardingCompleted
    case serverConnected(locked: Bool)
    case signInStarted(SignInMethod), signInSucceeded(SignInMethod), signInFailed(SignInMethod, code: String)
    case mfaChallengeShown(kind: String)
    case signUpStarted, signUpCompleted, passwordResetRequested
    case signOut(SignOutScope)
    case makerspaceSwitched
    case inventorySearched(hasQuery: Bool)
    case hardwareRequestSubmitted(itemCount: Int)
    case loanRenewed, bookingCreated, bookingCancelled, eventRegistered, eventRegistrationCancelled, ticketOpened
    case paymentStarted(vendor: String), paymentFinished(vendor: String, outcome: String), receiptDownloaded
    case pushPermissionResult(granted: Bool), pushOpened(feature: String), deepLinkOpened(kind: String)
    case staffRequestDecided(decision: String), staffItemIssued, staffItemReturned, staffDirectHandout
    case qrScanned(context: String), eventCheckIn
    case accountDeletionStarted, accountDeletionCompleted
    case consentUpdated(analytics: Bool, replay: Bool, diagnostics: Bool)

    enum Name: String, CaseIterable {
        case app_open, screen_view, onboarding_completed, server_connected, sign_in_started, sign_in_succeeded, sign_in_failed
        case mfa_challenge_shown, sign_up_started, sign_up_completed, password_reset_requested, sign_out, makerspace_switched
        case inventory_searched, hardware_request_submitted, loan_renewed, booking_created, booking_cancelled, event_registered
        case event_registration_cancelled, ticket_opened, payment_started, payment_finished, receipt_downloaded
        case push_permission_result, push_opened, deep_link_opened, staff_request_decided, staff_item_issued, staff_item_returned
        case staff_direct_handout, qr_scanned, event_check_in, account_deletion_started, account_deletion_completed, consent_updated
    }

    var name: Name {
        switch self {
        case .appOpen: return .app_open
        case .onboardingCompleted: return .onboarding_completed
        case .serverConnected: return .server_connected
        case .signInStarted: return .sign_in_started
        case .signInSucceeded: return .sign_in_succeeded
        case .signInFailed: return .sign_in_failed
        case .mfaChallengeShown: return .mfa_challenge_shown
        case .signUpStarted: return .sign_up_started
        case .signUpCompleted: return .sign_up_completed
        case .passwordResetRequested: return .password_reset_requested
        case .signOut: return .sign_out
        case .makerspaceSwitched: return .makerspace_switched
        case .inventorySearched: return .inventory_searched
        case .hardwareRequestSubmitted: return .hardware_request_submitted
        case .loanRenewed: return .loan_renewed
        case .bookingCreated: return .booking_created
        case .bookingCancelled: return .booking_cancelled
        case .eventRegistered: return .event_registered
        case .eventRegistrationCancelled: return .event_registration_cancelled
        case .ticketOpened: return .ticket_opened
        case .paymentStarted: return .payment_started
        case .paymentFinished: return .payment_finished
        case .receiptDownloaded: return .receipt_downloaded
        case .pushPermissionResult: return .push_permission_result
        case .pushOpened: return .push_opened
        case .deepLinkOpened: return .deep_link_opened
        case .staffRequestDecided: return .staff_request_decided
        case .staffItemIssued: return .staff_item_issued
        case .staffItemReturned: return .staff_item_returned
        case .staffDirectHandout: return .staff_direct_handout
        case .qrScanned: return .qr_scanned
        case .eventCheckIn: return .event_check_in
        case .accountDeletionStarted: return .account_deletion_started
        case .accountDeletionCompleted: return .account_deletion_completed
        case .consentUpdated: return .consent_updated
        }
    }

    var properties: [String: TelemetryValue] {
        switch self {
        case .serverConnected(let locked): return ["locked": .bool(locked)]
        case .signInStarted(let method), .signInSucceeded(let method): return ["method": .string(method.rawValue)]
        case .signInFailed(let method, let code): return ["method": .string(method.rawValue), "code": .string(code)]
        case .mfaChallengeShown(let kind): return ["kind": .string(kind)]
        case .signOut(let scope): return ["scope": .string(scope.rawValue)]
        case .inventorySearched(let hasQuery): return ["has_query": .bool(hasQuery)]
        case .hardwareRequestSubmitted(let count): return ["item_count": .int(count)]
        case .paymentStarted(let vendor): return ["vendor": .string(vendor)]
        case .paymentFinished(let vendor, let outcome): return ["vendor": .string(vendor), "outcome": .string(outcome)]
        case .pushPermissionResult(let granted): return ["granted": .bool(granted)]
        case .pushOpened(let feature): return ["feature": .string(feature)]
        case .deepLinkOpened(let kind): return ["kind": .string(kind)]
        case .staffRequestDecided(let decision): return ["decision": .string(decision)]
        case .qrScanned(let context): return ["context": .string(context)]
        case .consentUpdated(let analytics, let replay, let diagnostics):
            return ["analytics": .bool(analytics), "replay": .bool(replay), "diagnostics": .bool(diagnostics)]
        default: return [:]
        }
    }

    /// The server error `code`, else the HTTP status class (`4xx`), else `network`.
    static func failureCode(_ error: Error) -> String {
        if let code = APIError.code(error), !code.isEmpty { return String(code.prefix(64)) }
        if let status = APIError.status(error), status >= 100 { return "\(status / 100)xx" }
        return "network"
    }
}

enum TelemetryValue: Equatable {
    case string(String), int(Int), bool(Bool)
    var value: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .bool(let value): return value
        }
    }
}

/// Route templates, never raw ids. Sensitive screens pause session replay while visible.
enum TelemetryScreen: String, CaseIterable {
    case intro, consent_prompt, server_connect, sign_in, mfa, phone_sign_in, sign_up, password_reset, password_change, recovery_codes, email_verification
    case home, inventory, inventory_detail, activity, inbox, profile, bookings, spaces, space_detail, booking_detail
    case event_detail, event_ticket, membership_card, profile_edit, communication_preferences, payments, payment_detail
    case account_security, account_deletion, notification_settings, app_guide, privacy_analytics
    case staff_tools, staff_scan, staff_evidence

    var sensitive: Bool {
        switch self {
        case .sign_in, .mfa, .phone_sign_in, .sign_up, .password_reset, .password_change, .recovery_codes, .email_verification, .account_deletion,
             .payment_detail, .payments, .membership_card, .event_ticket, .staff_scan, .staff_evidence: return true
        default: return false
        }
    }
}

struct TelemetryUser: Equatable {
    enum RoleKind: String { case member, staff }
    let origin: URL
    let userID: Int
    let roleKind: RoleKind
    /// Lowercase hex SHA-256 of `"<server origin>|<user id>"`; the raw id never leaves the device.
    var pseudonymousID: String { Telemetry.sha256(Telemetry.originString(origin) + "|\(userID)") }
}

/// Build-time public provider identifiers written by `scripts/generate.py` into Info.plist.
struct TelemetryConfig: Equatable {
    var sentryDSN: String?
    var sentryEnvironment: String?
    var tracesSampleRate: Double = 0.1
    var postHogKey: String?
    var postHogHost = "https://eu.i.posthog.com"
    var clarityProjectID: String?
    var firebase = false
    var debugOverride = false

    init(info: [String: Any]?, firebasePlistPresent: Bool) {
        let values = info ?? [:]
        func text(_ key: String) -> String? { (values[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        sentryDSN = text("sentry_dsn")
        sentryEnvironment = text("sentry_environment")
        tracesSampleRate = (values["sentry_traces_sample_rate"] as? NSNumber)?.doubleValue ?? 0.1
        postHogKey = text("posthog_api_key")
        postHogHost = text("posthog_host") ?? postHogHost
        clarityProjectID = text("clarity_project_id")
        firebase = firebasePlistPresent
        debugOverride = values["debug_override"] as? Bool ?? false
    }

    static var bundled: TelemetryConfig {
        TelemetryConfig(info: Bundle.main.object(forInfoDictionaryKey: "SpaceWorksTelemetry") as? [String: Any],
                        firebasePlistPresent: Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil)
    }

    func configured(_ purpose: TelemetryPurpose) -> Bool {
        switch purpose {
        case .analytics: return firebase || postHogKey != nil
        case .replay: return clarityProjectID != nil
        case .diagnostics: return sentryDSN != nil
        }
    }
}

/// Per-install consent, never per account. Only purposes that were asked can be granted.
struct TelemetryConsent: Codable, Equatable {
    static let schemaVersion = 1
    var schema = TelemetryConsent.schemaVersion
    var granted: Set<TelemetryPurpose> = []
    var asked: Set<TelemetryPurpose> = []
}

/// One provider SDK behind the facade. Adapters are started only after their purpose is granted.
@MainActor protocol TelemetryAdapter: AnyObject {
    var purpose: TelemetryPurpose { get }
    func start(superProperties: [String: TelemetryValue])
    func stop()
    func track(_ name: String, properties: [String: TelemetryValue])
    func screen(_ screen: TelemetryScreen)
    func setSuperProperties(_ properties: [String: TelemetryValue])
    func identify(_ user: TelemetryUser)
    func reset()
    func setSensitive(_ sensitive: Bool)
}

extension TelemetryAdapter {
    func track(_ name: String, properties: [String: TelemetryValue]) {}
    func screen(_ screen: TelemetryScreen) {}
    func setSuperProperties(_ properties: [String: TelemetryValue]) {}
    func setSensitive(_ sensitive: Bool) {}
}

/// The app's single telemetry facade. Feature code calls `Telemetry.shared` only.
@MainActor @Observable
final class Telemetry {
    static var shared = Telemetry(config: TelemetryConfig(info: nil, firebasePlistPresent: false), adapters: [], settings: .standard)

    private(set) var consent: TelemetryConsent
    let config: TelemetryConfig
    /// Debug builds never send unless SPACEWORKS_TELEMETRY_DEBUG=1 was set when generating.
    let sendingAllowed: Bool
    /// The DEBUG demo never reaches a provider, even with the debug override.
    @ObservationIgnored var demoActive = false { didSet { if demoActive != oldValue { applySensitivity() } } }
    @ObservationIgnored private let adapters: [any TelemetryAdapter]
    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private var started = Set<ObjectIdentifier>()
    @ObservationIgnored private var superProperties: [String: TelemetryValue]
    @ObservationIgnored private var user: TelemetryUser?
    @ObservationIgnored private var sensitiveScreens = 0
    static let consentKey = "telemetry-consent"

    init(config: TelemetryConfig, adapters: [any TelemetryAdapter], settings: UserDefaults, isDebugBuild: Bool = Telemetry.isDebugBuild,
         appVersion: String = AppVersion.current) {
        self.config = config
        self.adapters = adapters
        self.settings = settings
        sendingAllowed = !isDebugBuild || config.debugOverride
        superProperties = ["platform": .string("ios"), "app_version": .string(appVersion), "build_type": .string(isDebugBuild ? "debug" : "release")]
        let stored = settings.data(forKey: Self.consentKey).flatMap { try? JSONDecoder().decode(TelemetryConsent.self, from: $0) }
        consent = stored?.schema == TelemetryConsent.schemaVersion ? stored! : TelemetryConsent()
        apply()
    }

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Purposes with a configured provider that may send in this build; the UI shows only these.
    var availablePurposes: [TelemetryPurpose] { sendingAllowed ? TelemetryPurpose.allCases.filter(config.configured) : [] }
    /// First run, or a newly configured purpose that was never asked.
    var needsPrompt: Bool { !Set(availablePurposes).isSubset(of: consent.asked) }
    var unaskedPurposes: [TelemetryPurpose] { availablePurposes.filter { !consent.asked.contains($0) } }
    func isGranted(_ purpose: TelemetryPurpose) -> Bool { consent.granted.contains(purpose) }

    /// Record decisions for the given purposes; untouched purposes keep their state.
    func setConsent(_ choices: [TelemetryPurpose: Bool]) {
        var next = consent
        for (purpose, granted) in choices where availablePurposes.contains(purpose) {
            next.asked.insert(purpose)
            if granted { next.granted.insert(purpose) } else { next.granted.remove(purpose) }
        }
        guard next != consent else { return }
        let before = consent.granted
        consent = next
        if let data = try? JSONEncoder().encode(next) { settings.set(data, forKey: Self.consentKey) }
        apply()
        if consent.granted != before {
            track(.consentUpdated(analytics: isGranted(.analytics), replay: isGranted(.replay), diagnostics: isGranted(.diagnostics)))
        }
    }

    func track(_ event: TelemetryEvent) {
        guard !demoActive else { return }
        for adapter in running where adapter.purpose == .analytics { adapter.track(event.name.rawValue, properties: event.properties) }
    }

    func screen(_ screen: TelemetryScreen) {
        guard !demoActive else { return }
        for adapter in running { adapter.screen(screen) }
    }

    /// Sensitive screens nest; replay pauses while any is visible.
    func enterScreen(_ screen: TelemetryScreen) {
        if screen.sensitive { sensitiveScreens += 1; applySensitivity() }
        self.screen(screen)
    }
    func leaveScreen(_ screen: TelemetryScreen) {
        guard screen.sensitive else { return }
        sensitiveScreens = max(0, sensitiveScreens - 1); applySensitivity()
    }

    /// Deployment is the first 12 hex of SHA-256 of the origin; set when a server is connected.
    func setDeployment(_ origin: URL) {
        superProperties["deployment"] = .string(String(Self.sha256(Self.originString(origin)).prefix(12)))
        restartSuperProperties()
    }

    func identify(_ user: TelemetryUser) {
        guard !demoActive, self.user != user else { return }
        self.user = user
        superProperties["role_kind"] = .string(user.roleKind.rawValue)
        restartSuperProperties()
        for adapter in running { adapter.identify(user) }
    }

    func reset() {
        guard user != nil || superProperties["role_kind"] != nil else { return }
        user = nil
        superProperties["role_kind"] = nil
        for adapter in running { adapter.reset() }
    }

    private var running: [any TelemetryAdapter] {
        adapters.filter { started.contains(ObjectIdentifier($0)) }
    }

    /// Start granted adapters and stop withdrawn ones immediately.
    private func apply() {
        for adapter in adapters {
            let id = ObjectIdentifier(adapter)
            let wanted = sendingAllowed && consent.granted.contains(adapter.purpose)
            if wanted && !started.contains(id) {
                adapter.start(superProperties: superProperties)
                started.insert(id)
                if let user, !demoActive { adapter.identify(user) }
            } else if !wanted && started.contains(id) {
                adapter.stop()
                started.remove(id)
            }
        }
        applySensitivity()
    }

    private func applySensitivity() {
        for adapter in running { adapter.setSensitive(demoActive || sensitiveScreens > 0) }
    }

    private func restartSuperProperties() {
        for adapter in running { adapter.setSuperProperties(superProperties) }
    }

    nonisolated static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `scheme://host[:port]`, lowercase, no path or trailing slash (identical on Android).
    nonisolated static func originString(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host?.lowercased() ?? ""
        return scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }
}
