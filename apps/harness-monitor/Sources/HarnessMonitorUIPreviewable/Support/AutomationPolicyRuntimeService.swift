import HarnessMonitorKit
import Observation

@MainActor
public final class AutomationPolicyRuntimeService {
  private let policyCenter: AutomationPolicyCenter
  private var store: HarnessMonitorStore?
  private var isRunning = false

  public init(policyCenter: AutomationPolicyCenter = .shared) {
    self.policyCenter = policyCenter
  }

  public func start(store: HarnessMonitorStore) {
    guard !isRunning else { return }
    isRunning = true
    self.store = store
    observePolicyRuntime()
  }

  public func stop() {
    isRunning = false
    store = nil
  }

  private func observePolicyRuntime() {
    guard isRunning, let store else { return }
    let runtime = withObservationTracking {
      (
        store.globalPolicyCanvasWorkspace,
        store.globalPolicyPipeline
      )
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observePolicyRuntime()
      }
    }
    DashboardAutomationPolicyRuntimeSynchronizer.synchronizeEnforcedCanvasAutomationPolicies(
      policyCenter: policyCenter,
      workspace: runtime.0,
      activeDocument: runtime.1
    )
  }
}
