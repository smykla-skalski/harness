import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  var sessionStatusSummaryModel: SessionStatusSummaryModel {
    let chrome = store.contentUI.chrome
    let metrics = store.connectionMetrics
    let sourceTitle: String =
      if snapshot == nil {
        "Loading"
      } else if isLoading || snapshot?.source == nil {
        "Refreshing"
      } else {
        snapshot?.source.rawValue.capitalized ?? "Loading"
      }
    let sourceTint: SessionStatusSourceTint =
      if isLoading || snapshot?.source == nil {
        .tertiary
      } else {
        switch snapshot?.source {
        case .live:
          sessionStatusSourceTint(for: metrics)
        case .cache:
          sessionStatusSourceTint(for: metrics)
        case .catalog:
          .tertiary
        case .none:
          .tertiary
        }
      }
    let connectionSummaryText =
      if metrics.connectedSince != nil {
        if let latency = metrics.transportLatencyMs {
          "Connection: \(metrics.transportKind.title), transport latency \(latency) milliseconds"
        } else if let requestLatency = metrics.requestLatencyMs {
          [
            "Connection: \(metrics.transportKind.title)",
            "transport latency unavailable,",
            "last request latency \(requestLatency) milliseconds",
          ].joined(separator: " ")
        } else {
          "Connection: \(metrics.transportKind.title)"
        }
      } else {
        "Connection: \(connectionTitle)"
      }
    return SessionStatusSummaryModel(
      metrics: metrics,
      sourceTitle: sourceTitle,
      sourceSystemImage: sourceSystemImage,
      sourceTint: sourceTint,
      statusStripState: SessionStatusStripState(
        daemonOwnership: store.daemonOwnership,
        bridgeRunning: store.daemonStatus?.manifest?.hostBridge.running == true,
        mcpStatus: chrome.mcpStatus,
        isMCPRegistryHostEnabled: mcpRegistryHostEnabled
      ),
      connectionSummaryText: connectionSummaryText,
      sessionStatusTitle: summary?.status.title ?? "Loading"
    )
  }

  private func sessionStatusSourceTint(for metrics: ConnectionMetrics) -> SessionStatusSourceTint {
    if metrics.usesMutedConnectionChrome {
      return .disabledConnection
    }
    let quality: ConnectionQuality =
      if metrics.transportLatencyMs != nil {
        metrics.transportQuality
      } else if metrics.requestLatencyMs != nil {
        metrics.requestQuality
      } else {
        .disconnected
      }
    switch quality {
    case .excellent, .good:
      return .success
    case .degraded:
      return .caution
    case .poor, .disconnected:
      return .danger
    }
  }

  var sourceSystemImage: String {
    guard !isLoading, let source = snapshot?.source else {
      return "arrow.clockwise"
    }
    switch source {
    case .live:
      return "bolt.horizontal.circle"
    case .cache:
      return "externaldrive"
    case .catalog:
      return "square.stack.3d.up"
    }
  }

  var connectionTitle: String {
    switch store.connectionState {
    case .idle: "Idle"
    case .connecting: "Connecting"
    case .online: "Online"
    case .offline: "Offline"
    }
  }
}
