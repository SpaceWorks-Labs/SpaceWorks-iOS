import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// A deployment origin, never an API path or a URL with embedded credentials.
public struct ServerOrigin: Sendable, Equatable {
    public let url: URL
    public init(_ input: String, allowLocalHTTP: Bool = false) throws {
        #if DEBUG
        let localHTTP = allowLocalHTTP
        #else
        let localHTTP = false
        #endif
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "https" || (localHTTP && parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { throw APIError(status: 0, code: "invalid_server_url", detail: APILocalCopy.text("Enter a valid HTTPS server URL.")) }
        parts.path = ""
        guard let url = parts.url else { throw URLError(.badURL) }
        self.url = url
    }

    /// Pagination must retain the deployment origin and API namespace before any auth is sent.
    public func nextPage(_ next: String?) throws -> URL? {
        guard let next else { return nil }
        guard let candidate = URL(string: next, relativeTo: url)?.absoluteURL,
              let parts = URLComponents(url: candidate, resolvingAgainstBaseURL: true),
              candidate.scheme == url.scheme, candidate.host == url.host,
              (candidate.port ?? (candidate.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80)),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              candidate.path.hasPrefix("/api/"),
              !(parts.percentEncodedPath.removingPercentEncoding ?? "").split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw APIError(status: 0, code: "invalid_next_page", detail: APILocalCopy.text("The server returned an invalid next page.")) }
        return candidate
    }
}

public struct APIError: Error, LocalizedError, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let detail: String
    public let retryAfter: Date?
    /// 426 `native_app_update_required` carries the enforced minimum (`minimum_version`).
    public let minimumVersion: String?
    public init(status: Int, code: String, detail: String, retryAfter: Date? = nil, minimumVersion: String? = nil) {
        self.status = status; self.code = code; self.detail = detail; self.retryAfter = retryAfter; self.minimumVersion = minimumVersion
    }
    public var errorDescription: String? {
        switch code {
        case "device_superadmin_not_supported": return APILocalCopy.text("Use the web console")
        case "session_revoked": return APILocalCopy.text("Your session has ended. Sign in again.")
        case "native_app_update_required": return APILocalCopy.text("Update the app to continue.")
        case "staff_access_required": return APILocalCopy.text("You don't have a staff role in that makerspace.")
        case "login_code_invalid": return APILocalCopy.text("That code isn't valid. Check your email for the latest code.")
        case "handle_required": return APILocalCopy.text("Choose a username to continue.")
        case "payment_rail_conflict": return APILocalCopy.text("Finish this payment on the web.")
        case "payments_unavailable": return APILocalCopy.text("Online payment is unavailable. Try again later or pay at the desk.")
        default: return detail
        }
    }

    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        if let error = error as? ClientError { return isCancellation(error.underlyingError) }
        return false
    }

    public static func display(_ error: Error) -> String {
        if let error = error as? APIError { return error.errorDescription ?? error.detail }
        if let error = error as? ClientError { return display(error.underlyingError) }
        return APILocalCopy.text("Couldn't connect. Try again.")
    }
    public static func retryDeadline(_ error: Error) -> Date? {
        if let error = error as? APIError { return error.retryAfter }
        if let error = error as? ClientError { return retryDeadline(error.underlyingError) }
        return nil
    }
    public static func status(_ error: Error) -> Int? {
        if let error = error as? APIError { return error.status }
        if let error = error as? ClientError { return status(error.underlyingError) }
        return nil
    }
    public static func code(_ error: Error) -> String? {
        if let error = error as? APIError { return error.code }
        if let error = error as? ClientError { return code(error.underlyingError) }
        return nil
    }
    public static func apiError(_ error: Error) -> APIError? {
        if let error = error as? APIError { return error }
        if let error = error as? ClientError { return apiError(error.underlyingError) }
        return nil
    }
    /// PRD §7: 426 `native_app_update_required` at device login, the staff step-up and refresh.
    public static func isUpdateRequired(_ error: Error) -> Bool {
        guard let error = apiError(error) else { return false }
        return error.status == 426 || error.code == "native_app_update_required"
    }
}

