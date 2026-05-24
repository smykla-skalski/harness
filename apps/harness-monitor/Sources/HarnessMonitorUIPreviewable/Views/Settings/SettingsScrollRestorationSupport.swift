import Foundation

@MainActor
final class SettingsScrollRestoreRetryDeferrer {
  private var generation: UInt64 = 0
  private var task: Task<Void, Never>?

  func schedule(
    _ offset: CGFloat,
    apply: @escaping @MainActor (CGFloat) -> Void
  ) {
    generation &+= 1
    let scheduledGeneration = generation
    task?.cancel()
    task = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, self.generation == scheduledGeneration else {
        return
      }
      self.task = nil
      apply(offset)
    }
  }

  func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
  }
}

@MainActor
final class SettingsScrollPersistenceBuffer {
  private var pendingOffsets: [SettingsSection: CGFloat] = [:]

  func pendingOffset(for section: SettingsSection) -> CGFloat? {
    pendingOffsets[section]
  }

  func record(_ offset: CGFloat, for section: SettingsSection) {
    pendingOffsets[section] = SettingsRestorationDefaults.normalizedScrollOffset(offset)
  }

  func consumeOffset(for section: SettingsSection) -> CGFloat? {
    let offset = pendingOffsets[section]
    pendingOffsets[section] = nil
    return offset
  }

  func clear(for section: SettingsSection) {
    pendingOffsets[section] = nil
  }
}

@MainActor
final class SettingsScrollPersistenceDeferrer {
  private var pendingSection: SettingsSection?
  private var task: Task<Void, Never>?

  func schedule(
    for section: SettingsSection,
    delay: Duration,
    apply: @escaping @MainActor () -> Void
  ) {
    pendingSection = section
    task?.cancel()
    task = Task { @MainActor in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard pendingSection == section else {
        return
      }
      pendingSection = nil
      task = nil
      apply()
    }
  }

  func flush(for section: SettingsSection, apply: @escaping @MainActor () -> Void) {
    guard pendingSection == section else {
      return
    }
    task?.cancel()
    task = nil
    pendingSection = nil
    apply()
  }

  func cancel(for section: SettingsSection) {
    guard pendingSection == section else {
      return
    }
    task?.cancel()
    task = nil
    pendingSection = nil
  }
}
