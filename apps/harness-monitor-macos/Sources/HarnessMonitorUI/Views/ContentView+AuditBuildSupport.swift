import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

enum ContentToolbarLayoutWidth {
  static let minimumWidth: CGFloat = 320
  static let defaultWidth: CGFloat = 1_000
  // The toolbar only changes meaningfully at coarse width buckets. Snapping
  // more aggressively avoids feeding detail-column layout jitter back into the
  // split-view shell during cockpit transitions.
  static let measurementQuantum: CGFloat = 32

  static func normalized(_ width: CGFloat) -> CGFloat {
    let clampedWidth = max(width, minimumWidth)
    return (clampedWidth / measurementQuantum).rounded() * measurementQuantum
  }
}

extension ContentView {
  var auditBuildAccessibilityValue: String? {
    auditBuildState?.accessibilityValue
  }

  var auditBuildBadgeState: AuditBuildDisplayState? {
    guard let auditBuildState else {
      return nil
    }
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
      || auditBuildState.status == "mismatch"
    {
      return auditBuildState
    }
    return nil
  }

  static func resolveAuditBuildState() -> AuditBuildDisplayState? {
    guard HarnessMonitorUITestEnvironment.isEnabled else {
      return nil
    }

    let info = Bundle.main.infoDictionary ?? [:]
    let environment = ProcessInfo.processInfo.environment
    let provenance = bundleBuildProvenance()

    return AuditBuildDisplayState(
      auditRunID: environment["HARNESS_MONITOR_AUDIT_RUN_ID"] ?? "none",
      auditLabel: environment["HARNESS_MONITOR_AUDIT_LABEL"] ?? "none",
      launchMode: environment["HARNESS_MONITOR_LAUNCH_MODE"] ?? "live",
      perfScenario: environment["HARNESS_MONITOR_PERF_SCENARIO"] ?? "none",
      previewScenario: environment["HARNESS_MONITOR_PREVIEW_SCENARIO"] ?? "default",
      buildCommit: provenance["HarnessMonitorBuildGitCommit"]
        ?? stringValue(in: info, key: "HarnessMonitorBuildGitCommit", fallback: "unknown"),
      buildDirty: provenance["HarnessMonitorBuildGitDirty"]
        ?? stringValue(in: info, key: "HarnessMonitorBuildGitDirty", fallback: "unknown"),
      buildFingerprint: provenance["HarnessMonitorBuildWorkspaceFingerprint"]
        ?? stringValue(
          in: info,
          key: "HarnessMonitorBuildWorkspaceFingerprint",
          fallback: "unknown"
        ),
      buildStartedAtUTC: provenance["HarnessMonitorBuildStartedAtUTC"]
        ?? stringValue(
          in: info,
          key: "HarnessMonitorBuildStartedAtUTC",
          fallback: "unknown"
        ),
      expectedCommit: environment["HARNESS_MONITOR_AUDIT_GIT_COMMIT"],
      expectedDirty: environment["HARNESS_MONITOR_AUDIT_GIT_DIRTY"],
      expectedFingerprint: environment["HARNESS_MONITOR_AUDIT_WORKSPACE_FINGERPRINT"],
      expectedBuildStartedAtUTC: environment["HARNESS_MONITOR_AUDIT_BUILD_STARTED_AT_UTC"]
    )
  }

  static func stringValue(
    in infoDictionary: [String: Any],
    key: String,
    fallback: String
  ) -> String {
    guard let value = infoDictionary[key] as? String else {
      return fallback
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  static func bundleBuildProvenance() -> [String: String] {
    guard
      let url = Bundle.main.url(
        forResource: "HarnessMonitorBuildProvenance",
        withExtension: "plist"
      ),
      let dictionary = NSDictionary(contentsOf: url) as? [String: Any]
    else {
      return [:]
    }

    return dictionary.compactMapValues { value in
      guard let stringValue = value as? String else {
        return nil
      }
      let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}
