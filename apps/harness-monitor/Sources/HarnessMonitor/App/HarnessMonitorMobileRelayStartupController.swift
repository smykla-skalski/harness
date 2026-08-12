import HarnessMonitorKit
import HarnessMonitorMacRelay
import Observation

@MainActor
@Observable
final class HarnessMonitorMobileRelayStartupController {
  typealias RuntimeBuilder = @Sendable () -> MobileMacRelayRuntime?

  private let runtimeBuilder: RuntimeBuilder
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private var hasStarted = false
  private(set) var runtime: MobileMacRelayRuntime?

  init(
    environment: HarnessMonitorEnvironment,
    store: HarnessMonitorStore,
    runsLiveSideEffects: Bool,
    runtimeBuilder: RuntimeBuilder? = nil
  ) {
    let clientProvider = HarnessMonitorMobileRelayClientProvider(store: store)
    self.runtimeBuilder = runtimeBuilder ?? {
      HarnessMonitorApp.makeMobileRelayRuntime(
        environment: environment,
        clientProvider: clientProvider,
        runsLiveSideEffects: runsLiveSideEffects
      )
    }
  }

  func start() {
    guard !hasStarted else {
      return
    }
    hasStarted = true

    let runtimeBuilder = self.runtimeBuilder
    let builderTask: Task<MobileMacRelayRuntime?, Never> = Task.detached(priority: .utility) {
      let runtime = runtimeBuilder()
      guard !Task.isCancelled else {
        runtime?.stop()
        return nil
      }
      runtime?.start()
      return runtime
    }
    startupTask = Task { @MainActor [weak self] in
      let runtime = await builderTask.value
      guard !Task.isCancelled else {
        runtime?.stop()
        return
      }
      self?.runtime = runtime
      self?.startupTask = nil
    }
  }

  func waitForStartup() async {
    await startupTask?.value
  }
}
