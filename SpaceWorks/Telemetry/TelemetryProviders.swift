import Clarity
import FirebaseAnalytics
import FirebaseCore
import Foundation
import PostHog
import Sentry

extension Telemetry {
    /// Real adapters for every configured provider. Nothing is initialised here: an adapter's SDK starts
    /// only when the facade starts it after consent.
    static func live(config: TelemetryConfig = .bundled, settings: UserDefaults = .standard) -> Telemetry {
        var adapters: [any TelemetryAdapter] = []
        if config.firebase { adapters.append(FirebaseTelemetryAdapter()) }
        if let key = config.postHogKey { adapters.append(PostHogTelemetryAdapter(apiKey: key, host: config.postHogHost)) }
        if let id = config.clarityProjectID { adapters.append(ClarityTelemetryAdapter(projectID: id)) }
        if let dsn = config.sentryDSN { adapters.append(SentryTelemetryAdapter(dsn: dsn, environment: config.sentryEnvironment, tracesSampleRate: config.tracesSampleRate)) }
        return Telemetry(config: config, adapters: adapters, settings: settings)
    }
}

/// Firebase Analytics without ad-identifier support (`FirebaseAnalyticsCore`). Collection is off in
/// Info.plist and switched on only after consent; `FirebaseApp.configure()` runs lazily at that point.
@MainActor final class FirebaseTelemetryAdapter: TelemetryAdapter {
    let purpose = TelemetryPurpose.analytics
    func start(superProperties: [String: TelemetryValue]) {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        Analytics.setAnalyticsCollectionEnabled(true)
        setSuperProperties(superProperties)
    }
    func stop() {
        Analytics.setAnalyticsCollectionEnabled(false)
        Analytics.setUserID(nil)
        Analytics.resetAnalyticsData()
    }
    func track(_ name: String, properties: [String: TelemetryValue]) {
        Analytics.logEvent(name, parameters: properties.mapValues(\.value))
    }
    func screen(_ screen: TelemetryScreen) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenName: screen.rawValue, AnalyticsParameterScreenClass: screen.rawValue])
    }
    func setSuperProperties(_ properties: [String: TelemetryValue]) {
        Analytics.setDefaultEventParameters(properties.filter { $0.key != "role_kind" }.mapValues(\.value))
        Analytics.setUserProperty(properties["role_kind"].map { "\($0.value)" }, forName: "role_kind")
    }
    func identify(_ user: TelemetryUser) {
        Analytics.setUserID(user.pseudonymousID)
        Analytics.setUserProperty(user.roleKind.rawValue, forName: "role_kind")
    }
    func reset() {
        Analytics.setUserID(nil)
        Analytics.setUserProperty(nil, forName: "role_kind")
    }
}

/// PostHog product analytics: the same events; autocapture, session replay, surveys and feature flags off.
@MainActor final class PostHogTelemetryAdapter: TelemetryAdapter {
    let purpose = TelemetryPurpose.analytics
    private let apiKey: String
    private let host: String
    private var configured = false
    private var superProperties: [String: TelemetryValue] = [:]
    init(apiKey: String, host: String) { self.apiKey = apiKey; self.host = host }
    func start(superProperties: [String: TelemetryValue]) {
        if configured { PostHogSDK.shared.optIn() } else {
            let config = PostHogConfig(projectToken: apiKey, host: host)
            config.captureApplicationLifecycleEvents = true
            config.captureScreenViews = false
            config.captureElementInteractions = false
            config.sessionReplay = false
            config.preloadFeatureFlags = false
            config.sendFeatureFlagEvent = false
            config.personProfiles = .identifiedOnly
            config.surveys = false
            config.errorTrackingConfig.autoCapture = false // Sentry is the only crash handler.
            PostHogSDK.shared.setup(config)
            configured = true
        }
        setSuperProperties(superProperties)
    }
    func stop() {
        PostHogSDK.shared.optOut()
        PostHogSDK.shared.reset()
    }
    func track(_ name: String, properties: [String: TelemetryValue]) {
        PostHogSDK.shared.capture(name, properties: properties.mapValues(\.value))
    }
    func screen(_ screen: TelemetryScreen) { PostHogSDK.shared.screen(screen.rawValue) }
    func setSuperProperties(_ properties: [String: TelemetryValue]) {
        superProperties = properties
        PostHogSDK.shared.register(properties.mapValues(\.value))
    }
    func identify(_ user: TelemetryUser) {
        // No person properties beyond role_kind and platform.
        PostHogSDK.shared.identify(user.pseudonymousID, userProperties: ["role_kind": user.roleKind.rawValue, "platform": "ios"], userPropertiesSetOnce: nil)
    }
    func reset() {
        PostHogSDK.shared.reset()
        PostHogSDK.shared.register(superProperties.filter { $0.key != "role_kind" }.mapValues(\.value))
    }
}

