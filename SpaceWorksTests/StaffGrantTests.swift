import XCTest
import Foundation
import SpaceWorksAPI
@testable import SpaceWorks

/// Phase 3 (backend 0.12.0): the staff step-up grant coexists with the member grant. Each has its
/// own bearer, refresh and sign-out; staff calls carry the grant's fixed `X-Makerspace-Id`.
@MainActor final class StaffGrantTests: XCTestCase {
    private let json = ["Content-Type": "application/json"]
    private var calls: [(path: String, bearer: String?, makerspace: String?)] = []
    private let memberPair = TokenPair(access: "test-access", refresh: "test-refresh")
    private let staffCompletion = "{\"access\":\"staff-access\",\"refresh\":\"staff-refresh\",\"device_grant\":\(DebugAuthFixtures.staffGrant),\"surface\":\"member\",\"user\":\(DebugAuthFixtures.staffGrantUser)}"

    private func state(member: MemoryTokens, staff: MemoryStaffGrantStorage = MemoryStaffGrantStorage(),
                       handler: @escaping (URLRequest) throws -> (Int, String)?) -> AuthState {
        calls = []
        StubProtocol.lock.lock()
        StubProtocol.handler = { request in
            self.calls.append((request.url!.path, request.value(forHTTPHeaderField: "Authorization"), request.value(forHTTPHeaderField: "X-Makerspace-Id")))
            if let custom = try handler(request) { return (custom.0, self.json, Data(custom.1.utf8)) }
            let bearer = request.value(forHTTPHeaderField: "Authorization")
            let text: String
            switch request.url!.path {
            case "/api/v1/config": text = DebugAuthFixtures.nativeConfig()
            case "/api/v1/auth/device/attestation-challenge": text = #"{"challenge":"fresh-challenge","expires_in":120}"#
            case "/api/v1/auth/me": text = bearer == "Bearer staff-access" ? DebugAuthFixtures.staffGrantUser : DebugAuthFixtures.staffPersonUser
            case "/api/v1/auth/device/staff-grant": text = DebugAuthFixtures.mfa
            case "/api/v1/auth/mfa/verify": text = self.staffCompletion
            case "/api/v1/auth/device/logout": text = #"{"detail":"Signed out."}"#
            case "/api/v1/admin/makerspace/7/pending-requests": text = #"{"count":1,"next":null,"previous":null,"results":["# + DebugStaffFixtures.request + "]}"
            default: XCTFail("Unexpected \(request.url!.path)"); text = "{}"
            }
            return (200, self.json, Data(text.utf8))
        }
        StubProtocol.lock.unlock()
        let config = DeviceSession.configuration(); config.protocolClasses = [StubProtocol.self]
        return AuthState(origin: try! ServerOrigin("https://spaceworks.example"), session: DeviceSession.make(configuration: config),
            settings: UserDefaults(suiteName: UUID().uuidString)!, storage: member, staffStorage: staff,
            trustStorage: MemoryDeviceTrustStorage(), appVersion: "1.4.0", attest: { _ in Data(#"{"type":"development"}"#.utf8) })
    }
    override func tearDown() { StubProtocol.lock.lock(); StubProtocol.handler = nil; StubProtocol.lock.unlock() }
    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requestBody(request))) as? [String: Any] ?? [:]
    }

    private func steppedUp(_ auth: AuthState) async {
        await auth.restore(); await auth.select(7)
        XCTAssertTrue(auth.canOfferStaffStepUp); XCTAssertFalse(auth.staffToolsAvailable)
        auth.staff.slug = "demo-workshop"
        await auth.staff.begin(); XCTAssertEqual(auth.staff.step, .mfa)
        auth.staff.code = "123456"; await auth.staff.verify()
    }

