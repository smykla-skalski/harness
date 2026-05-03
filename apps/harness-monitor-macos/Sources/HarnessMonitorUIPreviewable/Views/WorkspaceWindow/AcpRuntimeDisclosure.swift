import Foundation
import HarnessMonitorKit
import SwiftUI

enum AcpRuntimeDisclosureMotionPolicy {
  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.18)
  }
}

struct AcpRuntimeDisclosure: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  let runtimeState: AcpAgentRuntimeState
  let inspectStatus: AcpRuntimeInspectStatus

  @SceneStorage private var isExpanded: Bool

  init(runtimeState: AcpAgentRuntimeState, inspectStatus: AcpRuntimeInspectStatus) {
    self.runtimeState = runtimeState
    self.inspectStatus = inspectStatus
    _isExpanded = SceneStorage(
      wrappedValue: false,
      Self.sceneStorageKey(
        sessionID: runtimeState.sessionId,
        agentID: runtimeState.agentId
      )
    )
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      detailContent
        .padding(.top, HarnessMonitorTheme.spacingXS)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.agentRuntimeDisclosureContent(runtimeState.agentId)
        )
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("Runtime details")
          .scaledFont(.caption.weight(.semibold))
        if runtimeState.hasInspect == false {
          Text(inspectStatus.shortLabel)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.agentRuntimeDisclosure(runtimeState.agentId)
      )
      .accessibilityLabel("ACP runtime details")
      .accessibilityValue(accessibilityStatus)
    }
    .accessibilityElement(children: .contain)
    .animation(
      AcpRuntimeDisclosureMotionPolicy.animation(reduceMotion: reduceMotion),
      value: isExpanded
    )
  }

  static func sceneStorageKey(sessionID: String, agentID: String) -> String {
    "harness.workspace.runtime-disclosure.\(storageKeyComponent(sessionID)).\(storageKeyComponent(agentID))"
  }

  @ViewBuilder private var detailContent: some View {
    if let inspect = runtimeState.inspect {
      InspectorFactGrid(
        facts: [
          .init(title: "PID", value: inspect.pid.formatted()),
          .init(title: "PGID", value: inspect.pgid.formatted()),
          .init(title: "Uptime", value: formatRuntimeUptime(milliseconds: inspect.uptimeMs)),
          .init(title: "Sampled", value: sampledAtLabel),
          .init(
            title: "Last Update",
            value: formatTimestamp(inspect.lastUpdateAt, configuration: dateTimeConfiguration)
          ),
          .init(
            title: "Last Client Call",
            value: formatTimestamp(inspect.lastClientCallAt, configuration: dateTimeConfiguration)
          ),
          .init(title: "Terminals", value: inspect.terminalCount.formatted()),
        ]
      )
    } else {
      Text(inspectStatus.detail)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private static func storageKeyComponent(_ value: String) -> String {
    Data(value.utf8).map { byte in
      String(format: "%02x", byte)
    }.joined()
  }

  private var accessibilityStatus: String {
    runtimeState.hasInspect ? "Sampled \(sampledAtLabel)" : inspectStatus.accessibilityValue
  }

  private var sampledAtLabel: String {
    guard let sampledAt = runtimeState.inspectSampledAt else {
      return "n/a"
    }
    return formatTimestamp(sampledAt, configuration: dateTimeConfiguration)
  }
}

private func formatRuntimeUptime(milliseconds: UInt64) -> String {
  let totalSeconds = milliseconds / 1000
  if totalSeconds < 60 {
    return "\(totalSeconds)s"
  }
  if totalSeconds < 3600 {
    return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
  }
  let hours = totalSeconds / 3600
  let minutes = (totalSeconds % 3600) / 60
  return "\(hours)h \(minutes)m"
}
