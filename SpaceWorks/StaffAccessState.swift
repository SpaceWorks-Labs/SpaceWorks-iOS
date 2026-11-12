import Foundation
import Observation
import SpaceWorksAPI

/// The staff step-up grant (PRD §7 item 6, 0.12.0 dual-grant model). The member grant keeps
/// serving member screens; this holds a SECOND device grant with `authority: "staff"` fixed to
/// one makerspace, its own refresh and its own `/auth/me` (`session_authority: native_staff`).
/// Staff tools open only while this grant is valid for the selected makerspace and lists the action.
@MainActor @Observable
final class StaffAccessState {
    enum Step: Equatable { case idle, mfa, recoveryCodes }
    private(set) var step = Step.idle
    /// The fixed makerspace of the current staff grant, if any.
    private(set) var target: StaffGrantScope.Target?
    /// `/auth/me` read with the staff grant: only its makerspace's `staff_roles`.
    private(set) var staffUser: Components.Schemas.AuthUserPayload?
    private(set) var credentials: CredentialSnapshot?
    private(set) var mfa: Components.Schemas.MFAChallengeResponse?
    private(set) var enrollment: Components.Schemas.MFAEnrollment?
    private(set) var recoveryCodes: [String] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    /// Bumped whenever staff authority changes so scoped workspaces rebuild.
    private(set) var revision = 0
    var slug = ""
    var code = ""
    private var pendingSlug = ""
    private var mfaExpires: Date?
    private var generation = 0
    let service: SpaceWorksService
    private let attest: @Sendable (String) async throws -> Data
    private let appID: String
    private let development: Bool
    /// Reports update-required (426) to the owning AuthState.
    var onUpdateRequired: (APIError) -> Void = { _ in }

    init(service: SpaceWorksService, attest: @escaping @Sendable (String) async throws -> Data,
         appID: String = Brand.bundleID, development: Bool = NativeAttestor.development) {
        self.service = service; self.attest = attest; self.appID = appID; self.development = development
    }

    /// Staff actions this grant allows in `makerspaceID`, or nil when staff tools are closed there.
    func actions(for makerspaceID: Int) -> Set<String>? {
        guard credentials != nil, target?.id == makerspaceID, let staffUser,
              staffUser.session_authority.value1 == "native_staff",
              let role = staffUser.staff_roles.first(where: { $0.makerspace.id == makerspaceID }) else { return nil }
        return Set(role.actions)
    }
    func available(for makerspaceID: Int) -> Bool { actions(for: makerspaceID) != nil }

    /// Resume a stored staff grant after launch or on foreground; a refused grant is dropped locally.
    func refresh() async {
        guard await service.staffRefresh.current() != nil else {
            if target != nil || staffUser != nil { clearLocal() }
            return
        }
        let generation = self.generation
        let snapshot = await service.staffRefresh.snapshot()
        do {
            let identity = try await service.staffMe()
            guard generation == self.generation, await service.staffRefresh.isCurrent(snapshot) else { return }
            guard identity.session_authority.value1 == "native_staff", let scope = service.staffScope.current,
                  identity.staff_roles.contains(where: { $0.makerspace.id == scope.id }) else {
                await drop(message: String(localized: "Staff access ended. Open staff tools again to continue.")); return
            }
            publish(identity: identity, target: scope, snapshot: snapshot)
        } catch {
            guard generation == self.generation, !APIError.isCancellation(error) else { return }
            if APIError.isUpdateRequired(error), let failure = APIError.apiError(error) { onUpdateRequired(failure); return }
            if APIError.status(error) == 401 || APIError.status(error) == 403 {
                await drop(message: APIError.code(error) == "session_revoked" ? APIError.display(error)
                           : String(localized: "Staff access ended. Open staff tools again to continue."))
            }
        }
    }

