import SwiftUI

public struct AuditBuildDisplayState {
  public let auditRunID: String
  public let auditLabel: String
  public let launchMode: String
  public let perfScenario: String
  public let previewScenario: String
  public let buildCommit: String
  public let buildDirty: String
  public let buildFingerprint: String
  public let buildStartedAtUTC: String
  public let expectedCommit: String?
  public let expectedDirty: String?
  public let expectedFingerprint: String?
  public let expectedBuildStartedAtUTC: String?

  public init(
    auditRunID: String,
    auditLabel: String,
    launchMode: String,
    perfScenario: String,
    previewScenario: String,
    buildCommit: String,
    buildDirty: String,
    buildFingerprint: String,
    buildStartedAtUTC: String,
    expectedCommit: String?,
    expectedDirty: String?,
    expectedFingerprint: String?,
    expectedBuildStartedAtUTC: String?
  ) {
    self.auditRunID = auditRunID
    self.auditLabel = auditLabel
    self.launchMode = launchMode
    self.perfScenario = perfScenario
    self.previewScenario = previewScenario
    self.buildCommit = buildCommit
    self.buildDirty = buildDirty
    self.buildFingerprint = buildFingerprint
    self.buildStartedAtUTC = buildStartedAtUTC
    self.expectedCommit = expectedCommit
    self.expectedDirty = expectedDirty
    self.expectedFingerprint = expectedFingerprint
    self.expectedBuildStartedAtUTC = expectedBuildStartedAtUTC
  }

  public var status: String {
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

  public var showsVisibleBadge: Bool {
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

  public var accessibilityValue: String {
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

public struct AuditBuildBadge: View {
  public let state: AuditBuildDisplayState

  public init(state: AuditBuildDisplayState) {
    self.state = state
  }

  public var body: some View {
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
