import HarnessMonitorKit
import SwiftData

@MainActor
enum HarnessMonitorAppStoreFactory {
  private enum PreviewHostBridgeEnvironment {
    static let capabilitiesKey = "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_CAPABILITIES"
    static let reconfigureKey = "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_RECONFIGURE"
    static let runningKey = "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_RUNNING"
    static let codexStartKey = "HARNESS_MONITOR_PREVIEW_CODEX_START"
    static let socketPath = "/tmp/harness-preview-bridge.sock"
    static let startedAt = "2026-04-11T10:00:00Z"
  }

  private enum SupervisorSeedScenario: String {
    case stuckAgent = "stuck-agent"

    init?(environment: HarnessMonitorEnvironment) {
      let rawValue = environment.values["HARNESS_MONITOR_SUPERVISOR_SEED_SNAPSHOT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard let rawValue, !rawValue.isEmpty else {
        return nil
      }
      self.init(rawValue: rawValue)
    }

    var mode: PreviewDaemonController.Mode {
      switch self {
      case .stuckAgent:
        .supervisorStuckAgent
      }
    }
  }

  private enum PreviewScenarioOverride: String {
    case dashboardLanding = "dashboard-landing"
    case dashboard
    case cockpit
    case emptyCockpit = "empty-cockpit"
    case toolbarCountRegression = "toolbar-count-regression"
    case agentTuiOverflow = "agent-tui-overflow"
    case taskDrop = "task-drop"
    case offlineCached = "offline-cached"
    case overflow
    case empty

    init?(environment: HarnessMonitorEnvironment) {
      let rawValue = environment.values["HARNESS_MONITOR_PREVIEW_SCENARIO"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard let rawValue, !rawValue.isEmpty else {
        return nil
      }
      self.init(rawValue: rawValue)
    }

    var scenario: HarnessMonitorPreviewStoreFactory.Scenario {
      switch self {
      case .dashboardLanding:
        .dashboardLanding
      case .dashboard:
        .dashboardLoaded
      case .cockpit:
        .cockpitLoaded
      case .emptyCockpit:
        .emptyCockpit
      case .toolbarCountRegression:
        .toolbarCountRegression
      case .agentTuiOverflow:
        .agentTuiOverflow
      case .taskDrop:
        .taskDropCockpit
      case .offlineCached:
        .offlineCached
      case .overflow:
        .sidebarOverflow
      case .empty:
        .empty
      }
    }
  }

  private static let testActionDelayKey = "HARNESS_MONITOR_TEST_ACTION_DELAY_MS"

  static func makeStore(
    environment: HarnessMonitorEnvironment = .current,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) -> HarnessMonitorStore {
    let previewHostBridgeOverride = previewHostBridgeOverride(environment: environment)
    let previewCodexStartBehavior = previewCodexStartBehavior(environment: environment)
    let previewActionDelay = previewActionDelay(environment: environment)
    let supervisorSeedScenario = SupervisorSeedScenario(environment: environment)
    if let previewScenario = PreviewScenarioOverride(environment: environment) {
      return HarnessMonitorPreviewStoreFactory.makeStore(
        for: previewScenario.scenario,
        hostBridgeOverride: previewHostBridgeOverride,
        codexStartBehavior: previewCodexStartBehavior,
        actionDelay: previewActionDelay,
        modelContainer: modelContainer,
        persistenceError: persistenceError,
        voiceCapture: previewVoiceCapture(environment: environment)
      )
    }

    switch HarnessMonitorLaunchMode(environment: environment) {
    case .live:
      let ownership = DaemonOwnership(environment: environment)
      return HarnessMonitorStore(
        daemonController: DaemonController(
          environment: environment,
          ownership: ownership
        ),
        daemonOwnership: ownership,
        modelContainer: modelContainer,
        persistenceError: persistenceError
      )
    case .preview:
      if let supervisorSeedScenario {
        return HarnessMonitorStore(
          daemonController: PreviewDaemonController(
            mode: supervisorSeedScenario.mode,
            hostBridgeOverride: previewHostBridgeOverride,
            actionDelay: previewActionDelay,
            codexStartBehavior: previewCodexStartBehavior
          ),
          voiceCapture: previewVoiceCapture(environment: environment),
          modelContainer: modelContainer,
          persistenceError: persistenceError
        )
      }
      return HarnessMonitorStore(
        daemonController: PreviewDaemonController(
          previewFixtureSetRawValue: environment.values["HARNESS_MONITOR_PREVIEW_FIXTURE_SET"],
          hostBridgeOverride: previewHostBridgeOverride,
          actionDelay: previewActionDelay,
          codexStartBehavior: previewCodexStartBehavior
        ),
        voiceCapture: previewVoiceCapture(environment: environment),
        modelContainer: modelContainer,
        persistenceError: persistenceError
      )
    case .empty:
      if let supervisorSeedScenario {
        return HarnessMonitorStore(
          daemonController: PreviewDaemonController(
            mode: supervisorSeedScenario.mode,
            hostBridgeOverride: previewHostBridgeOverride,
            actionDelay: previewActionDelay,
            codexStartBehavior: previewCodexStartBehavior
          ),
          voiceCapture: previewVoiceCapture(environment: environment),
          modelContainer: modelContainer,
          persistenceError: persistenceError
        )
      }
      return HarnessMonitorStore(
        daemonController: PreviewDaemonController(
          mode: .empty,
          hostBridgeOverride: previewHostBridgeOverride,
          actionDelay: previewActionDelay,
          codexStartBehavior: previewCodexStartBehavior
        ),
        voiceCapture: previewVoiceCapture(environment: environment),
        modelContainer: modelContainer,
        persistenceError: persistenceError
      )
    }
  }