/// Microsoft Clarity session replay with strict masking; paused on sensitive screens and in the demo.
@MainActor final class ClarityTelemetryAdapter: TelemetryAdapter {
    let purpose = TelemetryPurpose.replay
    private let projectID: String
    private var initialized = false
    private var running = false
    private var sensitive = false
    init(projectID: String) { self.projectID = projectID }
    func start(superProperties: [String: TelemetryValue]) {
        running = true
        if !initialized {
            // Masking mode is a Clarity project setting: set it to Strict (docs/TELEMETRY.md).
            initialized = ClaritySDK.initialize(config: ClarityConfig(projectId: projectID))
        }
        apply()
    }
    func stop() { running = false; apply() }
    func screen(_ screen: TelemetryScreen) { if running { _ = ClaritySDK.setCurrentScreenName(screen.rawValue) } }
    func identify(_ user: TelemetryUser) {}
    func reset() {}
    func setSensitive(_ sensitive: Bool) { self.sensitive = sensitive; apply() }
    private func apply() {
        guard initialized else { return }
        if running && !sensitive { ClaritySDK.resume() } else { ClaritySDK.pause() }
    }
}

/// Sentry crashes, app hangs and performance traces. Sentry is the only crash handler (no Crashlytics).
@MainActor final class SentryTelemetryAdapter: TelemetryAdapter {
    let purpose = TelemetryPurpose.diagnostics
    private let dsn: String
    private let environment: String?
    private let tracesSampleRate: Double
    /// Read by the scrubber off the main actor; only the pseudonymous id is ever attached.
    nonisolated(unsafe) private static var userID: String?
    init(dsn: String, environment: String?, tracesSampleRate: Double) {
        self.dsn = dsn; self.environment = environment; self.tracesSampleRate = tracesSampleRate
    }
    func start(superProperties: [String: TelemetryValue]) {
        let info = Bundle.main.infoDictionary ?? [:]
        let release = "\(Bundle.main.bundleIdentifier ?? Brand.bundleID)@\(info["CFBundleShortVersionString"] as? String ?? "0")+\(info["CFBundleVersion"] as? String ?? "0")"
        let environment = environment ?? (Telemetry.isDebugBuild ? "debug" : "release")
        SentrySDK.start { options in
            options.dsn = self.dsn
            options.environment = environment
            options.releaseName = release
            options.tracesSampleRate = NSNumber(value: self.tracesSampleRate)
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.enableAppHangTracking = true
            options.enableCaptureFailedRequests = false
            options.tracePropagationTargets = []
            options.beforeSend = { SentryTelemetryAdapter.scrub($0) }
            options.beforeBreadcrumb = { SentryTelemetryAdapter.scrub($0) }
            options.beforeSendSpan = { SentryTelemetryAdapter.scrub($0) }
        }
        setSuperProperties(superProperties)
    }
    func stop() { Self.userID = nil; SentrySDK.close() }
    func setSuperProperties(_ properties: [String: TelemetryValue]) {
        SentrySDK.configureScope { scope in for (key, value) in properties { scope.setTag(value: "\(value.value)", key: key) } }
    }
    func identify(_ user: TelemetryUser) {
        Self.userID = user.pseudonymousID
        SentrySDK.setUser(User(userId: user.pseudonymousID))
    }
    func reset() { Self.userID = nil; SentrySDK.setUser(nil) }

    nonisolated static func scrub(_ event: Event) -> Event? {
        if let request = event.request {
            request.url = request.url.map(TelemetryScrubber.url)
            request.headers = request.headers.map(TelemetryScrubber.headers)
            request.queryString = nil; request.fragment = nil; request.cookies = nil; request.bodySize = nil
        }
        event.user = userID.map { User(userId: $0) }
        event.transaction = event.transaction.map(TelemetryScrubber.path)
        event.breadcrumbs = event.breadcrumbs?.compactMap { scrub($0) }
        event.extra = nil
        return event
    }
    nonisolated static func scrub(_ crumb: Breadcrumb) -> Breadcrumb? {
        crumb.data = crumb.data.map(TelemetryScrubber.data)
        crumb.message = crumb.message.map(TelemetryScrubber.path)
        return crumb
    }
    nonisolated static func scrub(_ span: any Span) -> (any Span)? {
        span.spanDescription = span.spanDescription.map(TelemetryScrubber.path)
        for (key, value) in span.data where key.lowercased().contains("url") || key.lowercased().contains("query") {
            span.removeData(key: key)
            if let text = value as? String, !key.lowercased().contains("query") { span.setData(value: TelemetryScrubber.url(text), key: key) }
        }
        return span
    }
}
