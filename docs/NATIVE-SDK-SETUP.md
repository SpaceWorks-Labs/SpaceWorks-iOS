# Native provider setup

SDK code is compiled in CI. A compiled adapter is not evidence of a configured provider or a
completed real-device transaction. Debug demo flows never invoke these SDKs or send their sample
values to a service.

Sign-in methods render only from the server's `GET /api/v1/config` `native.providers` block
(contract SHA-256 `8045528d…`, backend 0.12.0). Every native method uses the same attested device flow: a fresh
attestation challenge, the method's proof, then a device grant through a generated operation.
A response without `refresh` and a UUID `device_grant.id` is refused; no browser cookie or
access-only response is ever accepted as an app session.

| Integration | Native adapter | Owner/server setup |
|---|---|---|
| Device integrity | DeviceCheck App Attest; fresh key per sign-in, `clientDataHash = SHA-256(challenge)`, sent as `{"type":"app_attest","key_id","attestation"}` through the schema's open proof alternative. Simulators in Debug send `{"type":"development"}`. | Approved native app registration (blank makerspace) with the actual App ID Prefix; App Attest capability for the registered bundle/team; development registration for Debug builds |
| Minimum version | `native.min_app_version.ios`, compared by dotted numeric components on launch | Native app registration "Min supported version" (production) |
| Google | Official GoogleSignIn 10.0.0 with the server-issued nonce; the ID token audience is `native.providers.google.ios_client_id` (no server client ID) | Register the iOS OAuth client; set "Google ios client id"; put its reversed client ID in `branding/brand.json` `google_reversed_client_id` so the callback scheme is registered |
| Apple | AuthenticationServices with the server nonce; sends the authorization code (for revocation at deletion) and first-time name | Sign in with Apple capability; list the bundle ID in "Apple native app ids" |
| Organization OIDC | Discovery from the published issuer, authorization code + PKCE (S256) in an ephemeral `ASWebAuthenticationSession`, then the ID token goes to `POST /auth/social/oidc/{slug}`. Discovery and the code exchange talk only to the identity provider. | Add `spaceworks://auth/callback` as a redirect URI on the provider's existing public client (the published `client_id`) |
| Phone | `POST /auth/phone/login/start` with `delivery: device` and a fresh challenge; confirm with the code, the same challenge and its attestation before the challenge expires (180 s by default). Member-only. | Phone login and SMS delivery enabled on the server |
| Push | UserNotifications/APNs; routing keys arrive under the payload's `data` dictionary | APNs key in Platform push settings; `aps_environment` in `branding/brand.json` |
| QR | VisionKit scanner and explicit manual-code fallback | Real camera permission/device; server resolves the opaque code |
| Payments | Stripe PaymentSheet or Razorpay Checkout, selected by the intent's `vendor` | Per-makerspace provider credentials on the server; no app secrets |
| Usage analytics | Firebase Analytics 13.1.1 (`FirebaseAnalyticsCore`, no ad-id support) and PostHog 3.94.4, started only after consent | Your `GoogleService-Info.plist` (git-ignored) and/or `telemetry.posthog_api_key`; see [TELEMETRY.md](TELEMETRY.md) |
| Session replay | Microsoft Clarity 4.1.2, paused on sensitive screens | `telemetry.clarity_project_id`; Strict masking in the Clarity project |
| Crash and performance reports | Sentry 9.34.0 with the scrubber, no screenshots or PII | `telemetry.sentry_dsn` (public DSN) and sample rate |

Google clears its SDK session after obtaining a token; the app's Keychain device grant remains the
sole app session. Provider tokens are passed straight to the generated operation and are never
logged or persisted. Since 0.12.0 password, phone and social sign-in may all return the generated MFA
challenge (social: anyone MFA is mandatory for, i.e. staff-role holders), and an unusual sign-in
asks for an emailed code; see "Native contract 0.12.0" below.

Reauthentication for account deletion supports password (+ authenticator code), the separate phone
reauthentication code, and native Google/Apple/organization proof with the server's reauthentication
nonce, including a requested second factor. GitHub proof is web-only.

