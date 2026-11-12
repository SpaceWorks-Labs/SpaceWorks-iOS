# Reviewed build dependencies

`Package.resolved` is the Xcode lock resolved on 2026-11-13 (Xcode 27.2) for the owner-authorized
telemetry SDKs (`docs/TELEMETRY.md`): Firebase 13.1.1 (`FirebaseAnalyticsCore` only, which links
`GoogleAppMeasurementCore` and no ad-identifier support), PostHog 3.94.4, Sentry 9.34.0 and Microsoft
Clarity 4.1.2. Firebase 13 needs `app-check` 12, so GoogleSignIn moved from 10.0.0 to 10.1.0 (the first
release that accepts `app-check` 12; no API change used by the app). Every other pin is unchanged from
the previous reviewed lock. Its 31 version/revision pins include the direct and transitive app and
code-generator dependencies; transitive packages that only Firebase products the app does not link use
(gRPC, abseil, leveldb, the Google Ads on-device conversion package) are resolved by SwiftPM but never
linked, and `scripts/audit_bundle.py` refuses a Release bundle that contains ad-identifier code.
SHA-256: `6301f972b230d4510068e13e4df7082c7a6e094bf19023781b434ea2920dd142`.

Large clones can be served from local shallow mirrors without changing the lock: put a bare
`git clone --bare --depth 1 --branch <tag>` under `.tools/mirrors/` (ignored) and list it in the
generated workspace's `xcshareddata/swiftpm/configuration/mirrors.json`. The lock still records the
upstream URL and revision.

Following [Apple's CI guidance](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows),
after generating the Xcode project run `python3 scripts/dependency_lock.py stage`.
Xcode builds use `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`.
`python3 scripts/dependency_lock.py check` rejects any byte change to the resulting workspace lock.
CI caches include the canonical lock's hash and archive both the observed lock and verification.
The generated project remains ignored; do not commit a generated Xcode project to retain the lock.

For an intentional dependency update, change the declared exact versions, resolve explicitly on
the pinned Xcode installation in a reviewed development checkout, inspect every changed version,
revision and upstream repository, then replace this canonical lock. Run the complete source/native,
device-profile and unsigned Release/resource gates. Never accept an automatically rewritten lock,
silently update a package, or treat an SDK compile as live provider/backend verification.

`build-tools.json` records XcodeGen 2.46.0 and librsvg 2.62.3 from the actual published installation
log. CI checks these versions after installation and records actual executable version output;
it fails closed if a future Homebrew install selects a different version. This does not promise
that Homebrew will retain an older formula. Review a deliberate toolchain update and its generated
assets instead of upgrading the expected version merely to make a check pass. Xcode 26.2 remains
the separately pinned Apple toolchain.

Dependencies and supplied fonts/assets retain their own applicable licenses. This file grants no
additional license or embedding rights and does not choose an application repository license.
