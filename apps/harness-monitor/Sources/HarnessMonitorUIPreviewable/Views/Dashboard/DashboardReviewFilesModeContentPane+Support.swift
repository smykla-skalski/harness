import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFilesContextMenuItem: Identifiable {
  let file: ReviewFile
  let harnessURL: URL?
  let blobURL: URL?
  let pullRequestFileURL: URL?

  var id: String { file.path }
  var fileName: String { dashboardReviewFileName(for: file.path) }
}

struct DashboardReviewFilesCollapsedFolders: Codable, Equatable {
  var folders: [String] = []

  var encodedString: String {
    DashboardReviewsStorageCodec.encodeToString(self)
  }

  func contains(_ folder: String) -> Bool {
    folders.contains(folder)
  }

  mutating func toggle(_ folder: String) {
    if let index = folders.firstIndex(of: folder) {
      folders.remove(at: index)
    } else {
      folders.append(folder)
      folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
  }

  static func decode(from string: String) -> Self {
    DashboardReviewsStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}

struct DashboardReviewFilesListSelectionState: Equatable {
  var selectedPaths: Set<String> = []
  var anchorPath: String?

  func displayedSelection(fallbackPrimaryPath: String?) -> Set<String> {
    if selectedPaths.isEmpty {
      guard let fallbackPrimaryPath else { return [] }
      return [fallbackPrimaryPath]
    }
    return selectedPaths
  }

  @discardableResult
  mutating func applySelection(
    _ newSelection: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    let previous = displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
    let effective: Set<String>
    if newSelection.isEmpty, let fallbackPrimaryPath {
      effective = [fallbackPrimaryPath]
    } else {
      effective = newSelection
    }

    selectedPaths = effective
    let added = effective.subtracting(previous)
    if effective.count <= 1 {
      anchorPath = effective.first
    } else if let anchorPath, effective.contains(anchorPath) {
      self.anchorPath = anchorPath
    } else if let addedPath = orderedVisiblePaths.first(where: added.contains) {
      anchorPath = addedPath
    } else {
      anchorPath = primarySelectionPath(
        fallbackPrimaryPath: fallbackPrimaryPath,
        orderedVisiblePaths: orderedVisiblePaths
      )
    }

    return primarySelectionPath(
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  mutating func notePrimarySelection(_ path: String) {
    anchorPath = path
  }

  mutating func collapse(to primaryPath: String?) {
    selectedPaths = primaryPath.map { [$0] } ?? []
    anchorPath = primaryPath
  }

  @discardableResult
  mutating func prune(
    visiblePaths: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    let pruned = displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
      .intersection(visiblePaths)
    if pruned.isEmpty {
      if let fallbackPrimaryPath, visiblePaths.contains(fallbackPrimaryPath) {
        collapse(to: fallbackPrimaryPath)
      } else {
        collapse(to: orderedVisiblePaths.first(where: visiblePaths.contains))
      }
      return primarySelectionPath(
        fallbackPrimaryPath: fallbackPrimaryPath,
        orderedVisiblePaths: orderedVisiblePaths
      )
    }

    selectedPaths = pruned
    anchorPath = orderedPrimary(
      in: pruned,
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
    return primarySelectionPath(
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  private func primarySelectionPath(
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    let displayed = displayedSelection(fallbackPrimaryPath: fallbackPrimaryPath)
    return orderedPrimary(
      in: displayed,
      fallbackPrimaryPath: fallbackPrimaryPath,
      orderedVisiblePaths: orderedVisiblePaths
    )
  }

  private func orderedPrimary(
    in selection: Set<String>,
    fallbackPrimaryPath: String?,
    orderedVisiblePaths: [String]
  ) -> String? {
    if let anchorPath, selection.contains(anchorPath) {
      return anchorPath
    }
    if let fallbackPrimaryPath, selection.contains(fallbackPrimaryPath) {
      return fallbackPrimaryPath
    }
    if let visiblePath = orderedVisiblePaths.first(where: selection.contains) {
      return visiblePath
    }
    return selection.min()
  }
}

@MainActor
struct DashboardReviewFilesFolderSectionHeader: View {
  let folder: String
  let itemCount: Int
  let isCollapsed: Bool
  let onToggleCollapse: () -> Void

  private var fileCountLabel: String {
    itemCount == 1 ? "1 file" : "\(itemCount) files"
  }

  var body: some View {
    Button(action: onToggleCollapse) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(width: 12, alignment: .center)
          Text(verbatim: "\(folder)/")
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(verbatim: fileCountLabel)
          .monospacedDigit()
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    .accessibilityLabel("\(folder), \(fileCountLabel)")
  }
}

struct DashboardReviewFilesNavigatorRow: View {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  private let fileName: String
  private let unresolvedThreadCount: Int
  private let additionCountLabel: String
  private let deletionCountLabel: String
  private let accessibilitySummary: String

  init(
    file: ReviewFile,
    viewedState: ReviewFileViewedState,
    threads: [DashboardReviewFileThreadAnchor]
  ) {
    self.file = file
    self.viewedState = viewedState
    fileName = dashboardReviewFileName(for: file.path)
    unresolvedThreadCount = threads.reduce(0) { partialResult, thread in
      partialResult + (thread.isResolved ? 0 : 1)
    }
    additionCountLabel = "+\(file.additions)"
    deletionCountLabel = "-\(file.deletions)"
    let unresolvedLabel =
      unresolvedThreadCount == 0
      ? "no unresolved conversations"
      : unresolvedThreadCount == 1
        ? "1 unresolved conversation"
        : "\(unresolvedThreadCount) unresolved conversations"
    accessibilitySummary =
      "\(file.additions) additions, \(file.deletions) deletions, \(unresolvedLabel), "
      + (viewedState == .viewed ? "viewed" : "not viewed")
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: file.isBinary ? "photo" : "doc.text")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(width: 16)
      Text(fileName)
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      HStack(spacing: 8) {
        if unresolvedThreadCount > 0 {
          HStack(spacing: 4) {
            Image(systemName: "text.bubble.fill")
            Text(verbatim: "\(unresolvedThreadCount)")
              .monospacedDigit()
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.warmAccent)
        }
        HStack(spacing: 4) {
          if file.additions > 0 {
            Text(verbatim: additionCountLabel)
              .foregroundStyle(HarnessMonitorTheme.accent)
          }
          if file.deletions > 0 {
            Text(verbatim: deletionCountLabel)
              .foregroundStyle(HarnessMonitorTheme.warmAccent)
          }
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        Image(systemName: viewedState == .viewed ? "eye.fill" : "eye.slash")
          .foregroundStyle(
            viewedState == .viewed
              ? HarnessMonitorTheme.secondaryInk
              : HarnessMonitorTheme.accent
          )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(file.path)
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilitySummary)
  }
}
