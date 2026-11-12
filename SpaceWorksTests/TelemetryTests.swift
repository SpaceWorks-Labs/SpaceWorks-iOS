import XCTest
@testable import SpaceWorks

/// Recording fake provider: every SDK call the facade makes is captured, nothing leaves the process.
@MainActor final class RecordingTelemetryAdapter: TelemetryAdapter {
    let purpose: TelemetryPurpose
    private(set) var calls: [String] = []
    private(set) var events: [(String, [String: TelemetryValue])] = []
    private(set) var sensitive = false
    init(_ purpose: TelemetryPurpose) { self.purpose = purpose }
    func start(superProperties: [String: TelemetryValue]) { calls.append("start") }
    func stop() { calls.append("stop") }
    func track(_ name: String, properties: [String: TelemetryValue]) { events.append((name, properties)) }
    func screen(_ screen: TelemetryScreen) { calls.append("screen:\(screen.rawValue)") }
    func identify(_ user: TelemetryUser) { calls.append("identify:\(user.pseudonymousID)") }
    func reset() { calls.append("reset") }
    func setSensitive(_ sensitive: Bool) { self.sensitive = sensitive }
}

@MainActor final class TelemetryTests: XCTestCase {
    private var settings: UserDefaults!
    private let configured = TelemetryConfig(info: ["sentry_dsn": "https://0123456789abcdef0123456789abcdef@o1.ingest.sentry.io/42",
                                                    "posthog_api_key": "phc_test0123456789", "clarity_project_id": "abc123xyz"],
                                             firebasePlistPresent: true)
    private var previous: Telemetry!

    override func setUp() async throws {
        settings = UserDefaults(suiteName: "telemetry-tests-\(UUID().uuidString)")
        previous = Telemetry.shared
    }
    override func tearDown() async throws { Telemetry.shared = previous }

    private func hub(_ adapters: [RecordingTelemetryAdapter], config: TelemetryConfig? = nil, debug: Bool = false) -> Telemetry {
        Telemetry(config: config ?? configured, adapters: adapters, settings: settings, isDebugBuild: debug, appVersion: "1.0")
    }

    func testNoProviderStartsBeforeConsentAndOnlyTheGrantedPurposeStarts() {
        let analytics = RecordingTelemetryAdapter(.analytics), replay = RecordingTelemetryAdapter(.replay), diagnostics = RecordingTelemetryAdapter(.diagnostics)
        let telemetry = hub([analytics, replay, diagnostics])
        telemetry.track(.appOpen); telemetry.screen(.home)
        XCTAssertTrue(analytics.calls.isEmpty && replay.calls.isEmpty && diagnostics.calls.isEmpty)
        XCTAssertTrue(analytics.events.isEmpty)
        XCTAssertTrue(telemetry.needsPrompt)
        telemetry.setConsent([.diagnostics: true, .analytics: false, .replay: false])
        XCTAssertEqual(diagnostics.calls, ["start"])
        XCTAssertTrue(analytics.calls.isEmpty && replay.calls.isEmpty)
        XCTAssertFalse(telemetry.needsPrompt)
    }

    func testWithdrawalStopsImmediatelyAndGrantRestartsWithoutRelaunch() {
        let analytics = RecordingTelemetryAdapter(.analytics)
        let telemetry = hub([analytics])
        telemetry.setConsent([.analytics: true])
        XCTAssertEqual(analytics.events.map(\.0), ["consent_updated"])
        telemetry.setConsent([.analytics: false])
        XCTAssertEqual(analytics.calls, ["start", "stop"])
        telemetry.track(.bookingCreated)
        XCTAssertFalse(analytics.events.map(\.0).contains("booking_created"))
        telemetry.setConsent([.analytics: true])
        XCTAssertEqual(analytics.calls, ["start", "stop", "start"])
    }

