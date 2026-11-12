# Telemetry

Owner extension (2026-11-12): Firebase Analytics, PostHog, Microsoft Clarity and Sentry, identical in
behaviour to the Android app. Every provider is **off** until it is configured at build time **and** the
person has agreed to its purpose. Withdrawal stops it at once. The backend is not changed.

## Providers

| Purpose (consent row) | Provider | SDK (exact pin in `project.yml`, lock in `Dependencies/Package.resolved`) | What it sends |
|---|---|---|---|
| Usage analytics | Firebase Analytics | firebase-ios-sdk 13.1.1, product `FirebaseAnalyticsCore` (no IDFA/AdSupport, no `GoogleAppMeasurementIdentitySupport`) | The events and screen views below |
| Usage analytics | PostHog | posthog-ios 3.94.4 | The same events; lifecycle events on; autocapture, screen autocapture, session replay, surveys and feature flags off |
| Session replay | Microsoft Clarity | clarity-apps 4.1.2 | Masked session replay and heatmaps; paused on sensitive screens |
| Crash and performance reports | Sentry | sentry-cocoa 9.34.0 (product `Sentry`) | Crashes, app hangs, performance traces (sample rate from config) |

No Firebase Crashlytics (Sentry is the only crash handler) and no Firebase Messaging (iOS keeps APNs).
No App Tracking Transparency prompt: nothing is used to track across apps.

## Configuration (public values only)

`branding/brand.json` → optional `telemetry` block; absent or `null` = provider off:

```json
"telemetry": {
  "sentry_dsn": null,
  "sentry_environment": null,
  "sentry_traces_sample_rate": 0.1,
  "posthog_api_key": null,
  "posthog_host": "https://eu.i.posthog.com",
  "clarity_project_id": null
}
```

Each key can be overridden when generating with an environment variable of the same name in upper case:
`SPACEWORKS_SENTRY_DSN`, `SPACEWORKS_SENTRY_ENVIRONMENT`, `SPACEWORKS_SENTRY_TRACES_SAMPLE_RATE`,
`SPACEWORKS_POSTHOG_API_KEY`, `SPACEWORKS_POSTHOG_HOST`, `SPACEWORKS_CLARITY_PROJECT_ID`.
`scripts/generate.py` validates them and writes them into the generated Info.plist under `SpaceWorksTelemetry`.
It refuses anything secret-shaped: a Sentry DSN with a secret part, a PostHog personal key (`phx_`), a non-HTTPS host.

Firebase is configured only by `SpaceWorks/GoogleService-Info.plist`. The file is git-ignored; XcodeGen
copies it into the app only when it exists, and `FirebaseApp.configure()` runs only when the plist is in
the bundle **and** usage analytics was granted. The generated Info.plist always sets
`FIREBASE_ANALYTICS_COLLECTION_ENABLED`, `GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED`,
`GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED`, `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS` and
`FirebaseAutomaticScreenReportingEnabled` to `false`; collection is switched on at runtime after consent.

Debug builds, and the DEBUG demo, never send anything. Set `SPACEWORKS_TELEMETRY_DEBUG=1` when generating
to let a Debug build send (for verifying with test projects); the demo still never sends.

In Clarity, also set the project's masking mode to **Strict** in the Clarity dashboard (mask all text,
inputs and images). The app additionally pauses Clarity on the sensitive screens listed below.

## Consent

Three purposes, all off by default: **Usage analytics**, **Session replay**, **Crash and performance reports**.
A purpose with no configured provider is hidden; with no provider configured the prompt and the Profile row
are hidden.

- First run: after the introduction, before the server step, a "Help improve Space Works" sheet (app name
  from branding) shows one switch per configured purpose and **Allow all**, **Save choices** and **Not now**
  (Not now and swiping the sheet away = all off). It is shown once; adding a provider later asks only for the
  newly configured purpose. It never blocks sign-in.
- Profile → **Privacy and analytics**: the same switches at any time, with "Withdrawing stops collection now.
  It cannot delete what a provider already holds."
- Stored per install (not per account) in `UserDefaults` key `telemetry-consent` with a schema version.
- Grant starts the provider immediately, without a relaunch (Sentry, Firebase, PostHog and Clarity all start
  lazily). Withdrawal: Firebase `setAnalyticsCollectionEnabled(false)` + `resetAnalyticsData()`,
  PostHog `optOut()` + `reset()`, Sentry `close()`, Clarity `pause()`.

## Identity and data rules

- Never sent: names, email, phone, makerspace names, item names, free text, QR payloads, tokens, server ids
  in properties, request/response bodies or headers.
- Pseudonymous user id = lowercase hex SHA-256 of `"<origin>|<user id>"`, where origin is
  `scheme://host[:port]` lowercased with no trailing slash. Set on sign-in (Firebase `setUserID`, PostHog
  `identify` with only `role_kind` and `platform`, Sentry `user.id` only); cleared on sign-out.
- Super properties: `platform` = `ios`, `app_version`, `build_type` (`debug`/`release`), `deployment` (first 12
  hex of SHA-256 of the origin), `role_kind` (`member`, or `staff` with native staff authority and staff actions
  in the selected makerspace).