    /// Start the step-up from the current member session: fresh attestation, then the second factor.
    func begin() async {
        let slug = self.slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !busy else { return }
        guard !slug.isEmpty, slug.count <= 150, slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            error = String(localized: "Enter the makerspace's short name."); return
        }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        let generation = self.generation
        do {
            let challenge = try await service.challenge(appID: appID, development: development)
            let expires = Date().addingTimeInterval(TimeInterval(challenge.expires_in))
            let proof = try await attest(challenge.challenge)
            guard Date() < expires else { throw APIError(status: 0, code: "challenge_expired", detail: String(localized: "Your sign-in expired. Try again.")) }
            let service = self.service
            let started = try await service.withSession {
                try await service.staffStepUp(makerspace: slug, challenge: challenge.challenge, attestationJSON: proof)
            }
            guard generation == self.generation else { return }
            pendingSlug = slug
            mfa = started; mfaExpires = Date().addingTimeInterval(TimeInterval(started.expires_in))
            enrollment = started.enrollment_required ? try await service.enroll(challenge: started.challenge) : nil
            code = ""; step = .mfa
        } catch { fail(error) }
    }

    /// Finish the step-up challenge WITHOUT the Authorization header; the result is a NEW grant.
    func verify() async {
        guard !busy, let mfa else { return }
        guard (mfaExpires ?? .distantPast) > Date() else { cancel(); error = String(localized: "Your sign-in expired. Try again."); return }
        guard code.count >= 6 else { error = String(localized: "Enter your authenticator or recovery code."); return }
        busy = true; error = nil
        defer { busy = false; code = "" }
        let generation = self.generation
        do {
            let result = try await service.verify(challenge: mfa.challenge, code: code, enrolling: mfa.enrollment_required)
            guard generation == self.generation else { return }
            guard let pair = NativeDeviceCompletion.tokens(access: result.access, refresh: result.refresh, grant: result.device_grant, surface: result.surface),
                  let makerspaceID = NativeDeviceCompletion.staffMakerspaceID(result.device_grant) else {
                throw APIError(status: 0, code: "native_session_missing", detail: String(localized: "This server did not provide a staff session. Contact your makerspace."))
            }
            service.deviceTrust.remember(result.device_trust)
            try await service.installStaffGrant(.init(pair: pair, makerspaceID: makerspaceID, makerspaceSlug: pendingSlug))
            self.mfa = nil; enrollment = nil; mfaExpires = nil
            recoveryCodes = result.recovery_codes ?? []
            await refresh()
            guard target?.id == makerspaceID else { return }
            step = recoveryCodes.isEmpty ? .idle : .recoveryCodes
            notice = String(localized: "Staff tools are open for this makerspace.")
        } catch { fail(error) }
    }

    func confirmRecoveryCodes() { recoveryCodes = []; step = .idle }
    func cancel() { mfa = nil; enrollment = nil; mfaExpires = nil; code = ""; error = nil; step = .idle }

    /// Leave staff tools: sign the staff grant out on the server; the member grant keeps working.
    func end(serverLogout: Bool = true) async {
        guard await service.staffRefresh.current() != nil || target != nil else { return }
        if serverLogout { try? await service.staffSignOut() }
        clearLocal()
        try? await service.installStaffGrant(nil)
    }

    /// The staff grant was refused (role removed, grant revoked, generation changed): drop it only.
    func drop(message: String) async {
        clearLocal()
        try? await service.installStaffGrant(nil)
        error = message
    }

    private func publish(identity: Components.Schemas.AuthUserPayload, target: StaffGrantScope.Target, snapshot: CredentialSnapshot) {
        let changed = self.target != target || actionsKey(staffUser) != actionsKey(identity)
        staffUser = identity; self.target = target; credentials = snapshot
        if changed { revision += 1 }
    }
    private func actionsKey(_ user: Components.Schemas.AuthUserPayload?) -> String {
        user?.staff_roles.map { "\($0.makerspace.id):\($0.actions.sorted().joined(separator: ","))" }.joined(separator: ";") ?? ""
    }
    private func clearLocal() {
        generation += 1
        let hadGrant = target != nil || staffUser != nil
        target = nil; staffUser = nil; credentials = nil
        mfa = nil; enrollment = nil; mfaExpires = nil; code = ""; step = .idle; recoveryCodes = []; notice = nil
        if hadGrant { revision += 1 }
    }
    private func fail(_ failure: Error) {
        guard !APIError.isCancellation(failure) else { return }
        if APIError.isUpdateRequired(failure), let error = APIError.apiError(failure) { onUpdateRequired(error); return }
        error = APIError.display(failure)
    }
}
