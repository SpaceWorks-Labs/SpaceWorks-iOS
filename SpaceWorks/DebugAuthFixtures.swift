#if DEBUG
import Foundation

/// Contract-shaped fixtures for UI tests only, selected by explicit process launch flags.
enum DebugAuthFixtures {
    static let grant = #"{"id":"00000000-0000-0000-0000-000000000001","platform":"apple","app_id":"org.spaceworks.app","environment":"development","status":"active","attested_at":"2026-10-16T12:00:00Z","last_used_at":"2026-10-16T12:00:00Z","created_at":"2026-10-16T12:00:00Z","authority":"member","staff_makerspace_id":null,"login_method":"password"}"#
    static let membership = #"{"id":7,"slug":"demo-workshop","role":"member","role_id":1,"role_ids":[1],"role_slugs":["member"],"role_names":["Member"],"role_name":"Member","role_slug":"member","source":"membership","actions":[],"can_configure_machine_types":false,"is_machine_only":false,"can_refer":false,"can_verify":false,"verified_at":null,"referrals_enabled":false,"tracks":["community"]}"#
    static let secondMembership = membership.replacingOccurrences(of: #""id":7"#, with: #""id":8"#).replacingOccurrences(of: "demo-workshop", with: "community-lab")
    static var user: String { user(memberships: [membership, secondMembership]) }
    /// 0.12.0 `AuthUserPayload`: every required field, a username already chosen, no staff roles on a member grant.
    static func user(memberships: [String], superuser: Bool = false, authority: String = "member", staffRoles: String = "[]",
                     hasStaffRole: Bool = false, handle: String? = "maker") -> String {
        let handleValue = handle.map { "\"\($0)\"" } ?? "null"
        let suggestion = handle == nil ? "\"maker.one\"" : "null"
        return "{\"session_authority\":\"\(authority)\",\"id\":12,\"username\":\"member\",\"email\":\"member@example.invalid\",\"display_name\":\"Maker\",\"phone\":\"\",\"email_verified\":true,\"role\":\"member\",\"is_superuser\":\(superuser),\"must_change_password\":false,\"makerspaces\":[\(memberships.joined(separator: ","))],"
            + "\"handle\":\(handleValue),\"handle_required\":\(handle == nil),\"handle_suggestion\":\(suggestion),\"kind\":\"person\",\"is_platform\":false,\"has_staff_role\":\(hasStaffRole),"
            + "\"has_elevated_authority\":\(hasStaffRole),\"has_organizations\":false,\"staff_roles\":\(staffRoles),\"superadmin_actions\":[],\"mfa_grace_ends_at\":null,"
            + "\"merge_suggested\":false,\"mfa_enrolment_due\":false,\"preferred_locale\":null,\"effective_locale\":\"en\",\"supported_locales\":[]}"
    }
    /// The staff step-up grant's `/auth/me`: `native_staff` with staff roles for makerspace 7 only.
    static var staffGrantUser: String {
        let roles = #"[{"makerspace":{"id":7,"slug":"demo-workshop","name":"Demo workshop"},"roles":[{"id":3,"slug":"handover","name":"Handover"}],"actions":["accept_request","reject_request","assign_box","issue_request","return_request","upload_evidence","manage_bookings"]}]"#
        return user(memberships: [membership, secondMembership], authority: "native_staff", staffRoles: roles, hasStaffRole: true)
    }
    /// A member grant of a person who holds a staff role somewhere (the step-up is offered).
    static var staffPersonUser: String { user(memberships: [membership, secondMembership], hasStaffRole: true) }
    static let staffGrant = #"{"id":"00000000-0000-0000-0000-000000000002","platform":"apple","app_id":"org.spaceworks.app","environment":"development","status":"active","attested_at":"2026-10-16T12:00:00Z","last_used_at":"2026-10-16T12:00:00Z","created_at":"2026-10-16T12:00:00Z","authority":"staff","staff_makerspace_id":7,"login_method":"password"}"#
    static var tokens: String { "{\"access\":\"test-access\",\"refresh\":\"test-refresh\",\"user\":\(user),\"device_grant\":\(grant)}" }
    static let mfa = #"{"mfa_required":true,"enrollment_required":false,"challenge":"test-mfa-challenge-of-valid-length","expires_in":300}"#
    static let telemetry = #"{"pageview":{"provider":"none","site_id":"","endpoint":""},"replay":{"provider":"none","site_id":"","endpoint":""},"diagnostics":{"sentry":{"enabled":false,"dsn":"","sample_rate":0},"firebase_performance":{"enabled":false,"sample_rate":0}},"firebase":{"api_key":"","auth_domain":"","project_id":"","app_id":"","messaging_sender_id":"","measurement_id":"","vapid_public_key":""}}"#
    static let configBase = #""landing_enabled":false,"passkeys_enabled":false,"platform_telemetry_legacy_allowed":false,"platform_telemetry":"# + telemetry
    static let config = #"{"email_enabled":false,"public_image_max_bytes":10485760,"password_login":{"member":true,"staff":true},"social_auth":{},"# + configBase + "}"
    /// The schema's `native` discovery block: password and phone enabled, optional iOS minimum.
    static func nativeConfig(minimum: String? = nil) -> String {
        let value = minimum.map { "\"\($0)\"" } ?? "null"
        return #"{"email_enabled":false,"public_image_max_bytes":10485760,"password_login":{"member":true},"# + configBase + #","native":{"app_display_name":"Space Works","app_identity":{"android":null,"ios":null},"min_app_version":{"android":null,"ios":"# + value + #"},"providers":{"password":true,"phone":true,"google":null,"apple":null,"oidc":[]}}}"#
    }
    static let chartSpec = #"{"series":["issued_count"],"x":{"field":"period","kind":"time"},"values":[{"field":"issued_count","unit":"loans"}],"currency_field":null,"partition":null,"negatives":"clip","truncation":null,"alt_template":"Loans by month"}"#
    static var usage: String {
        #"{"usage_available":true,"loans":{"count":3,"returned_count":2,"currently_out":1,"monthly":{"rows":[{"period":"2026-09","issued_count":2,"return_events":1},{"period":"2026-10","issued_count":1,"return_events":1}],"chart_spec":"# + chartSpec + #"}},"payments":{"paid_by_currency":{"inr":"1250.00"},"outstanding_by_currency":{"inr":"250.00"},"totals":{"rows":[],"chart_spec":"# + chartSpec + #"}}}"#
    }
    static let dashboard = #"{"scope_mode":"full","pending_requests":2,"awaiting_issue":0,"queue_tiles":{"ready_to_issue":1,"due_returns":3,"pickups":0},"widgets":[],"outstanding_by_currency":{"inr":"250.00"}}"#
    static let messaging = #"{"sms":{"available":true,"consented":false,"phone_verified":false,"phone_masked":"","suppressed":false},"whatsapp":{"available":false,"consented":false,"phone_verified":false,"phone_masked":"","suppressed":false}}"#
    static let enrollment = #"{"secret":"TESTAUTHENTICATORKEY","provisioning_uri":"otpauth://totp/SpaceWorks:maker?secret=TESTAUTHENTICATORKEY&issuer=SpaceWorks","qr_data_url":""}"#
}
#endif
