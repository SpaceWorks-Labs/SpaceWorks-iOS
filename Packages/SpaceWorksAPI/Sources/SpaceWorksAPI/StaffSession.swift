import Foundation
import HTTPTypes
import OpenAPIRuntime

/// `app_version` is a string of at most 32 characters (schema); anything else is not sent.
enum AppVersionField {
    static func valid(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 32 ? trimmed : nil
    }
}

/// The makerspace a staff grant is fixed to. The staff middleware sends it as `X-Makerspace-Id`
/// on every staff call; it never follows the member makerspace selection.
public final class StaffGrantScope: @unchecked Sendable {
    public struct Target: Sendable, Equatable { public let id: Int; public let slug: String }
    private let lock = NSLock()
    private var target: Target?
    init(_ value: (id: Int, slug: String)?) { target = value.map { Target(id: $0.id, slug: $0.slug) } }
    public var current: Target? { lock.withLock { target } }
    func set(_ value: Target?) { lock.withLock { target = value } }
}

/// Bearer + fixed makerspace header for the staff grant. A 401 tries the staff grant's own
/// single-flight refresh once; the member grant is never touched.
struct StaffSessionMiddleware: ClientMiddleware {
    let refresh: RefreshCoordinator
    let scope: StaffGrantScope
    let signals: SessionSignals
    func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for name in ["Cookie", "Origin", "Referer"] { request.headerFields[HTTPField.Name(name)!] = nil }
        let credentials = await refresh.snapshot()
        if let expected = DeviceRequestScope.staffCredentials, credentials.epoch != expected.epoch { throw CancellationError() }
        guard let pair = credentials.pair, let target = scope.current else {
            throw APIError(status: 401, code: "staff_grant_missing", detail: APILocalCopy.text("Open staff tools again to continue."))
        }
        request.headerFields[.authorization] = "Bearer \(pair.access)"
        // Required on staff routes; account routes (`/auth/me`, logout) name no space, so omit it there.
        request.headerFields[HTTPField.Name("X-Makerspace-Id")!] = operationID.hasPrefix("api_v1_auth_") ? nil : String(target.id)
        do {
            let result = try await next(request, body, baseURL)
            guard result.0.status.code == 401 else { return try await checked(result) }
            let updated = try await refresh.recover(rejected: credentials)
            guard (await refresh.snapshot()).epoch == credentials.epoch, scope.current == target else { throw CancellationError() }
            request.headerFields[.authorization] = "Bearer \(updated.access)"
            return try await checked(next(request, body, baseURL))
        } catch { signals.emit(error); throw error }
    }
}

extension SpaceWorksService {
    /// Step-up from ANY active device session (PRD §7 item 6): a fresh attestation challenge,
    /// the makerspace slug and `app_version`. Always answers with an MFA challenge; finish it with
    /// `verify(challenge:code:)` or enrolment WITHOUT the Authorization header.
    public func staffStepUp(makerspace slug: String, challenge: String, attestationJSON: Data) async throws -> Components.Schemas.MFAChallengeResponse {
        let input = Components.Schemas.DeviceStaffGrant(makerspace: slug, challenge: challenge,
            attestation: try DeviceAttestation.payload(attestationJSON), app_version: appVersion)
        return try await client.api_v1_auth_device_staff_grant_create(.init(body: .json(input))).ok.body.json
    }

    /// Install (or clear) the staff grant. The fixed makerspace is published before the pair.
    public func installStaffGrant(_ record: StaffGrantRecord?) async throws {
        if let record {
            staffScope.set(.init(id: record.makerspaceID, slug: record.makerspaceSlug))
            try await staffRefresh.install(record.pair)
        } else {
            try await staffRefresh.install(nil)
            staffScope.set(nil)
        }
    }

    /// `/auth/me` as the staff grant sees it: `session_authority: native_staff` and `staff_roles`
    /// for the fixed makerspace only.
    public func staffMe() async throws -> Components.Schemas.AuthUserPayload {
        try await staffClient.api_v1_auth_me_retrieve().ok.body.json
    }

    /// Signs only the staff grant out; the member grant keeps working.
    public func staffSignOut() async throws {
        _ = try await staffClient.api_v1_auth_device_logout_create().ok.body.json
    }

    /// Binds staff calls to the staff grant installation the caller observed.
    public func withStaffGrant<T: Sendable>(expectedCredentials: CredentialSnapshot, makerspaceID: Int,
                                            operation: @Sendable () async throws -> T) async throws -> T {
        guard await staffRefresh.isSameInstallation(expectedCredentials) else { throw CancellationError() }
        guard await staffRefresh.isCurrent(expectedCredentials), staffScope.current?.id == makerspaceID else {
            throw APIError(status: 401, code: "staff_grant_missing", detail: APILocalCopy.text("Open staff tools again to continue."))
        }
        return try await DeviceRequestScope.$staffCredentials.withValue(expectedCredentials, operation: operation)
    }
}
