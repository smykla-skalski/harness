import ProjectDescription

/// LaunchServices identity for the agent/audit-isolated Monitor app variant.
///
/// Reads the Tuist manifest variable `TUIST_ISOLATED_BUNDLE_ID` (exported by
/// `Scripts/generate.sh` from `harness_monitor_isolated_bundle_id`) so each
/// build lane gets a bundle id distinct from the developer's running
/// `io.harnessmonitor.app`; otherwise LaunchServices can hand a
/// `xctrace --launch` / `open` off to the registered or running copy and an
/// audit profiles the wrong process. Manifests cannot read arbitrary process
/// environment, so this goes through Tuist's `Environment` (`TUIST_`-prefixed)
/// API. The fallback covers a direct `tuist generate` with no lane environment.
public enum IsolatedAppIdentity {
    public static let fallbackBundleId = "io.harnessmonitor.app.isolated"

    public static var bundleId: String {
        Environment.isolatedBundleId.getString(default: fallbackBundleId)
    }
}