  private static func previewActionDelay(
    environment: HarnessMonitorEnvironment
  ) -> Duration? {
    guard
      let rawValue = environment.values[testActionDelayKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty,
      let milliseconds = Int(rawValue),
      milliseconds > 0
    else {
      return nil
    }
    return .milliseconds(milliseconds)
  }

  private static func previewVoiceCapture(
    environment: HarnessMonitorEnvironment
  ) -> any VoiceCaptureProviding {
    let failure = environment.values["HARNESS_MONITOR_PREVIEW_VOICE_FAILURE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let failure, !failure.isEmpty else {
      return PreviewVoiceCaptureService()
    }

    switch failure.lowercased() {
    case "speech-assets":
      let localeIdentifier =
        environment.values["HARNESS_MONITOR_PREVIEW_VOICE_LOCALE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let locale: String
      if let localeIdentifier, !localeIdentifier.isEmpty {
        locale = localeIdentifier
      } else {
        locale = "en_PL"
      }
      return PreviewVoiceCaptureService(
        behavior: .failure(NativeVoiceCaptureError.speechAssetsUnavailable(locale))
      )
    default:
      return PreviewVoiceCaptureService(
        behavior: .failure(PreviewVoiceCaptureService.PreviewFailure(message: failure))
      )
    }
  }

  private static func previewHostBridgeOverride(
    environment: HarnessMonitorEnvironment
  ) -> PreviewHostBridgeOverride? {
    let rawCapabilities = environment.values[PreviewHostBridgeEnvironment.capabilitiesKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let rawBehavior = environment.values[PreviewHostBridgeEnvironment.reconfigureKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let rawRunning = environment.values[PreviewHostBridgeEnvironment.runningKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    guard
      rawCapabilities?.isEmpty == false
        || rawBehavior?.isEmpty == false
        || rawRunning?.isEmpty == false
    else {
      return nil
    }

    let running =
      switch rawRunning {
      case "0", "false", "no":
        false
      default:
        true
      }

    var capabilities: [String: HostBridgeCapabilityManifest] = [:]
    if running, let rawCapabilities {
      for capability in rawCapabilities.split(separator: ",") {
        let name = capability.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
          continue
        }
        capabilities[name] = previewHostBridgeCapabilityManifest(for: name)
      }
    }

    let behavior =
      PreviewHostBridgeReconfigureBehavior(rawValue: rawBehavior ?? "unsupported") ?? .unsupported

    return PreviewHostBridgeOverride(
      bridgeStatus: BridgeStatusReport(
        running: running,
        socketPath: PreviewHostBridgeEnvironment.socketPath,
        pid: 4242,
        startedAt: PreviewHostBridgeEnvironment.startedAt,
        uptimeSeconds: 600,
        capabilities: capabilities
      ),
      reconfigureBehavior: behavior
    )
  }

  private static func previewCodexStartBehavior(
    environment: HarnessMonitorEnvironment
  ) -> PreviewCodexStartBehavior {
    let rawValue = environment.values[PreviewHostBridgeEnvironment.codexStartKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return PreviewCodexStartBehavior(rawValue: rawValue ?? "") ?? .unsupported
  }

  private static func previewHostBridgeCapabilityManifest(
    for capability: String
  ) -> HostBridgeCapabilityManifest {
    switch capability {
    case "codex":
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "websocket",
        endpoint: "ws://127.0.0.1:4545"
      )
    case "agent-tui":
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "unix",
        endpoint: PreviewHostBridgeEnvironment.socketPath,
        metadata: ["active_sessions": "0"]
      )
    default:
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "preview"
      )
    }
  }
}