/// Session-wide outcomes any operation can surface. AuthState observes them; nothing else does.
public final class SessionSignals: @unchecked Sendable {
    public enum Signal: Sendable, Equatable { case updateRequired(minimumVersion: String?) }
    private let lock = NSLock()
    private var handler: (@Sendable (Signal) -> Void)?
    public init() {}
    public func observe(_ handler: (@Sendable (Signal) -> Void)?) { lock.withLock { self.handler = handler } }
    func emit(_ error: Error) {
        guard APIError.isUpdateRequired(error) else { return }
        let handler = lock.withLock { self.handler }
        handler?(.updateRequired(minimumVersion: APIError.apiError(error)?.minimumVersion))
    }
}

/// The remembered-device value, read by the sign-in middleware and replaced when a sign-in completes.
public final class DeviceTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let storage: (any DeviceTrustStorage)?
    public init(storage: (any DeviceTrustStorage)?) {
        self.storage = storage
        value = try? storage?.load()
    }
    public var current: String? { lock.withLock { value } }
    /// A completed sign-in returns `device_trust`; an absent value keeps the remembered one.
    public func remember(_ token: String?) {
        guard let token, !token.isEmpty, token.utf8.count <= 512 else { return }
        lock.withLock { value = token }
        try? storage?.store(token)
    }
    /// Operations the unusual-sign-in check reads `X-Device-Trust` on (PRD §7, `device_memory.py`).
    static let operations: Set<String> = [
        "api_v1_auth_device_login_create", "api_v1_auth_social_google_create", "api_v1_auth_social_apple_create",
        "api_v1_auth_social_oidc_create", "api_v1_auth_phone_login_confirm_create", "api_v1_auth_mfa_verify_create",
        "api_v1_auth_mfa_confirm_create", "api_v1_auth_device_staff_grant_create", "api_v1_auth_login_code_resend_create"]
}

struct DeviceTrustMiddleware: ClientMiddleware {
    let trust: DeviceTrust
    func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        let name = HTTPField.Name("X-Device-Trust")!
        request.headerFields[name] = DeviceTrust.operations.contains(operationID) ? trust.current : nil
        return try await next(request, body, baseURL)
    }
}