    func testConsentIsPersistedPerInstallAndReasksOnlyNewlyConfiguredPurposes() {
        let only = TelemetryConfig(info: ["sentry_dsn": "https://0123456789abcdef0123456789abcdef@o1.ingest.sentry.io/42"], firebasePlistPresent: false)
        hub([], config: only).setConsent([.diagnostics: true])
        let reopened = hub([], config: only)
        XCTAssertTrue(reopened.isGranted(.diagnostics))
        XCTAssertFalse(reopened.needsPrompt)
        let expanded = hub([], config: configured)
        XCTAssertTrue(expanded.needsPrompt)
        XCTAssertEqual(expanded.unaskedPurposes, [.analytics, .replay])
        XCTAssertTrue(expanded.isGranted(.diagnostics))
    }

    func testAbsentConfigurationIsANoOpAndHidesTheUI() {
        let telemetry = hub([], config: TelemetryConfig(info: nil, firebasePlistPresent: false))
        XCTAssertEqual(telemetry.availablePurposes, [])
        XCTAssertFalse(telemetry.needsPrompt)
        telemetry.setConsent([.analytics: true])
        XCTAssertFalse(telemetry.isGranted(.analytics), "An unconfigured purpose cannot be granted")
        XCTAssertEqual(TelemetryConfig.bundled.configured(.replay), false, "The repository ships no provider identifiers")
    }

    func testDebugBuildsSendNothingWithoutTheOverride() {
        let analytics = RecordingTelemetryAdapter(.analytics)
        let telemetry = hub([analytics], debug: true)
        XCTAssertEqual(telemetry.availablePurposes, [])
        telemetry.setConsent([.analytics: true])
        XCTAssertTrue(analytics.calls.isEmpty)
        var override = configured; override.debugOverride = true
        let enabled = hub([analytics], config: override, debug: true)
        enabled.setConsent([.analytics: true])
        XCTAssertEqual(analytics.calls, ["start"])
    }

    func testDemoModeSendsNothingAndPausesReplay() {
        let analytics = RecordingTelemetryAdapter(.analytics), replay = RecordingTelemetryAdapter(.replay)
        let telemetry = hub([analytics, replay])
        telemetry.setConsent([.analytics: true, .replay: true])
        let before = analytics.events.count
        telemetry.demoActive = true
        telemetry.track(.bookingCreated); telemetry.enterScreen(.home)
        telemetry.identify(TelemetryUser(origin: URL(string: "https://lab.example")!, userID: 7, roleKind: .member))
        XCTAssertEqual(analytics.events.count, before)
        XCTAssertFalse(analytics.calls.contains { $0.hasPrefix("screen") || $0.hasPrefix("identify") })
        XCTAssertTrue(replay.sensitive)
    }

    func testSensitiveScreensPauseReplayUntilEveryOneIsLeft() {
        let replay = RecordingTelemetryAdapter(.replay)
        let telemetry = hub([replay])
        telemetry.setConsent([.replay: true])
        telemetry.enterScreen(.home); XCTAssertFalse(replay.sensitive)
        telemetry.enterScreen(.payments); telemetry.enterScreen(.payment_detail); XCTAssertTrue(replay.sensitive)
        telemetry.leaveScreen(.payment_detail); XCTAssertTrue(replay.sensitive)
        telemetry.leaveScreen(.payments); XCTAssertFalse(replay.sensitive)
        for screen in [TelemetryScreen.sign_in, .mfa, .phone_sign_in, .password_change, .account_deletion, .payment_detail, .staff_scan, .staff_evidence, .membership_card, .event_ticket] {
            XCTAssertTrue(screen.sensitive, screen.rawValue)
        }
    }

