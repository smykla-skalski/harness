import Foundation
import HarnessMonitorKit
import Observation
import SwiftUI

/// View-local @Observable holder for the Reviews > Files filter
/// inputs. Text changes debounce 250ms before bumping the snapshot id
/// the section watches; this keeps every keystroke from re-running the
/// filter and from publishing a fresh snapshot the view model would
/// otherwise refilter against.
@Observable
@MainActor
final class DashboardReviewFilesFilterState {
  var text: String = "" {
    didSet { scheduleSnapshotPublish() }
  }
  var hideGenerated: Bool = false {
    didSet { publishSnapshot() }
  }
  var hideWhitespaceOnly: Bool = false {
    didSet { publishSnapshot() }
  }
  var generatedPathMatcher: ReviewFilesGeneratedPathMatcher = .empty {
    didSet { publishSnapshot() }
  }

  private(set) var snapshotID = UUID()
  private(set) var snapshot: ReviewFilesFilter = .init()
  @ObservationIgnored private var pendingTextTask: Task<Void, Never>?

  static let textDebounceNanoseconds: UInt64 = 250_000_000

  init(
    hideGenerated: Bool = false,
    hideWhitespaceOnly: Bool = false,
    generatedPathMatcher: ReviewFilesGeneratedPathMatcher = .empty
  ) {
    self.hideGenerated = hideGenerated
    self.hideWhitespaceOnly = hideWhitespaceOnly
    self.generatedPathMatcher = generatedPathMatcher
    self.snapshot = makeSnapshot()
  }

  func clearText() {
    text = ""
    publishSnapshot()
  }

  private func makeSnapshot() -> ReviewFilesFilter {
    ReviewFilesFilter(
      searchText: text,
      hideGenerated: hideGenerated,
      hideWhitespaceOnly: hideWhitespaceOnly,
      generatedPathMatcher: generatedPathMatcher
    )
  }

  private func publishSnapshot() {
    pendingTextTask?.cancel()
    pendingTextTask = nil
    snapshot = makeSnapshot()
    snapshotID = UUID()
  }

  private func scheduleSnapshotPublish() {
    pendingTextTask?.cancel()
    let debounce = Self.textDebounceNanoseconds
    pendingTextTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: debounce)
      guard !Task.isCancelled else { return }
      self?.publishSnapshot()
    }
  }
}
