import XCTest
import Foundation
import SpaceWorksAPI
@testable import SpaceWorks

/// Phase 2 (backend 0.12.0): `app_version` + 426, `device_trust` / `X-Device-Trust`, the unusual
/// sign-in email code and resend, social MFA, `session_revoked`, and the blocking username step.
@MainActor final class AuthFlowTests: XCTestCase {
    private let json = ["Content-Type": "application/json"]
    private var calls: [String] = []

    private func state(tokens: TokenPair? = nil, trust: MemoryDeviceTrustStorage = MemoryDeviceTrustStorage(),
                       storage: MemoryTokens? = nil,
                       handler: @escaping (URLRequest) throws -> (Int, String)) -> AuthState {
        calls = []
        StubProtocol.lock.lock()
        StubProtocol.handler = { request in
            self.calls.append("\(request.httpMethod ?? "") \(request.url!.path)")
            for header in ["Cookie", "Origin", "Referer"] { XCTAssertNil(request.value(forHTTPHeaderField: header)) }
            let (status, text) = try handler(request)
            return (status, self.json, Data(text.utf8))
        }
        StubProtocol.lock.unlock()
        let config = DeviceSession.configuration(); config.protocolClasses = [StubProtocol.self]
        return AuthState(origin: try! ServerOrigin("https://spaceworks.example"), session: DeviceSession.make(configuration: config),
            settings: UserDefaults(suiteName: UUID().uuidString)!, storage: storage ?? MemoryTokens(tokens),
            staffStorage: MemoryStaffGrantStorage(), trustStorage: trust, appVersion: "1.4.0",
            attest: { _ in Data(#"{"type":"development"}"#.utf8) })
    }
    override func tearDown() { StubProtocol.lock.lock(); StubProtocol.handler = nil; StubProtocol.lock.unlock() }

    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requestBody(request))) as? [String: Any] ?? [:]
    }
    private func common(_ request: URLRequest) -> (Int, String)? {
        switch request.url!.path {
        case "/api/v1/config": return (200, DebugAuthFixtures.nativeConfig())
        case "/api/v1/auth/device/attestation-challenge": return (200, #"{"challenge":"fresh-challenge","expires_in":120}"#)
        case "/api/v1/auth/me": return (200, DebugAuthFixtures.user)
        case "/api/v1/auth/device/logout": return (200, #"{"detail":"Signed out."}"#)
        default: return nil
        }
    }
    private func tokens(trust: String) -> String {
        "{\"access\":\"test-access\",\"refresh\":\"test-refresh\",\"user\":\(DebugAuthFixtures.user),\"device_grant\":\(DebugAuthFixtures.grant),\"device_trust\":\"\(trust)\"}"
    }
    private func completed(trust: String = "verified-trust") -> String {
        "{\"access\":\"test-access\",\"refresh\":\"test-refresh\",\"device_grant\":\(DebugAuthFixtures.grant),\"surface\":\"member\",\"user\":\(DebugAuthFixtures.user),\"device_trust\":\"\(trust)\"}"
    }

    func testPasswordSignInSendsAppVersionEchoesAndReplacesTheRememberedDevice() async throws {
        let trust = MemoryDeviceTrustStorage("remembered-before")
        let auth = state(trust: trust) { request in
            if request.url!.path == "/api/v1/auth/device/login" {
                XCTAssertEqual(self.body(request)["app_version"] as? String, "1.4.0")
                XCTAssertNil(self.body(request)["authority"], "Password sign-in asks for a member grant")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Trust"), "remembered-before")
                return (200, self.tokens(trust: "remembered-after"))
            }
            if request.url!.path == "/api/v1/auth/me" { XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-Trust"), "Only sign-in routes carry the device value") }
            return try XCTUnwrap(self.common(request))
        }
        await auth.restore(); auth.username = "maker"; auth.password = "password-fixture"
        await auth.signIn()
        XCTAssertEqual(auth.stage, .signedIn)
        XCTAssertEqual(try trust.load(), "remembered-after")
        XCTAssertEqual(auth.service.deviceTrust.current, "remembered-after")
    }

    func testUnusualSignInAsksForTheEmailedCodeResendsAndVerifiesWithEmailFactor() async throws {
        var resends = 0
        let auth = state { request in
            switch request.url!.path {
            case "/api/v1/auth/device/login":
                return (200, #"{"mfa_required":true,"enrollment_required":false,"challenge":"risk-challenge-0000000000000001","expires_in":600,"purpose":"risk","factors":["email_code"]}"#)
            case "/api/v1/auth/login-code/resend":
                resends += 1
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(self.body(request) as? [String: String], ["challenge": "risk-challenge-0000000000000001"])
                return (200, #"{"sent":true,"expires_in":600,"resends_left":1}"#)
            case "/api/v1/auth/mfa/verify":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(self.body(request) as? [String: String], ["challenge": "risk-challenge-0000000000000001", "code": "654321", "factor": "email_code"])
                return (200, self.completed())
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore(); auth.username = "maker"; auth.password = "password-fixture"
        await auth.signIn()
        XCTAssertEqual(auth.stage, .mfa); XCTAssertTrue(auth.emailCodeChallenge)
        await auth.resendLoginCode()
        XCTAssertEqual(resends, 1); XCTAssertEqual(auth.loginCodeResendsLeft, 1)
        XCTAssertEqual(auth.loginCodeNotice, "We sent a new code to your email.")
        auth.code = "12"; await auth.verify()
        XCTAssertEqual(auth.error, "Enter the six-digit code from your email.")
        auth.code = "654321"; await auth.verify()
        XCTAssertEqual(auth.stage, .signedIn)
        XCTAssertEqual(auth.service.deviceTrust.current, "verified-trust")
    }

    func testInvalidEmailCodeShowsServerCopyAndStaysOnTheCodeStep() async {
        let auth = state { request in
            switch request.url!.path {
            case "/api/v1/auth/device/login":
                return (200, #"{"mfa_required":true,"enrollment_required":false,"challenge":"risk-challenge-0000000000000001","expires_in":600,"purpose":"risk","factors":["email_code"]}"#)
            case "/api/v1/auth/mfa/verify": return (400, #"{"detail":"Invalid code.","code":"login_code_invalid"}"#)
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore(); auth.username = "maker"; auth.password = "password-fixture"; await auth.signIn()
        auth.code = "000000"; await auth.verify()
        XCTAssertEqual(auth.stage, .mfa)
        XCTAssertEqual(auth.error, "That code isn't valid. Check your email for the latest code.")
    }

    func testSocialSignInFollowsTheMFAChallengeBranch() async {
        let auth = state { request in
            switch request.url!.path {
            case "/api/v1/auth/social/nonce": return (200, #"{"nonce":"provider-nonce","expires_in":300}"#)
            case "/api/v1/auth/social/google":
                XCTAssertEqual(self.body(request)["app_version"] as? String, "1.4.0")
                return (200, DebugAuthFixtures.mfa)
            case "/api/v1/auth/mfa/verify": return (200, self.completed())
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore()
        await auth.signIn(with: .google) { _ in ProviderCredential(idToken: "google-id-token") }
        XCTAssertEqual(auth.stage, .mfa); XCTAssertFalse(auth.emailCodeChallenge)
        auth.code = "123456"; await auth.verify()
        XCTAssertEqual(auth.stage, .signedIn)
    }

    func testUpdateRequiredAtSignInShowsTheEnforcedMinimum() async {
        let auth = state { request in
            if request.url!.path == "/api/v1/auth/device/login" {
                return (426, #"{"detail":"Update the app.","code":"native_app_update_required","minimum_version":"2.0.0"}"#)
            }
            return try XCTUnwrap(self.common(request))
        }
        await auth.restore(); auth.username = "maker"; auth.password = "password-fixture"; await auth.signIn()
        XCTAssertEqual(auth.stage, .updateRequired)
        XCTAssertEqual(auth.minimumVersion, "2.0.0")
    }

    func testUpdateRequiredAtRefreshKeepsTheStoredSession() async throws {
        let storage = MemoryTokens(TokenPair(access: "old-access", refresh: "old-refresh"))
        let auth = state(storage: storage) { request in
            switch request.url!.path {
            case "/api/v1/auth/me": return (401, #"{"detail":"Expired.","code":"token_not_valid"}"#)
            case "/api/v1/auth/device/refresh":
                XCTAssertEqual(self.body(request) as? [String: String], ["refresh": "old-refresh", "app_version": "1.4.0"])
                return (426, #"{"detail":"Update the app.","code":"native_app_update_required","minimum_version":"1.5.0"}"#)
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(auth.stage, .updateRequired)
        XCTAssertEqual(auth.minimumVersion, "1.5.0")
        XCTAssertEqual(try storage.load(), TokenPair(access: "old-access", refresh: "old-refresh"), "Nothing was rotated, so nothing is cleared")
    }

    func testSessionRevokedSignsOutWithExplicitCopy() async {
        let auth = state(tokens: TokenPair(access: "old-access", refresh: "old-refresh")) { request in
            switch request.url!.path {
            case "/api/v1/auth/me": return (401, #"{"detail":"Expired.","code":"token_not_valid"}"#)
            case "/api/v1/auth/device/refresh": return (401, #"{"detail":"Session revoked.","code":"session_revoked"}"#)
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore()
        XCTAssertEqual(auth.stage, .signIn); XCTAssertNil(auth.user)
        XCTAssertEqual(auth.error, "Your session has ended. Sign in again.")
    }

    func testHandleRequiredBlocksUntilAUsernameIsChosen() async throws {
        var claimed = false
        let auth = state { request in
            switch request.url!.path {
            case "/api/v1/auth/device/login": return (200, DebugAuthFixtures.tokens)
            case "/api/v1/auth/me":
                return (200, claimed ? DebugAuthFixtures.user : DebugAuthFixtures.user(memberships: [DebugAuthFixtures.membership], handle: nil))
            case "/api/v1/handles/check":
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Makerspace-Id"))
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first { $0.name == "handle" }?.value, "maker.one")
                return (200, #"{"handle":"maker.one","available":false,"reason":"taken","suggestion":"maker.two"}"#)
            case "/api/v1/member/profile/handle":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Makerspace-Id"))
                XCTAssertEqual(self.body(request) as? [String: String], ["handle": "maker.two"])
                claimed = true
                return (200, #"{"handle":"maker.two","claimed_at":"2026-11-12T10:00:00Z","changed_at":"2026-11-12T10:00:00Z"}"#)
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore(); auth.username = "maker"; auth.password = "password-fixture"; await auth.signIn()
        XCTAssertEqual(auth.stage, .chooseUsername)
        let form = try XCTUnwrap(auth.usernameForm())
        XCTAssertEqual(form.handle, "maker.one", "The server's suggestion is offered first")
        await form.checkAvailability()
        XCTAssertEqual(form.availability, false); XCTAssertEqual(form.unavailableMessage, "That username is taken.")
        XCTAssertFalse(form.canSubmit)
        form.useSuggestion(); XCTAssertEqual(form.handle, "maker.two"); XCTAssertTrue(form.canSubmit)
        await form.submit()
        XCTAssertEqual(auth.stage, .signedIn); XCTAssertEqual(auth.user?.handle, "maker")
    }

    /// The chain: server config, password sign-in through the risk code, /me, a 401 that refreshes
    /// once, the paged device list, then sign out everywhere (which clears this device).
    func testFullMemberChainFromConfigToSignOutEverywhere() async throws {
        var meCalls = 0
        let auth = state { request in
            switch request.url!.path {
            case "/api/v1/auth/device/login":
                return (200, #"{"mfa_required":true,"enrollment_required":false,"challenge":"risk-challenge-0000000000000001","expires_in":600,"purpose":"risk","factors":["email_code"]}"#)
            case "/api/v1/auth/mfa/verify": return (200, self.completed())
            case "/api/v1/auth/me":
                meCalls += 1
                if meCalls == 2, request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access" { return (401, #"{"detail":"Expired.","code":"token_not_valid"}"#) }
                return (200, DebugAuthFixtures.user)
            case "/api/v1/auth/device/refresh":
                XCTAssertEqual(self.body(request)["app_version"] as? String, "1.4.0")
                return (200, "{\"access\":\"rotated-access\",\"refresh\":\"rotated-refresh\",\"device_grant\":\(DebugAuthFixtures.grant)}")
            case "/api/v1/auth/device/grants": return (200, DebugAccountFixtures.grants)
            case "/api/v1/auth/logout-all": return (200, #"{"web_sessions":1,"devices":2}"#)
            default: return try XCTUnwrap(self.common(request))
            }
        }
        await auth.restore(); XCTAssertEqual(auth.stage, .signIn)
        auth.username = "maker"; auth.password = "password-fixture"; await auth.signIn()
        auth.code = "654321"; await auth.verify(); XCTAssertEqual(auth.stage, .signedIn)
        await auth.foreground(); XCTAssertEqual(auth.stage, .signedIn)
        let rotated = await auth.service.refresh.current(); XCTAssertEqual(rotated, TokenPair(access: "rotated-access", refresh: "rotated-refresh"))
        let account = try XCTUnwrap(auth.accountState(makerspaceID: nil))
        await account.loadGrants()
        XCTAssertEqual(account.grants.count, 2)
        await auth.signOutEverywhere()
        XCTAssertEqual(auth.stage, .signIn); XCTAssertEqual(auth.error, "Signed out on every device and browser.")
        XCTAssertEqual(calls.filter { $0.hasSuffix("/auth/device/refresh") }.count, 1)
    }
}