- Sentry: `sendDefaultPii = false`, no screenshots or view hierarchy, no failed-request capture, no trace
  headers added to server requests (`tracePropagationTargets = []`). `beforeSend`, `beforeBreadcrumb` and
  `beforeSendSpan` (`TelemetryScrubber`) drop Authorization, Cookie, X-Makerspace-Id, query strings, fragments
  and bodies, and replace numeric, UUID and opaque-token path segments with `{id}`. Environment = brand
  `sentry_environment` or build type; release = `<bundle id>@<version>+<build>`.
- Clarity paused on: sign-in, MFA, the emailed sign-in code, the staff step-up, phone sign-in, sign-up, password reset/change, recovery codes, email
  verification, account deletion, payments and payment detail, staff QR scanner and evidence camera,
  membership card and event ticket. There are no WebViews.

## Events

Names are identical on Android (snake_case, ≤ 40 characters; properties are strings, numbers or booleans).
Fired from view models at the server-confirmed success point, except `*_started`.

`app_open`, `screen_view{screen}`, `onboarding_completed`, `server_connected{locked}`, `sign_in_started{method}`,
`sign_in_succeeded{method}`, `sign_in_failed{method, code}`, `mfa_challenge_shown{kind: enrollment|verification}`,
`sign_up_started`, `sign_up_completed`, `password_reset_requested`, `sign_out{scope: device|everywhere}`,
`makerspace_switched`, `inventory_searched{has_query}`, `hardware_request_submitted{item_count}`, `loan_renewed`,
`booking_created`, `booking_cancelled`, `event_registered`, `event_registration_cancelled`, `ticket_opened`,
`payment_started{vendor}`, `payment_finished{vendor, outcome: paid|pending|cancelled|failed|unavailable}`,
`receipt_downloaded`, `push_permission_result{granted}`, `push_opened{feature}`, `deep_link_opened{kind}`,
`staff_request_decided{decision: accepted|rejected}`, `staff_item_issued`, `staff_item_returned`,
`staff_direct_handout`, `qr_scanned{context: handover_container|handover_equipment|event_check_in}`,
`event_check_in`, `account_deletion_started`, `account_deletion_completed`,
`consent_updated{analytics, replay, diagnostics}`.

0.12.0 auth and staff flows (owned here; Android uses the same names): `mfa_challenge_shown{kind}` also
takes `email_code` for the unusual-sign-in emailed code; `username_set` (the blocking "Choose your
username" step succeeded); `update_required{source: config|server}` (the published minimum, or a 426
from any call); `staff_step_up_started`, `staff_step_up_succeeded`, `staff_step_up_failed{code}`,
`staff_signed_out` ("Leave staff tools"). The makerspace slug typed for the step-up is never sent.

`method` ∈ password, google, apple, oidc, phone, passkey; `code` = server error `code`, else HTTP status class
(`4xx`), else `network`. `feature`/`kind` are destination route templates.

Screen names (`TelemetryScreen`): `intro`, `consent_prompt`, `server_connect`, `sign_in`, `mfa`, `phone_sign_in`,
`sign_up`, `password_reset`, `password_change`, `recovery_codes`, `email_verification`, `email_code`, `username`,
`update_required`, `staff_step_up`, `home`, `inventory`,
`inventory_detail`, `activity`, `inbox`, `profile`, `bookings`, `spaces`, `space_detail`, `booking_detail`,
`event_detail`, `event_ticket`, `membership_card`, `profile_edit`, `communication_preferences`, `payments`,
`payment_detail`, `account_security`, `account_deletion`, `notification_settings`, `app_guide`,
`privacy_analytics`, `staff_tools`, `staff_scan`, `staff_evidence`.

## Code

`SpaceWorks/Telemetry/`: `Telemetry` (the facade: `track`, `screen`, `identify`, `reset`, `setConsent`; consent
store; gating), `TelemetryProviders` (one adapter per SDK), `TelemetryScrubber`, `TelemetryViews` (consent
sheet, Privacy and analytics, `.telemetryScreen(_:)`). Feature code calls only `Telemetry.shared`.
`SpaceWorksTests/TelemetryTests.swift` uses a recording adapter: no provider before consent, withdrawal stops,
scrubbing, stable non-raw identity, demo and Debug send nothing, absent config hides the UI, event names valid.

## Verify with fake keys

1. `SPACEWORKS_TELEMETRY_DEBUG=1 SPACEWORKS_SENTRY_DSN=https://0123456789abcdef0123456789abcdef@o0.ingest.sentry.io/1 SPACEWORKS_POSTHOG_API_KEY=phc_fake0123456789 SPACEWORKS_CLARITY_PROJECT_ID=fakeproj python3 scripts/generate.py`, then build Debug.
2. With a proxy (for example Proxyman or Charles) confirm no request to `*.sentry.io`, `*.posthog.com`,
   `*.clarity.ms` or Google Analytics hosts before consent, and none for a purpose that is off.
3. Allow a purpose: its host is contacted (the vendor rejects the fake id, which is fine). Withdraw it in
   Profile → Privacy and analytics: requests stop.
4. Only a real project proves ingestion, dashboards, retention and deletion. Regenerate without the variables
   afterwards; never commit real identifiers you do not intend to ship.
