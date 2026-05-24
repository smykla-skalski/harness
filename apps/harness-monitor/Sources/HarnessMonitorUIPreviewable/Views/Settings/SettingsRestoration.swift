import Foundation
import SwiftUI

public enum SettingsRestorationDefaults {
  public static let selectedSectionKey = "harness.settings.selectedSection"
  private static let scrollOffsetKeyPrefix = "harness.settings.scrollOffset"

  public static func initialSelectedSection(
    fallback: SettingsSection,
    ignoresStoredValue: Bool,
    userDefaults: UserDefaults = .standard
  ) -> SettingsSection {
    guard !ignoresStoredValue else {
      return fallback
    }
    guard let rawValue = userDefaults.string(forKey: selectedSectionKey) else {
      return fallback
    }
    return SettingsSection(rawValue: rawValue) ?? fallback
  }

  public static func storeSelectedSection(
    _ section: SettingsSection,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(section.rawValue, forKey: selectedSectionKey)
  }

  static func scrollOffset(
    for section: SettingsSection,
    userDefaults: UserDefaults = .standard
  ) -> CGFloat {
    normalizedScrollOffset(
      CGFloat(userDefaults.double(forKey: scrollOffsetKey(for: section)))
    )
  }

  static func storeScrollOffset(
    _ offset: CGFloat,
    for section: SettingsSection,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(
      Double(normalizedScrollOffset(offset)),
      forKey: scrollOffsetKey(for: section)
    )
  }

  static func normalizedScrollOffset(_ offset: CGFloat) -> CGFloat {
    guard offset.isFinite, offset > 0 else {
      return 0
    }
    return offset
  }

  private static func scrollOffsetKey(for section: SettingsSection) -> String {
    scrollOffsetKeyPrefix + section.rawValue
  }
}

private struct SettingsScrollRestorationSectionKey: EnvironmentKey {
  static let defaultValue: SettingsSection? = nil
}

private struct SettingsScrollRestorationSuspendedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var settingsScrollRestorationSection: SettingsSection? {
    get { self[SettingsScrollRestorationSectionKey.self] }
    set { self[SettingsScrollRestorationSectionKey.self] = newValue }
  }

  var settingsScrollRestorationSuspended: Bool {
    get { self[SettingsScrollRestorationSuspendedKey.self] }
    set { self[SettingsScrollRestorationSuspendedKey.self] = newValue }
  }
}

struct SettingsScrollRestorationModifier: ViewModifier {
  private static let restoreTolerance: CGFloat = 1

  @Environment(\.settingsScrollRestorationSection)
  private var section
  @Environment(\.settingsScrollRestorationSuspended)
  private var isRestorationSuspended
  @State private var activeUserScroll = false
  @State private var lastPersistedOffset: CGFloat?
  @State private var pendingRestore: PendingRestore?
  @State private var restoreGeneration: UInt64 = 0
  @State private var restoreRetryDeferrer = SettingsScrollRestoreRetryDeferrer()
  @State private var restoredSection: SettingsSection?
  @State private var restoreApplicatorRequest: SettingsScrollRestoreRequest?
  @State private var restoreApplicatorRequestID: UInt64 = 0
  @State private var scrollPosition = ScrollPosition()
  @State private var scrollPersistenceBuffer = SettingsScrollPersistenceBuffer()
  @State private var userScrollObserved = false

  func body(content: Content) -> some View {
    Group {
      if let section {
        content
          .scrollPosition($scrollPosition)
          .background(
            SettingsScrollRestoreApplicator(request: restoreApplicatorRequest)
          )
          .onScrollGeometryChange(
            for: SettingsScrollState.self,
            of: Self.scrollState
          ) { oldState, newState in
            guard !waitForPendingRestore(newState, for: section) else {
              return
            }
            guard restoredSection == section else {
              return
            }
            persistGeometryOffset(
              newState.offsetY,
              oldOffset: oldState.offsetY,
              for: section
            )
          }
          .onScrollPhaseChange { _, newPhase, context in
            handleScrollPhaseChange(
              newPhase,
              state: Self.scrollState(context.geometry),
              for: section
            )
          }
          .onChange(of: section, initial: true) { oldSection, newSection in
            if oldSection != newSection {
              persistBufferedOffset(for: oldSection)
            }
            restoreScrollPosition(for: newSection)
          }
          .onChange(of: isRestorationSuspended, initial: true) { _, isSuspended in
            guard isSuspended else { return }
            cancelRestore(for: section, observedOffset: nil)
          }
      } else {
        content
      }
    }
  }