    func testPseudonymousIdentityIsAStableHashNeverTheRawIDAndIsClearedOnReset() {
        let user = TelemetryUser(origin: URL(string: "HTTPS://Lab.Example/")!, userID: 42, roleKind: .staff)
        XCTAssertEqual(user.pseudonymousID, Telemetry.sha256("https://lab.example|42"))
        XCTAssertEqual(user.pseudonymousID, TelemetryUser(origin: URL(string: "https://lab.example")!, userID: 42, roleKind: .member).pseudonymousID)
        XCTAssertEqual(user.pseudonymousID.count, 64)
        XCTAssertNotEqual(user.pseudonymousID, "42")
        XCTAssertNotEqual(user.pseudonymousID, TelemetryUser(origin: URL(string: "https://other.example")!, userID: 42, roleKind: .staff).pseudonymousID)
        let analytics = RecordingTelemetryAdapter(.analytics)
        let telemetry = hub([analytics])
        telemetry.identify(user)
        telemetry.setConsent([.analytics: true])
        XCTAssertEqual(analytics.calls, ["start", "identify:\(user.pseudonymousID)"], "A later grant identifies the signed-in person")
        telemetry.reset()
        XCTAssertEqual(analytics.calls.last, "reset")
    }

    func testEventNamesAreUniqueValidAndMatchTheSharedSpec() {
        let spec = ["app_open", "screen_view", "onboarding_completed", "server_connected", "sign_in_started", "sign_in_succeeded", "sign_in_failed",
                    "mfa_challenge_shown", "sign_up_started", "sign_up_completed", "password_reset_requested", "sign_out", "makerspace_switched",
                    "inventory_searched", "hardware_request_submitted", "loan_renewed", "booking_created", "booking_cancelled", "event_registered",
                    "event_registration_cancelled", "ticket_opened", "payment_started", "payment_finished", "receipt_downloaded",
                    "push_permission_result", "push_opened", "deep_link_opened", "staff_request_decided", "staff_item_issued", "staff_item_returned",
                    "staff_direct_handout", "qr_scanned", "event_check_in", "account_deletion_started", "account_deletion_completed", "consent_updated"]
        let names = TelemetryEvent.Name.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(names), Set(spec))
        let valid = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{0,39}$")
        for name in names + TelemetryScreen.allCases.map(\.rawValue) {
            XCTAssertNotNil(valid.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), name)
        }
        XCTAssertEqual(TelemetryEvent.signInFailed(.google, code: "4xx").properties, ["method": .string("google"), "code": .string("4xx")])
        XCTAssertEqual(TelemetryEvent.hardwareRequestSubmitted(itemCount: 3).properties, ["item_count": .int(3)])
    }

    func testScrubberRemovesHeadersQueriesAndIdentifiers() {
        XCTAssertEqual(TelemetryScrubber.url("https://user:pw@lab.example/api/v1/member/makerspaces/7/inventory/123?search=drill#top"),
                       "https://lab.example/api/v1/member/makerspaces/{id}/inventory/{id}")
        XCTAssertEqual(TelemetryScrubber.path("GET /api/v1/bookings/0f8fad5b-d9cb-469f-a165-70867728950e/cancel?x=1"),
                       "GET /api/v1/bookings/{id}/cancel")
        XCTAssertEqual(TelemetryScrubber.path("/spaces/a1B2c3D4e5F6g7H8i9/book"), "/spaces/{id}/book")
        XCTAssertEqual(TelemetryScrubber.headers(["Authorization": "Bearer t", "Cookie": "c", "X-Makerspace-Id": "7", "Accept": "json"]), ["Accept": "json"])
        let data = TelemetryScrubber.data(["url": "https://lab.example/items/9?q=1", "http.query": "q=1", "method": "GET", "request_body": "secret"])
        XCTAssertEqual(data["url"] as? String, "https://lab.example/items/{id}")
        XCTAssertEqual(data["method"] as? String, "GET")
        XCTAssertNil(data["http.query"]); XCTAssertNil(data["request_body"])
    }

    func testServerConnectionRecordsLockedFlagAtTheConfirmedSuccessPoint() async {
        let analytics = RecordingTelemetryAdapter(.analytics)
        Telemetry.shared = hub([analytics])
        Telemetry.shared.setConsent([.analytics: true])
        let state = AppState(lockedServer: nil, settings: settings, health: { _ in })
        state.serverInput = "https://lab.example"
        await state.connect()
        XCTAssertEqual(analytics.events.last?.0, "server_connected")
        XCTAssertEqual(analytics.events.last?.1, ["locked": .bool(false)])
    }
}
