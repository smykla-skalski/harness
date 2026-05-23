import Foundation
import SwiftData

extension HarnessMonitorStore {
  public var selectedAcpInspectAgents: [AcpAgentInspectSnapshot] {
    selectedAcpInspectState?.agents ?? []
  }

  public var selectedAcpInspectObservedAt: Date? {
    selectedAcpInspectState?.sampledAt
  }

  public var showConfirmation: Bool {
    get { pendingConfirmation != nil }
    set { if !newValue { cancelConfirmation() } }
  }

  var maintainsLiveDaemonObservation: Bool {
    !(daemonController is PreviewDaemonController)
  }

  public convenience init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil,
    reviewFilePreviewStore: ReviewFilePreviewStore = ReviewFilePreviewStore(
      directory: HarnessMonitorPaths.reviewFilePreviewCacheRoot()
    )
  ) {
    self.init(
      daemonController: daemonController,
      fileViewer: fileViewer,
      voiceCapture: NativeVoiceCaptureService(),
      daemonOwnership: daemonOwnership,
      modelContainer: modelContainer,
      persistenceError: persistenceError,
      cacheService: cacheService,
      taskBoardSettingsWorker: TaskBoardSettingsWorker(),
      reviewFilePreviewStore: reviewFilePreviewStore
    )
  }

  func setSupervisorRuntimeState(_ state: SupervisorRuntimeState) {
    guard supervisorRuntimeState != state else { return }
    supervisorRuntimeState = state
  }
}