    func testStepUpCreatesASecondGrantForOneMakerspaceAndKeepsTheMemberGrant() async throws {
        let member = MemoryTokens(memberPair), staff = MemoryStaffGrantStorage()
        let auth = state(member: member, staff: staff) { request in
            switch request.url!.path {
            case "/api/v1/auth/device/staff-grant":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access", "The step-up starts from the member session")
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Makerspace-Id"))
                let body = self.body(request)
                XCTAssertEqual(body["makerspace"] as? String, "demo-workshop"); XCTAssertEqual(body["challenge"] as? String, "fresh-challenge")
                XCTAssertEqual(body["app_version"] as? String, "1.4.0")
                XCTAssertEqual((body["attestation"] as? [String: String])?["type"], "development")
                return nil
            case "/api/v1/auth/mfa/verify":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "MFA completes without the Authorization header")
                return nil
            default: return nil
            }
        }
        await steppedUp(auth)
        XCTAssertEqual(auth.staff.step, .idle); XCTAssertEqual(auth.staff.target?.id, 7)
        XCTAssertTrue(auth.staffToolsAvailable)
        XCTAssertEqual(auth.staff.actions(for: 7)?.contains("issue_request"), true)
        XCTAssertNil(auth.staff.actions(for: 8), "Staff authority is fixed to the grant's makerspace")
        XCTAssertEqual(try member.load(), memberPair, "The member grant is kept")
        XCTAssertEqual(try staff.load(), StaffGrantRecord(pair: TokenPair(access: "staff-access", refresh: "staff-refresh"), makerspaceID: 7, makerspaceSlug: "demo-workshop"))
        let staffMe = try XCTUnwrap(calls.last { $0.path == "/api/v1/auth/me" })
        XCTAssertEqual(staffMe.bearer, "Bearer staff-access"); XCTAssertNil(staffMe.makerspace)
        await auth.select(8); XCTAssertFalse(auth.staffToolsAvailable)
    }

    func testStaffCallsUseTheStaffBearerAndTheGrantsMakerspace() async throws {
        let auth = state(member: MemoryTokens(memberPair)) { _ in nil }
        await steppedUp(auth)
        let repository = LiveStaffRepository(service: auth.service, expectedCredentials: auth.staff.credentials, makerspaceID: 7,
                                             origin: try ServerOrigin("https://spaceworks.example"))
        let page = try await repository.requests(queue: .pending, page: 1)
        XCTAssertEqual(page.results.count, 1)
        let call = try XCTUnwrap(calls.last)
        XCTAssertEqual(call.path, "/api/v1/admin/makerspace/7/pending-requests")
        XCTAssertEqual(call.bearer, "Bearer staff-access"); XCTAssertEqual(call.makerspace, "7")
        let other = LiveStaffRepository(service: auth.service, expectedCredentials: auth.staff.credentials, makerspaceID: 8,
                                        origin: try ServerOrigin("https://spaceworks.example"))
        do { _ = try await other.requests(queue: .pending, page: 1); XCTFail("Another makerspace must not use this staff grant") }
        catch { XCTAssertEqual(APIError.code(error), "staff_grant_missing") }
    }

    func testStaffGrantRefreshesOnItsOwnWithoutTouchingTheMemberPair() async throws {
        let member = MemoryTokens(memberPair)
        var expired = true
        let auth = state(member: member) { request in
            switch request.url!.path {
            case "/api/v1/admin/makerspace/7/pending-requests" where expired:
                expired = false; return (401, #"{"detail":"Expired.","code":"token_not_valid"}"#)
            case "/api/v1/auth/device/refresh":
                XCTAssertEqual(self.body(request) as? [String: String], ["refresh": "staff-refresh", "app_version": "1.4.0"])
                return (200, "{\"access\":\"staff-access-2\",\"refresh\":\"staff-refresh-2\",\"device_grant\":\(DebugAuthFixtures.staffGrant)}")
            default: return nil
            }
        }
        await steppedUp(auth)
        let repository = LiveStaffRepository(service: auth.service, expectedCredentials: auth.staff.credentials, makerspaceID: 7,
                                             origin: try ServerOrigin("https://spaceworks.example"))
        _ = try await repository.requests(queue: .pending, page: 1)
        XCTAssertEqual(calls.last?.bearer, "Bearer staff-access-2")
        let staffPair = await auth.service.staffRefresh.current(); XCTAssertEqual(staffPair, TokenPair(access: "staff-access-2", refresh: "staff-refresh-2"))
        XCTAssertEqual(try member.load(), memberPair)
    }

    func testStepUpAndLeavingAreTrackedWithoutIdentifiers() async throws {
        let previous = Telemetry.shared; defer { Telemetry.shared = previous }
        let recorder = RecordingTelemetryAdapter(.analytics)
        let telemetry = Telemetry(config: TelemetryConfig(info: ["posthog_api_key": "phc_test0123456789"], firebasePlistPresent: false), adapters: [recorder],
                                  settings: UserDefaults(suiteName: UUID().uuidString)!, isDebugBuild: false, appVersion: "1.0")
        telemetry.setConsent([.analytics: true]); Telemetry.shared = telemetry
        let auth = state(member: MemoryTokens(memberPair)) { _ in nil }
        await steppedUp(auth)
        let names = recorder.events.map(\.0)
        XCTAssertTrue(names.contains("staff_step_up_started")); XCTAssertTrue(names.contains("staff_step_up_succeeded"))
        XCTAssertTrue(recorder.events.allSatisfy { event in !event.1.values.contains { "\($0)".contains("demo-workshop") } })
        await auth.staff.end()
        XCTAssertEqual(recorder.events.last?.0, "staff_signed_out")
    }

    func testLosingTheStaffGrantDropsOnlyStaffTools() async throws {
        var revoked = false
        let auth = state(member: MemoryTokens(memberPair)) { request in
            guard revoked else { return nil }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer staff-access" { return (401, #"{"detail":"Revoked.","code":"token_not_valid"}"#) }
            if request.url!.path == "/api/v1/auth/device/refresh" { return (401, #"{"detail":"Revoked.","code":"session_revoked"}"#) }
            return nil
        }
        await steppedUp(auth); XCTAssertTrue(auth.staffToolsAvailable)
        revoked = true
        await auth.foreground()
        XCTAssertEqual(auth.stage, .signedIn, "The member session continues")
        XCTAssertFalse(auth.staffToolsAvailable); XCTAssertNil(auth.staff.target)
        let staffPair = await auth.service.staffRefresh.current(); XCTAssertNil(staffPair)
        let memberCurrent = await auth.service.refresh.current(); XCTAssertEqual(memberCurrent, memberPair)
    }

    func testLeavingStaffToolsSignsOutTheStaffGrantOnly() async throws {
        let staff = MemoryStaffGrantStorage()
        let auth = state(member: MemoryTokens(memberPair), staff: staff) { _ in nil }
        await steppedUp(auth)
        await auth.staff.end()
        let logout = try XCTUnwrap(calls.last { $0.path == "/api/v1/auth/device/logout" })
        XCTAssertEqual(logout.bearer, "Bearer staff-access")
        XCTAssertNil(try staff.load()); XCTAssertFalse(auth.staffToolsAvailable)
        XCTAssertEqual(auth.stage, .signedIn)
        let memberCurrent = await auth.service.refresh.current(); XCTAssertEqual(memberCurrent, memberPair)
    }

    func testSigningOutEndsTheStaffGrantThenTheMemberGrant() async throws {
        let member = MemoryTokens(memberPair), staff = MemoryStaffGrantStorage()
        let auth = state(member: member, staff: staff) { _ in nil }
        await steppedUp(auth)
        await auth.signOut()
        let logouts = calls.filter { $0.path == "/api/v1/auth/device/logout" }.map(\.bearer)
        XCTAssertEqual(logouts, ["Bearer staff-access", "Bearer test-access"])
        XCTAssertNil(try staff.load()); XCTAssertNil(try member.load()); XCTAssertEqual(auth.stage, .signIn)
    }

    func testStoredStaffGrantResumesAfterLaunch() async throws {
        let staff = MemoryStaffGrantStorage(.init(pair: TokenPair(access: "staff-access", refresh: "staff-refresh"), makerspaceID: 7, makerspaceSlug: "demo-workshop"))
        let auth = state(member: MemoryTokens(memberPair), staff: staff) { _ in nil }
        await auth.restore(); await auth.select(7)
        XCTAssertTrue(auth.staffToolsAvailable)
    }

    func testNoStaffRoleThereShowsServerRefusal() async {
        let auth = state(member: MemoryTokens(memberPair)) { request in
            request.url!.path == "/api/v1/auth/device/staff-grant"
                ? (403, #"{"detail":"You do not hold a staff role in that makerspace.","code":"staff_access_required"}"#) : nil
        }
        await auth.restore(); await auth.select(7)
        auth.staff.slug = "community-lab"; await auth.staff.begin()
        XCTAssertEqual(auth.staff.step, .idle)
        XCTAssertEqual(auth.staff.error, "You don't have a staff role in that makerspace.")
        XCTAssertEqual(auth.stage, .signedIn)
    }

    func testStaffAuthorityPasswordLoginSendsAuthorityAndMakerspace() async throws {
        let auth = state(member: MemoryTokens()) { request in
            guard request.url!.path == "/api/v1/auth/device/login" else { return nil }
            let body = self.body(request)
            XCTAssertEqual(body["authority"] as? String, "staff"); XCTAssertEqual(body["makerspace"] as? String, "demo-workshop")
            XCTAssertEqual(body["app_version"] as? String, "1.4.0")
            return (200, DebugAuthFixtures.mfa)
        }
        let result = try await auth.service.signIn(appID: "org.spaceworks.app", development: true, username: "maker", password: "pw",
                                                   challenge: "fresh-challenge", attestationJSON: Data(#"{"type":"development"}"#.utf8),
                                                   staffMakerspace: "demo-workshop")
        guard case .MFAChallengeResponse = result else { return XCTFail("A staff login always answers with an MFA challenge") }
    }
}
