import HarnessMonitorKit
import Observation

@MainActor
final class OpenAnythingCorpusUpdateDriver {
  typealias InputBuilder = @MainActor () -> OpenAnythingCorpusInput

  private static let defaultSourceCoalesceDelayNanos: UInt64 = 50_000_000

  private let sourceChangeCoalescingDelayNanoseconds: UInt64
  private var generation: UInt64 = 0
  private var rebuildSequence: UInt64 = 0
  private var sourceObservationTask: Task<Void, Never>?
  private var rebuildTask: Task<Void, Never>?
  private var coordinator: OpenAnythingCorpusCoordinator?
  private var inputBuilder: InputBuilder?

  init(
    sourceChangeCoalescingDelayNanoseconds: UInt64 =
      OpenAnythingCorpusUpdateDriver.defaultSourceCoalesceDelayNanos
  ) {
    self.sourceChangeCoalescingDelayNanoseconds = sourceChangeCoalescingDelayNanoseconds
  }

  func start(
    coordinator: OpenAnythingCorpusCoordinator,
    inputBuilder: @escaping InputBuilder
  ) {
    generation &+= 1
    sourceObservationTask?.cancel()
    sourceObservationTask = nil
    rebuildTask?.cancel()
    rebuildTask = nil
    self.coordinator = coordinator
    self.inputBuilder = inputBuilder
    observeSource(generation: generation)
  }

  func stop() {
    generation &+= 1
    sourceObservationTask?.cancel()
    sourceObservationTask = nil
    rebuildTask?.cancel()
    rebuildTask = nil
    coordinator = nil
    inputBuilder = nil
  }

  private func observeSource(generation: UInt64) {
    guard self.generation == generation, let inputBuilder else { return }
    let input = withObservationTracking {
      inputBuilder()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.queueSourceObservation(generation: generation)
      }
    }
    scheduleRebuild(for: input, generation: generation)
  }

  private func queueSourceObservation(generation: UInt64) {
    guard self.generation == generation else { return }
    sourceObservationTask?.cancel()
    rebuildSequence &+= 1
    rebuildTask?.cancel()
    rebuildTask = nil
    let delayNanoseconds = sourceChangeCoalescingDelayNanoseconds
    sourceObservationTask = Task { @MainActor [weak self] in
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      } else {
        await Task.yield()
      }
      guard !Task.isCancelled else { return }
      self?.sourceObservationTask = nil
      self?.observeSource(generation: generation)
    }
  }

  private func scheduleRebuild(
    for input: OpenAnythingCorpusInput,
    generation: UInt64
  ) {
    rebuildSequence &+= 1
    let sequence = rebuildSequence
    rebuildTask?.cancel()
    rebuildTask = Task.detached(priority: .utility) { [weak self] in
      let sourceSignature = OpenAnythingCorpusTask.sourceSignature(input: input)
      guard !Task.isCancelled else { return }
      guard
        await self?.shouldBuildCorpus(
          sourceSignature: sourceSignature,
          generation: generation,
          sequence: sequence
        ) == true
      else {
        return
      }

      let records = OpenAnythingCorpusTask.records(input: input)
      guard !Task.isCancelled else { return }
      let signature = OpenAnythingCorpusTask.signature(
        records: records,
        fallback: sourceSignature
      )
      guard !Task.isCancelled else { return }
      await self?.acceptCorpus(
        records,
        signature: signature,
        generation: generation,
        sequence: sequence
      )
    }
  }

  private func shouldBuildCorpus(
    sourceSignature: Int,
    generation: UInt64,
    sequence: UInt64
  ) -> Bool {
    guard isCurrent(generation: generation, sequence: sequence), let coordinator else {
      return false
    }
    guard
      !OpenAnythingPluginRegistry.shared.hasRegisteredPlugins,
      coordinator.lastSignature == sourceSignature
    else {
      return true
    }
    if rebuildTask != nil {
      rebuildTask = nil
    }
    return false
  }

  private func acceptCorpus(
    _ records: [OpenAnythingRecord],
    signature: Int,
    generation: UInt64,
    sequence: UInt64
  ) async {
    guard isCurrent(generation: generation, sequence: sequence), let coordinator else {
      return
    }
    await coordinator.acceptCorpus(records, signature: signature)
    if isCurrent(generation: generation, sequence: sequence) {
      rebuildTask = nil
    }
  }

  private func isCurrent(generation: UInt64, sequence: UInt64) -> Bool {
    self.generation == generation && rebuildSequence == sequence
  }
}
