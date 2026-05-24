import Foundation

@MainActor
final class SettingsScrollRestoreRetryDeferrer {
  private var generation: UInt64 = 0

  func schedule(
    _ offset: CGFloat,
    apply: @escaping @MainActor (CGFloat) -> Void
  ) {
    generation &+= 1
    let scheduledGeneration = generation
    Task { @MainActor in
      await Task.yield()
      guard self.generation == scheduledGeneration else {
        return
      }
      apply(offset)
    }
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