Sources: [Google release](https://github.com/google/GoogleSignIn-iOS/releases/tag/10.0.0),
[Google integration](https://developers.google.com/identity/sign-in/ios/sign-in),
[App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity),
[RFC 8252](https://www.rfc-editor.org/rfc/rfc8252).

## Native contract 0.12.0

Pinned 2026-11-12 to backend `dev` 0.12.0 (`api/provenance.json`: SHA-256 `8045528d…`, 17,638,300
bytes, 2,211 paths, schema commit `b502caeb`, head `5c7f5733`). `scripts/generate.py` stages a
mechanical projection for the generator: only the allow-listed operations and the schemas they
reach, the JSON request representation, and **every string enum reachable from a response opened
to a plain string** (PRD §7: an unknown value is "other", never a decode failure). Request-only
enums stay typed. The app compares the raw values it acts on (`session_authority`, statuses, kinds)
and shows server copy for the rest; `scripts/tests/test_generation.py` pins the projection.

| Rule (PRD §7) | Where in the app |
|---|---|
| `app_version` on device login, social, phone confirm, phone restore, the staff step-up and refresh | `SpaceWorksService(appVersion:)` (`CFBundleShortVersionString`) |
| 426 `native_app_update_required` (`minimum_version`) | Any operation, refresh included, raises `SessionSignals.updateRequired`; `AuthState` shows Update required with the enforced minimum and keeps the stored session (nothing was rotated) |
| `device_trust` → `X-Device-Trust` | Stored per server in Keychain (`DeviceTrustVault`); sent only on sign-in routes (login, social, phone confirm, MFA verify/confirm, login-code resend, staff step-up); replaced after every completed sign-in |
| Unusual sign-in (`purpose: "risk"`, `factors: ["email_code"]`) | "Check your email" step; `POST /auth/mfa/verify {challenge, code, factor: "email_code"}`; "Send a new code" → `POST /auth/login-code/resend` (disabled when `resends_left` is 0); `login_code_invalid` copy |
| Social `oneOf[tokens, MFAChallengeResponse]` | Google/Apple/OIDC follow the MFA screen when challenged |
| `handle_required` | Blocking "Choose your username" step after sign-in (`GET /handles/check`, `POST /member/profile/handle`), server suggestion offered first |
| 401 `session_revoked` | Signed out with "Your session has ended. Sign in again." |
| Paged `GET /auth/device/grants` | Every page is read (bounded at 20); grants show `authority` |
| Booking reject `{reason}` | Staff must enter a reason (≤ 1,000 characters) |
| Staff step-up | See below |

**Staff step-up (dual grant).** A member grant never carries staff authority. Profile offers "Open
staff tools" when `/auth/me` says `has_staff_role`; the person enters the makerspace's short name
(prefilled with the selected makerspace) and the app calls `POST /auth/device/staff-grant`
`{makerspace, challenge, attestation, app_version}` from the member session, then finishes the MFA
challenge (or authenticator enrolment) with `POST /auth/mfa/verify` / `confirm` WITHOUT the
Authorization header. The result is a second grant (`authority: "staff"`, `staff_makerspace_id`),
kept in its own Keychain item (`StaffGrantVault`) with its own single-flight refresh
(`SpaceWorksService.staffRefresh`). Staff routes go through `staffClient`: the staff bearer and
`X-Makerspace-Id` = the grant's makerspace (omitted on `/auth/*`). Staff tools appear only while
the staff grant's `/auth/me` reports `session_authority: native_staff` and lists the selected
makerspace in `staff_roles`; each tool still needs its action. A 401 on the staff grant (role
removed, grant revoked) drops only staff tools; the member session continues. "Leave staff tools"
signs the staff grant out; signing out signs out the staff grant and then the member grant;
sign-out everywhere and account deletion clear both locally (the server already revoked them).
`SpaceWorksService.signIn(staffMakerspace:)` also supports the `authority: "staff"` login path.

