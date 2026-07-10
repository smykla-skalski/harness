import Foundation
import SwiftData

extension HarnessMonitorStore {
  public var apiClient: (any HarnessMonitorClientProtocol)? { client }

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
    remoteDaemonServices: RemoteDaemonServices? = nil,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil,
    reviewFilePreviewStore: ReviewFilePreviewStore = ReviewFileStoreDefaults.preview(),
    reviewFilePatchStore: ReviewFilePatchStore = ReviewFileStoreDefaults.patch()
  ) {
    self.init(
      daemonController: daemonController,
      fileViewer: fileViewer,
      voiceCapture: NativeVoiceCaptureService(),
      daemonOwnership: daemonOwnership,
      remoteDaemonServices: remoteDaemonServices,
      modelContainer: modelContainer,
      persistenceError: persistenceError,
      cacheService: cacheService,
      taskBoardSettingsWorker: TaskBoardSettingsWorker(),
      reviewFilePreviewStore: reviewFilePreviewStore,
      reviewFilePatchStore: reviewFilePatchStore
    )
  }

  func setSupervisorRuntimeState(_ state: SupervisorRuntimeState) {
    guard supervisorRuntimeState != state else { return }
    supervisorRuntimeState = state
  }
}