/// 0.12.0 `DeviceAttestationPayload` is an `anyOf` with one typed branch per proof. PRD §7: send
/// App Attest through its own `app_attest` branch and development through `development`, never the
/// open verifier branch (used only for an unrecognised deployment-specific proof).
public enum DeviceAttestation {
    public static func payload(_ json: Data) throws -> Components.Schemas.DeviceAttestationPayload {
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "app_attest":
            guard let keyID = (object["key_id"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let attestation = (object["attestation"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                throw APIError(status: 0, code: "attestation_invalid", detail: APILocalCopy.text("This device could not prove the app's integrity. Try again."))
            }
            return .init(value2: .init(_type: .app_attest, key_id: .init(keyID), attestation: .init(attestation)))
        case "development" where object.count == 1:
            return .init(value3: .init(_type: .development))
        default:
            return .init(value4: try JSONDecoder().decode(OpenAPIObjectContainer.self, from: json))
        }
    }
}

/// Local credentials, not a hand-written API payload. Persist together in Keychain in A1.
public struct TokenPair: Sendable, Equatable, Codable {
    public let access: String
    public let refresh: String
    public init(access: String, refresh: String) { self.access = access; self.refresh = refresh }
}

/// Credentials and installation epoch are captured atomically for each request.
public struct CredentialSnapshot: Sendable {
    public let pair: TokenPair?
    let epoch: Int
    /// The coordinator that issued it: a member snapshot never validates against the staff grant.
    let owner: ObjectIdentifier
}

/// Late 401s may reuse a rotated pair only within the same installed session.
public actor RefreshCoordinator {
    private var pair: TokenPair?
    private var flight: Task<TokenPair, Error>?
    private let rotate: @Sendable (String) async throws -> TokenPair
    private let persist: @Sendable (TokenPair?) throws -> Void
    private var generation = 0
    public init(pair: TokenPair? = nil, persist: @escaping @Sendable (TokenPair?) throws -> Void = { _ in },
                rotate: @escaping @Sendable (String) async throws -> TokenPair) {
        self.pair = pair; self.rotate = rotate; self.persist = persist
    }
    public func current() -> TokenPair? { pair }
    public func snapshot() -> CredentialSnapshot { CredentialSnapshot(pair: pair, epoch: generation, owner: ObjectIdentifier(self)) }
    public func isCurrent(_ snapshot: CredentialSnapshot) -> Bool { generation == snapshot.epoch && pair != nil }
    public func isSameInstallation(_ snapshot: CredentialSnapshot) -> Bool { snapshot.owner == ObjectIdentifier(self) && generation == snapshot.epoch }
    public func install(_ value: TokenPair?) throws {
        generation += 1
        flight?.cancel()
        flight = nil
        pair = nil
        try persist(value)
        pair = value
    }
    public func recover(rejected snapshot: CredentialSnapshot) async throws -> TokenPair {
        guard generation == snapshot.epoch, let rejectedAccess = snapshot.pair?.access else { throw CancellationError() }
        guard let current = pair else { throw APIError(status: 401, code: "signed_out", detail: APILocalCopy.text("Sign in to continue.")) }
        if current.access != rejectedAccess { return current }
        if let flight { return try await flight.value }
        let rotate = self.rotate
        let generation = self.generation
        let task = Task {
            do {
                let updated = try await rotate(current.refresh)
                guard self.generation == generation else { throw CancellationError() }
                try self.persist(updated)
                guard self.generation == generation else { throw CancellationError() }
                self.commit(updated)
                return updated
            } catch {
                if self.generation == generation {
                    if APIError.isUpdateRequired(error) {
                        // 426: nothing was rotated. Keep the pair so the updated app resumes this session.
                        self.flight = nil
                    } else {
                        self.commit(nil)
                        try? self.persist(nil)
                    }
                }
                throw error
            }
        }
        flight = task
        return try await task.value
    }
    private func commit(_ value: TokenPair?) {
        // Atomic pair replacement completes inside the shared task before any waiter can retry.
        pair = value
        flight = nil
    }
}

public actor MakerspaceContext {
    private var selected: Int?
    private var activeDirectMemberships = Set<Int>()
    public init() {}
    public func current() -> Int? { selected }
    fileprivate func authorizesPush(_ id: Int) -> Bool { activeDirectMemberships.contains(id) }
    /// A1 supplies active membership IDs from the generated /auth/me response.
    public func select(_ id: Int?, activeMemberships: Set<Int>) throws {
        guard id == nil || activeMemberships.contains(id!) else {
            throw APIError(status: 403, code: "inactive_membership", detail: APILocalCopy.text("Select an active makerspace membership."))
        }
        activeDirectMemberships = activeMemberships
        selected = id
    }
}

func checked(_ result: (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
    let (response, body) = result
    guard response.status.code >= 300 else { return result }
    let data = try await body.mapAsync { try await Data(collecting: $0, upTo: 1_048_576) }
    let envelope = data.flatMap { try? JSONDecoder().decode(Components.Schemas.HardwareRequestError.self, from: $0) }
    // Framework/validation errors have intentionally variable shapes (§7); retain dynamic JSON rather than inventing API models.
    let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let code = envelope?.code ?? object?["code"] as? String
    let detail = envelope?.detail ?? object?["detail"] as? String
    let minimumVersion = (object?["minimum_version"] as? String).flatMap { $0.count <= 32 ? $0 : nil }
    var fieldMessages: [String] = []
    func collect(_ value: Any, path: String, depth: Int) {
        guard depth <= 8, fieldMessages.count < 50 else { return }
        if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldMessages.append("\(path): \(text.prefix(1000))")
        } else if let strings = value as? [String], !strings.isEmpty {
            fieldMessages.append("\(path): \(strings.joined(separator: " ").prefix(1000))")
        } else if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() { collect(dictionary[key]!, path: path.isEmpty ? key : path + "." + key, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for (index, item) in array.prefix(50).enumerated() { collect(item, path: path + "." + String(index), depth: depth + 1) }
        }
    }
    for key in object?.keys.sorted() ?? [] where !["detail", "code"].contains(key) { collect(object![key]!, path: key, depth: 0) }
    let fields = fieldMessages.joined(separator: "\n")
    var retry: Date?
    if let header = response.headerFields[.retryAfter] {
        if let seconds = TimeInterval(header), seconds.isFinite { retry = Date().addingTimeInterval(max(0, seconds)) }
        else {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            retry = format.date(from: header)
        }
    }
    if response.status.code == 429, retry == nil { retry = Date().addingTimeInterval(60) }
    let fallback: String
    switch response.status.code {
    case 400: fallback = APILocalCopy.text("Check the details and try again.")
    case 401: fallback = APILocalCopy.text("Please sign in again.")
    case 403: fallback = APILocalCopy.text("You do not have permission to do this.")
    case 404: fallback = APILocalCopy.text("This item wasn't found.")
    case 409: fallback = APILocalCopy.text("This changed. Refresh and try again.")
    case 426: fallback = APILocalCopy.text("Update the app to continue.")
    case 429: fallback = APILocalCopy.text("Too many requests. Try again later.")
    case 503: fallback = APILocalCopy.text("The server is unavailable. Try again later.")
    default: fallback = APILocalCopy.text("Couldn't connect. Try again.")
    }
    let message: String
    if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = detail }
    else if response.status.code == 400, !fields.isEmpty { message = fields }
    else { message = fallback }
    throw APIError(status: response.status.code, code: code ?? (response.status.code == 426 ? "native_app_update_required" : "http_\(response.status.code)"),
                   detail: message, retryAfter: retry, minimumVersion: minimumVersion)
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

struct ErrorMiddleware: ClientMiddleware {
    var signals: SessionSignals? = nil
    func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        do { return try await checked(next(request, body, baseURL)) }
        catch { signals?.emit(error); throw error }
    }
}

/// Global account scope (no makerspace header): generated auth operations plus the account-wide
/// username routes the `handle_required` step needs.
let globalAccountOperations: Set<String> = ["api_v1_member_profile_handle_create", "api_v1_handles_check_retrieve"]

enum DeviceRequestScope {
    @TaskLocal static var makerspace: Int?
    @TaskLocal static var credentials: CredentialSnapshot?
    @TaskLocal static var staffCredentials: CredentialSnapshot?
    @TaskLocal static var pushMakerspace: Int?
    @TaskLocal static var globalAccount = false
}

public struct SessionMiddleware: ClientMiddleware {
    public let refresh: RefreshCoordinator
    public let makerspace: MakerspaceContext
    var signals: SessionSignals? = nil
    public init(refresh: RefreshCoordinator, makerspace: MakerspaceContext) { self.refresh = refresh; self.makerspace = makerspace }
    init(refresh: RefreshCoordinator, makerspace: MakerspaceContext, signals: SessionSignals) {
        self.refresh = refresh; self.makerspace = makerspace; self.signals = signals
    }
    public func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                          next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for name in ["Cookie", "Origin", "Referer"] { request.headerFields[HTTPField.Name(name)!] = nil }
        let credentials = await refresh.snapshot()
        if let expected = DeviceRequestScope.credentials, credentials.epoch != expected.epoch { throw CancellationError() }
        let pair = credentials.pair
        request.headerFields[.authorization] = pair.map { "Bearer \($0.access)" }
        let selected = await makerspace.current()
        if let expected = DeviceRequestScope.makerspace, expected != selected { throw CancellationError() }
        if let push = DeviceRequestScope.pushMakerspace {
            guard ["api_v1_integrations_push_devices_create", "api_v1_integrations_push_devices_destroy"].contains(operationID),
                  await makerspace.authorizesPush(push) else { throw CancellationError() }
        }
        if DeviceRequestScope.globalAccount {
            guard operationID.hasPrefix("api_v1_auth_") || globalAccountOperations.contains(operationID),
                  DeviceRequestScope.pushMakerspace == nil else { throw CancellationError() }
            request.headerFields[HTTPField.Name("X-Makerspace-Id")!] = nil
        } else {
            request.headerFields[HTTPField.Name("X-Makerspace-Id")!] = (DeviceRequestScope.pushMakerspace ?? DeviceRequestScope.makerspace ?? selected).map(String.init)
        }
        do { return try await send(request, body: body, baseURL: baseURL, credentials: credentials, next: next) }
        catch { signals?.emit(error); throw error }
    }
    private func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, credentials: CredentialSnapshot,
                      next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        let result = try await next(request, body, baseURL)
        if result.0.status.code == 401, credentials.pair != nil {
            let updated = try await refresh.recover(rejected: credentials)
            if let expected = DeviceRequestScope.makerspace, await makerspace.current() != expected { throw CancellationError() }
            if let push = DeviceRequestScope.pushMakerspace, !(await makerspace.authorizesPush(push)) { throw CancellationError() }
            guard (await refresh.snapshot()).epoch == credentials.epoch else { throw CancellationError() }
            request.headerFields[.authorization] = "Bearer \(updated.access)"
            return try await checked(next(request, body, baseURL))
        }
        return try await checked(result)
    }
}

