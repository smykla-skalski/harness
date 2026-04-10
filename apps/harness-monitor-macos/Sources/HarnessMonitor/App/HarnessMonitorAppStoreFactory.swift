import HarnessMonitorKit
import SwiftData

@MainActor
enum HarnessMonitorAppStoreFactory {
  private enum PreviewScenarioOverride: String {
    case dashboardLanding = "dashboard-landing"
    case dashboard
    case cockpit
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

  static func makeStore(
    environment: HarnessMonitorEnvironment = .current,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil
  ) -> HarnessMonitorStore {
    if let previewScenario = PreviewScenarioOverride(environment: environment) {
      return HarnessMonitorPreviewStoreFactory.makeStore(
        for: previewScenario.scenario,
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
      return HarnessMonitorStore(
        daemonController: PreviewDaemonController(
          previewFixtureSetRawValue: environment.values["HARNESS_MONITOR_PREVIEW_FIXTURE_SET"]
        ),
        voiceCapture: previewVoiceCapture(environment: environment),
        modelContainer: modelContainer,
        persistenceError: persistenceError
      )
    case .empty:
      return HarnessMonitorStore(
        daemonController: PreviewDaemonController(mode: .empty),
        voiceCapture: previewVoiceCapture(environment: environment),
        modelContainer: modelContainer,
        persistenceError: persistenceError
      )
    }
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
}
