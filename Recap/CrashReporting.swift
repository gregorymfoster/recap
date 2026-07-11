import RecapCore
import Sentry

/// Crash-only Sentry reporting, prod builds only.
///
/// Dev builds (`com.gregfoster.recap.dev`) never start the SDK at all — the
/// same pattern as the Sparkle updater being `nil` in dev — so dev sessions
/// can't pollute prod issues.
///
/// Local-first privacy posture: crashes only. Tracing, breadcrumbs, network
/// capture, swizzling, and PII are all disabled, and `beforeSend` strips
/// breadcrumbs as defense in depth. No transcript, note, or title text ever
/// passes through this SDK.
enum CrashReporting {
    static func start() {
        guard !AppIdentity.isDevBuild else { return }
        SentrySDK.start { options in
            options.dsn = "https://9294190d6aa5cfb6f872150bbe1000e4@o4511673711198208.ingest.us.sentry.io/4511718270697472"
            options.environment = "production"
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkTracking = false
            options.enableSwizzling = false
            options.sendDefaultPii = false
            options.beforeSend = { event in
                event.breadcrumbs = nil
                return event
            }
        }
    }
}