/// Refuse every redirect. Credentials and health checks never move to a different host or HTTP.
public final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum DeviceSession {
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return config
    }
    public static func make(configuration: URLSessionConfiguration = configuration()) -> URLSession {
        URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}

public final class SpaceWorksService: Sendable {
    let client: Client
    let publicClient: Client
    /// The staff step-up grant's own client: its bearer and the grant's fixed `X-Makerspace-Id`.
    let staffClient: Client
    public let refresh: RefreshCoordinator
    public let makerspace: MakerspaceContext
    /// The staff grant coexists with the member grant (PRD §7 item 6) and refreshes on its own.
    public let staffRefresh: RefreshCoordinator
    public let staffScope: StaffGrantScope
    public let signals = SessionSignals()
    public let deviceTrust: DeviceTrust
    /// Sent as `app_version` on login, social, phone, the staff step-up and refresh (426 gate).
    public let appVersion: String?
    public init(origin: ServerOrigin, session: URLSession = DeviceSession.make(), initialTokens: TokenPair? = nil,
                makerspace: MakerspaceContext = MakerspaceContext(),
                persist: @escaping @Sendable (TokenPair?) throws -> Void = { _ in },
                appVersion: String? = nil, deviceTrust: (any DeviceTrustStorage)? = nil,
                staffStorage: (any StaffGrantStorage)? = nil) {
        // Buffered mode keeps URLSession's session delegate in control of redirects. Streaming
        // transport installs its own task delegate and would bypass that guarantee.
        let transport = URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered))
        let trust = DeviceTrust(storage: deviceTrust)
        let signals = self.signals
        let version = appVersion.flatMap { AppVersionField.valid($0) }
        let raw = Client(serverURL: origin.url, configuration: ServerDateTranscoder.configuration, transport: transport, middlewares: [DeviceTrustMiddleware(trust: trust), ErrorMiddleware(signals: signals)])
        self.publicClient = raw
        self.deviceTrust = trust
        self.appVersion = version
        let rotate: @Sendable (String) async throws -> TokenPair = { token in
            let response = try await raw.api_v1_auth_device_refresh_create(.init(body: .json(.init(refresh: token, app_version: version))))
            let value = try response.ok.body.json
            return TokenPair(access: value.access, refresh: value.refresh)
        }
        let coordinator = RefreshCoordinator(pair: initialTokens, persist: persist, rotate: rotate)
        self.refresh = coordinator
        self.makerspace = makerspace
        self.client = Client(serverURL: origin.url, configuration: ServerDateTranscoder.configuration, transport: transport,
                             middlewares: [DeviceTrustMiddleware(trust: trust), SessionMiddleware(refresh: coordinator, makerspace: makerspace, signals: signals)])
        let stored = try? staffStorage?.load()
        let scope = StaffGrantScope(stored.map { ($0.makerspaceID, $0.makerspaceSlug) })
        let staffCoordinator = RefreshCoordinator(pair: stored?.pair, persist: { pair in
            let target = scope.current
            try staffStorage?.store(pair.flatMap { pair in target.map { StaffGrantRecord(pair: pair, makerspaceID: $0.id, makerspaceSlug: $0.slug) } })
        }, rotate: rotate)
        self.staffScope = scope
        self.staffRefresh = staffCoordinator
        self.staffClient = Client(serverURL: origin.url, configuration: ServerDateTranscoder.configuration, transport: transport,
                                  middlewares: [DeviceTrustMiddleware(trust: trust), StaffSessionMiddleware(refresh: staffCoordinator, scope: scope, signals: signals)])
    }
    public func health() async throws {
        let result = try await client.api_v1_health_retrieve()
        _ = try result.ok.body.json
    }
    /// A task's makerspace header stays bound to its original repository across actor suspension.
    public func withMakerspace<T: Sendable>(_ id: Int, expectedCredentials: CredentialSnapshot? = nil,
                                              operation: @Sendable () async throws -> T) async throws -> T {
        if let expectedCredentials {
            guard await refresh.isSameInstallation(expectedCredentials) else { throw CancellationError() }
            guard await refresh.isCurrent(expectedCredentials) else {
                throw APIError(status: 401, code: "signed_out", detail: APILocalCopy.text("Please sign in again."))
            }
        }
        let credentials: CredentialSnapshot
        if let existing = DeviceRequestScope.credentials { credentials = existing }
        else if let expectedCredentials { credentials = expectedCredentials }
        else { credentials = await refresh.snapshot() }
        return try await DeviceRequestScope.$credentials.withValue(credentials) {
            try await DeviceRequestScope.$globalAccount.withValue(false) {
                try await DeviceRequestScope.$makerspace.withValue(id, operation: operation)
            }
        }
    }

    /// Account security remains available before joining or selecting a makerspace. This scope
    /// carries the device session epoch and permits only generated auth operations, without a maker header.
    public func withSession<T: Sendable>(expectedCredentials: CredentialSnapshot? = nil, operation: @Sendable () async throws -> T) async throws -> T {
        guard DeviceRequestScope.pushMakerspace == nil else { throw CancellationError() }
        if let expectedCredentials, !(await refresh.isCurrent(expectedCredentials)) { throw CancellationError() }
        let credentials: CredentialSnapshot
        if let existing = DeviceRequestScope.credentials { credentials = existing }
        else if let expectedCredentials { credentials = expectedCredentials }
        else { credentials = await refresh.snapshot() }
        guard await refresh.isCurrent(credentials) else { throw CancellationError() }
        return try await DeviceRequestScope.$credentials.withValue(credentials) {
            try await DeviceRequestScope.$globalAccount.withValue(true) {
                try await DeviceRequestScope.$makerspace.withValue(nil, operation: operation)
            }
        }
    }

    /// Only push-device create/delete may use another freshly authorized direct membership.
    /// UI selection stays unchanged; the caller's set cannot create authority absent from /me.
    public func withPushMakerspace<T: Sendable>(_ id: Int, authorizedDirectMembershipIDs: Set<Int>, expectedCredentials: CredentialSnapshot? = nil, operation: @Sendable () async throws -> T) async throws -> T {
        guard authorizedDirectMembershipIDs.contains(id), await makerspace.authorizesPush(id) else { throw CancellationError() }
        let credentials: CredentialSnapshot
        if let expectedCredentials { credentials = expectedCredentials }
        else { credentials = await refresh.snapshot() }
        guard await refresh.isCurrent(credentials) else { throw CancellationError() }
        return try await DeviceRequestScope.$credentials.withValue(credentials) {
            // Global account security can end its session while still owning push cleanup.
            // This explicit narrower scope must not inherit the auth-only operation flag.
            try await DeviceRequestScope.$globalAccount.withValue(false) {
                try await DeviceRequestScope.$pushMakerspace.withValue(id) {
                    try await DeviceRequestScope.$makerspace.withValue(nil, operation: operation)
                }
            }
        }
    }

    public func configuration() async throws -> Components.Schemas.PublicConfig {
        try await publicClient.api_v1_config_retrieve().ok.body.json
    }
    public func challenge(appID: String, development: Bool) async throws -> Components.Schemas.DeviceChallengeResponse {
        let input = Components.Schemas.DeviceIdentity(platform: "apple", app_id: appID, environment: development ? .development : .production)
        return try await publicClient.api_v1_auth_device_attestation_challenge_create(.init(body: .json(input))).ok.body.json
    }
    /// A member grant by default. `staffMakerspace` asks for a staff grant fixed to that slug
    /// (always answered with an MFA challenge, PRD §7 item 6).
    public func signIn(appID: String, development: Bool, username: String, password: String, challenge: String,
                       attestationJSON: Data, staffMakerspace: String? = nil) async throws -> Components.Schemas.DeviceLoginResult {
        let input = try Components.Schemas.DeviceLogin(platform: "apple", app_id: appID, environment: development ? .development : .production,
            authority: staffMakerspace == nil ? nil : .init(value1: .staff), makerspace: staffMakerspace,
            username: username, password: password, challenge: challenge,
            attestation: DeviceAttestation.payload(attestationJSON), app_version: appVersion)
        return try await publicClient.api_v1_auth_device_login_create(.init(body: .json(input))).ok.body.json
    }
    public func me() async throws -> Components.Schemas.AuthUserPayload {
        try await client.api_v1_auth_me_retrieve().ok.body.json
    }
    /// `emailCode` answers an unusual-sign-in (`purpose: "risk"`) challenge with `factor: "email_code"`.
    public func verify(challenge: String, code: String, enrolling: Bool = false, emailCode: Bool = false) async throws -> Components.Schemas.MFACompleted {
        let input = Components.Schemas.MFAVerify(challenge: challenge, code: code, factor: emailCode ? .init(value1: .email_code) : nil)
        if enrolling { return try await publicClient.api_v1_auth_mfa_confirm_create(.init(body: .json(input))).ok.body.json }
        return try await publicClient.api_v1_auth_mfa_verify_create(.init(body: .json(input))).ok.body.json
    }
    /// Emails a fresh unusual-sign-in code for the same challenge (the server allows a few).
    public func resendLoginCode(challenge: String) async throws -> Components.Schemas.LoginCodeResent {
        try await publicClient.api_v1_auth_login_code_resend_create(.init(body: .json(.init(challenge: challenge)))).ok.body.json
    }
    public func enroll(challenge: String) async throws -> Components.Schemas.MFAEnrollment {
        try await publicClient.api_v1_auth_mfa_enroll_create(.init(body: .json(.init(challenge: challenge)))).ok.body.json
    }
    public func signOut() async throws {
        _ = try await client.api_v1_auth_device_logout_create().ok.body.json
    }
    public func changePassword(current: String, new: String) async throws {
        _ = try await client.api_v1_auth_change_password_create(.init(body: .json(.init(current_password: current, new_password: new)))).ok.body.json
    }
    public func createAccount(name: String, email: String, password: String, phone: String, handle: String? = nil) async throws {
        let input = Components.Schemas.MemberSignUp(display_name: name, email: email, phone: phone, password: password, website: "",
                                                    handle: handle?.isEmpty == false ? handle : nil)
        _ = try await publicClient.api_v1_auth_member_sign_up_create(.init(body: .json(input))).ok.body.json
    }
    public func requestPasswordReset(email: String) async throws {
        _ = try await publicClient.api_v1_auth_forgot_password_create(.init(body: .json(.init(email: email)))).ok.body.json
    }
    public func resetPassword(email: String, code: String, new: String) async throws {
        let input = Components.Schemas.ResetPasswordConfirmRequest.OtpResetPasswordConfirm(.init(email: email, code: code, new_password: new))
        _ = try await publicClient.api_v1_auth_reset_password_create(.init(body: .json(input))).ok.body.json
    }
    public func confirmEmail(code: String) async throws {
        _ = try await client.api_v1_auth_email_verification_confirm_create(.init(body: .json(.init(code: code)))).ok.body.json
    }
    public func resendEmailVerification() async throws {
        _ = try await client.api_v1_auth_email_verification_resend_create().ok.body.json
    }
}

/// The server's date-times carry microseconds whenever the stored value has them (DRF ISO 8601), and
/// sometimes a `+00:00` offset; the runtime's default transcoder rejects fractional seconds. Decode both,
/// send without fractions.
public struct ServerDateTranscoder: DateTranscoder {
    public static let configuration = Configuration(dateTranscoder: ServerDateTranscoder())
    private let fractional = ISO8601DateTranscoder(options: [.withInternetDateTime, .withFractionalSeconds])
    private let whole = ISO8601DateTranscoder()
    public init() {}
    public func encode(_ date: Date) throws -> String { try whole.encode(date) }
    public func decode(_ string: String) throws -> Date {
        if let date = try? fractional.decode(string) { return date }
        return try whole.decode(string)
    }
}