  private static func scrollState(_ geometry: ScrollGeometry) -> SettingsScrollState {
    let maxOffset = max(0, geometry.contentSize.height - geometry.visibleRect.height)
    return SettingsScrollState(
      offsetY: min(max(0, geometry.contentOffset.y), maxOffset),
      maxOffsetY: maxOffset
    )
  }

  private func restoreScrollPosition(for section: SettingsSection) {
    guard !isRestorationSuspended else {
      cancelRestore(for: section, observedOffset: nil)
      return
    }

    restoreGeneration &+= 1
    let generation = restoreGeneration
    let offset = SettingsRestorationDefaults.scrollOffset(for: section)
    activeUserScroll = false
    userScrollObserved = false
    scrollPersistenceBuffer.clear(for: section)
    lastPersistedOffset = offset
    if offset > 0 {
      pendingRestore = PendingRestore(section: section, offset: offset, generation: generation)
      restoredSection = nil
    } else {
      pendingRestore = nil
      restoredSection = section
    }
    requestScroll(to: offset)

    Task { @MainActor in
      await Task.yield()
      guard restoreGeneration == generation else {
        return
      }
      requestScroll(to: offset)
    }
  }

  private func requestScroll(to offset: CGFloat) {
    restoreApplicatorRequestID &+= 1
    restoreApplicatorRequest = SettingsScrollRestoreRequest(
      id: restoreApplicatorRequestID,
      offset: offset
    )
    scrollPosition.scrollTo(
      point: CGPoint(
        x: 0,
        y: SettingsRestorationDefaults.normalizedScrollOffset(offset)
      )
    )
  }

  private func handleScrollPhaseChange(
    _ phase: ScrollPhase,
    state: SettingsScrollState,
    for section: SettingsSection
  ) {
    if SettingsScrollRestorationPhasePolicy.isUserScroll(phase) {
      activeUserScroll = true
      userScrollObserved = true
      if pendingRestore?.section == section {
        cancelRestore(for: section, observedOffset: state.offsetY)
      }
      bufferObservedOffset(state.offsetY, for: section, force: false, allowsZero: true)
      return
    }

    if phase == .idle, userScrollObserved {
      bufferObservedOffset(state.offsetY, for: section, force: true, allowsZero: true)
      persistBufferedOffset(for: section)
      activeUserScroll = false
      userScrollObserved = false
    }
  }

  private func cancelRestore(
    for section: SettingsSection,
    observedOffset: CGFloat?
  ) {
    restoreGeneration &+= 1
    pendingRestore = nil
    restoredSection = section
    scrollPersistenceBuffer.clear(for: section)
    lastPersistedOffset = SettingsRestorationDefaults.scrollOffset(for: section)
  }

  private func waitForPendingRestore(
    _ state: SettingsScrollState,
    for section: SettingsSection
  ) -> Bool {
    guard let pendingRestore, pendingRestore.section == section else {
      return false
    }
    guard pendingRestore.generation == restoreGeneration else {
      self.pendingRestore = nil
      return false
    }

    let targetOffset = pendingRestore.offset
    let visibleTargetOffset = SettingsScrollPersistencePolicy.restorationTargetOffset(
      storedOffset: targetOffset,
      maxOffset: state.maxOffsetY
    )
    guard visibleTargetOffset > 0 else {
      finishRestore(for: section, observedOffset: state.offsetY)
      return false
    }
    guard state.maxOffsetY > 0 else {
      scheduleRestoreRetry(to: targetOffset, generation: pendingRestore.generation)
      return true
    }

    if abs(state.offsetY - visibleTargetOffset) > Self.restoreTolerance {
      scheduleRestoreRetry(to: targetOffset, generation: pendingRestore.generation)
      return true
    }
    finishRestore(for: section, observedOffset: state.offsetY)
    return true
  }

