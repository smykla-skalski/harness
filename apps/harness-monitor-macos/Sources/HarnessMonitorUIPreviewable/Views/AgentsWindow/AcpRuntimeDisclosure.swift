import HarnessMonitorKit
import SwiftUI

enum AcpRuntimeDisclosureMotionPolicy {
  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.18)
  }
}

struct AcpRuntimeDisclosure: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.harnessDateTimeConfiguration) private var dateTimeConfiguration

  let agentID: String
  let inspect: AcpAgentInspectSnapshot?

  @SceneStorage private var isExpanded: Bool

  init(agentID: String, inspect: AcpAgentInspectSnapshot?) {
    self.agentID = agentID
    self.inspect = inspect
    _isExpanded = SceneStorage(
      wrappedValue: false,
      Self.sceneStorageKey(agentID: agentID)
    )
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      detailContent
        .padding(.top, HarnessMonitorTheme.spacingXS)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentRuntimeDisclosureContent(agentID))
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("Runtime details")
          .scaledFont(.caption.weight(.semibold))
        if inspect == nil {
          Text("Syncing…")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentRuntimeDisclosure(agentID))
    }
    .accessibilityElement(children: .contain)
    .animation(
      AcpRuntimeDisclosureMotionPolicy.animation(reduceMotion: reduceMotion),
      value: isExpanded
    )
  }

  static func sceneStorageKey(agentID: String) -> String {
    "harness.agents.runtime-disclosure.\(HarnessMonitorAccessibility.slug(agentID))"
  }

  @ViewBuilder
  private var detailContent: some View {
    if let inspect {
      InspectorFactGrid(
        facts: [
          .init(title: "PID", value: inspect.pid.formatted()),
          .init(title: "PGID", value: inspect.pgid.formatted()),
          .init(title: "Uptime", value: formatRuntimeUptime(milliseconds: inspect.uptimeMs)),
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
      Text("Waiting for the daemon to publish the latest ACP runtime inspect snapshot.")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
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
