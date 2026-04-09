import SwiftUI

struct AuditBuildDisplayState {
  let auditRunID: String
  let auditLabel: String
  let launchMode: String
  let perfScenario: String
  let previewScenario: String
  let buildCommit: String
  let buildDirty: String
  let buildFingerprint: String
  let buildStartedAtUTC: String
  let expectedCommit: String?
  let expectedDirty: String?
  let expectedFingerprint: String?
  let expectedBuildStartedAtUTC: String?

  var status: String {
    guard let expectedCommit, let expectedDirty, let expectedFingerprint else {
      return "bundle-only"
    }
    guard
      expectedCommit == buildCommit,
      expectedDirty == buildDirty,
      expectedFingerprint == buildFingerprint
    else {
      return "mismatch"
    }
    return "match"
  }

  var showsVisibleBadge: Bool {
    auditRunID != "none"
      || auditLabel != "none"
      || expectedFingerprint != nil
      || expectedBuildStartedAtUTC != nil
  }

  var badgeTitle: String {
    switch status {
    case "match":
      "Audit build OK"
    case "mismatch":
      "Audit build mismatch"
    default:
      "Audit build"
    }
  }

  var badgeSubtitle: String {
    [
      shortToken(buildCommit),
      shortToken(buildFingerprint),
      perfScenario,
    ]
    .filter { !$0.isEmpty && $0 != "none" && $0 != "unknown" }
    .joined(separator: "  ")
  }

  var badgeFootnote: String {
    if status == "mismatch" {
      let expectedSummary = [shortToken(expectedCommit), shortToken(expectedFingerprint)]
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
      return expectedSummary.isEmpty ? "" : "expected \(expectedSummary)"
    }

    let runLabel = auditLabel == "none" ? auditRunID : auditLabel
    let buildTime = shortTimestamp(buildStartedAtUTC)
    return [runLabel, buildTime]
      .filter { !$0.isEmpty && $0 != "none" && $0 != "unknown" }
      .joined(separator: "  ")
  }

  var accessibilityValue: String {
    [
      "auditRunID=\(auditRunID)",
      "auditLabel=\(auditLabel)",
      "auditStatus=\(status)",
      "buildCommit=\(buildCommit)",
      "buildDirty=\(buildDirty)",
      "buildFingerprint=\(buildFingerprint)",
      "buildStartedAtUTC=\(buildStartedAtUTC)",
      "expectedBuildCommit=\(expectedCommit ?? "none")",
      "expectedBuildDirty=\(expectedDirty ?? "none")",
      "expectedBuildFingerprint=\(expectedFingerprint ?? "none")",
      "expectedBuildStartedAtUTC=\(expectedBuildStartedAtUTC ?? "none")",
      "launchMode=\(launchMode)",
      "perfScenario=\(perfScenario)",
      "previewScenario=\(previewScenario)",
    ].joined(separator: ", ")
  }

  private func shortToken(_ value: String?) -> String {
    guard let value else {
      return ""
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "unknown", trimmed != "none" else {
      return ""
    }
    return String(trimmed.prefix(8))
  }

  private func shortTimestamp(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 16 else {
      return trimmed
    }
    return String(trimmed.prefix(16))
  }
}

struct AuditBuildBadge: View {
  let state: AuditBuildDisplayState

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(state.badgeTitle)
        .font(.caption.weight(.semibold))
      if !state.badgeSubtitle.isEmpty {
        Text(state.badgeSubtitle)
          .font(.caption2.monospaced())
      }
      if !state.badgeFootnote.isEmpty {
        Text(state.badgeFootnote)
          .font(.caption2)
      }
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .harnessFloatingControlGlass(
      cornerRadius: 12,
      tint: HarnessMonitorTheme.ink,
      prominence: .subdued
    )
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(state.accessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.auditBuildBadge)
  }
}