  private func scheduleRestoreRetry(to offset: CGFloat, generation: UInt64) {
    // Defer geometry-driven restore retries so the callback never mutates scroll
    // position during the same frame that produced the measurement.
    restoreRetryDeferrer.schedule(offset) { latestOffset in
      guard restoreGeneration == generation else {
        return
      }
      requestScroll(to: latestOffset)
    }
  }

  private func finishRestore(
    for section: SettingsSection,
    observedOffset _: CGFloat
  ) {
    pendingRestore = nil
    restoredSection = section
  }

  private func persistGeometryOffset(
    _ offset: CGFloat,
    oldOffset: CGFloat,
    for section: SettingsSection
  ) {
    let isConfirmedUserScroll = activeUserScroll || userScrollObserved
    guard isConfirmedUserScroll else {
      return
    }
    let hasMeaningfulMovement =
      SettingsScrollPersistencePolicy.hasMeaningfulMovement(
        from: oldOffset,
        to: offset
      )
    guard hasMeaningfulMovement else {
      return
    }
    bufferObservedOffset(
      offset,
      for: section,
      force: false,
      allowsZero: true
    )
  }

  private func bufferObservedOffset(
    _ offset: CGFloat,
    for section: SettingsSection,
    force: Bool,
    allowsZero: Bool
  ) {
    let previousOffset = scrollPersistenceBuffer.pendingOffset(for: section) ?? lastPersistedOffset
    guard
      SettingsScrollPersistencePolicy.shouldPersist(
        offset,
        previousOffset: previousOffset,
        force: force,
        allowsZero: allowsZero
      )
    else {
      return
    }
    let normalizedOffset = SettingsRestorationDefaults.normalizedScrollOffset(offset)
    scrollPersistenceBuffer.record(normalizedOffset, for: section)
  }

  private func persistBufferedOffset(for section: SettingsSection) {
    guard let normalizedOffset = scrollPersistenceBuffer.consumeOffset(for: section) else {
      return
    }
    SettingsRestorationDefaults.storeScrollOffset(normalizedOffset, for: section)
    lastPersistedOffset = normalizedOffset
  }

  private struct PendingRestore: Equatable {
    var section: SettingsSection
    var offset: CGFloat
    var generation: UInt64
  }

  private struct SettingsScrollState: Equatable {
    var offsetY: CGFloat = 0
    var maxOffsetY: CGFloat = 0
  }
}

enum SettingsScrollPersistencePolicy {
  private static let persistenceStep: CGFloat = 24

  static func restorationTargetOffset(storedOffset: CGFloat, maxOffset: CGFloat) -> CGFloat {
    min(
      SettingsRestorationDefaults.normalizedScrollOffset(storedOffset),
      SettingsRestorationDefaults.normalizedScrollOffset(maxOffset)
    )
  }

  static func hasMeaningfulMovement(from oldOffset: CGFloat, to newOffset: CGFloat) -> Bool {
    abs(
      SettingsRestorationDefaults.normalizedScrollOffset(newOffset)
        - SettingsRestorationDefaults.normalizedScrollOffset(oldOffset)
    ) >= persistenceStep
  }

  static func shouldPersist(
    _ offset: CGFloat,
    previousOffset: CGFloat?,
    force: Bool,
    allowsZero: Bool
  ) -> Bool {
    let normalizedOffset = SettingsRestorationDefaults.normalizedScrollOffset(offset)
    guard allowsZero || normalizedOffset > 0 else {
      return false
    }
    return force
      || previousOffset.map {
        abs($0 - normalizedOffset) >= persistenceStep
      } ?? true
  }
}

enum SettingsScrollRestorationPhasePolicy {
  static func isUserScroll(_ phase: ScrollPhase) -> Bool {
    switch phase {
    case .tracking, .interacting, .decelerating:
      true
    case .idle, .animating:
      false
    }
  }
}

struct SettingsScrollRestoreRequest: Equatable {
  var id: UInt64
  var offset: CGFloat
}
