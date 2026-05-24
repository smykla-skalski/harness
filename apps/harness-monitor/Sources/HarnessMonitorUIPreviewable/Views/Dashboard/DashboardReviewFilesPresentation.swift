import HarnessMonitorKit
import SwiftUI

enum DashboardReviewFileBucket: String, CaseIterable {
  case source = "Source"
  case tests = "Tests"
  case config = "Config"
  case workflows = "Workflows"
  case generated = "Generated"
  case lockfiles = "Lockfiles"
  case binary = "Binary"

  var systemImage: String {
    switch self {
    case .source: "curlybraces"
    case .tests: "checklist"
    case .config: "gearshape"
    case .workflows: "point.3.connected.trianglepath.dotted"
    case .generated: "wand.and.stars"
    case .lockfiles: "lock.doc"
    case .binary: "photo"
    }
  }
}

struct DashboardReviewFilesSummary: Equatable {
  var total = 0
  var viewed = 0
  var additions: UInt32 = 0
  var deletions: UInt32 = 0
  var unresolvedThreads = 0
  var buckets: [DashboardReviewFileBucket: Int] = [:]

  var unviewed: Int { max(total - viewed, 0) }

  static func make(
    files: [ReviewFile],
    viewedByPath: [String: ReviewFileViewedState],
    threadIndex: DashboardReviewFileThreadIndex
  ) -> Self {
    var summary = Self()
    summary.total = files.count
    for file in files {
      summary.additions += file.additions
      summary.deletions += file.deletions
      if (viewedByPath[file.path] ?? file.viewerViewedState) == .viewed {
        summary.viewed += 1
      }
      for bucket in DashboardReviewFileClassifier.buckets(for: file) {
        summary.buckets[bucket, default: 0] += 1
      }
      summary.unresolvedThreads += threadIndex.unresolvedAnchorCount(forPath: file.path)
    }
    return summary
  }
}

struct DashboardReviewFilesModePresentation: Equatable {
  static let empty = Self(summary: DashboardReviewFilesSummary(), visibleFiles: [], groups: [])

  let summary: DashboardReviewFilesSummary
  let visibleFiles: [ReviewFile]
  let groups: [DashboardReviewFilesModeGroup]
}

struct DashboardReviewFilesModeGroup: Equatable, Identifiable {
  let folder: String
  let rows: [DashboardReviewFilesModeRow]

  var id: String { folder }
}

struct DashboardReviewFilesModeRow: Equatable, Identifiable {
  let file: ReviewFile
  let viewedState: ReviewFileViewedState
  let threads: [DashboardReviewFileThreadAnchor]

  var id: String { file.path }
}

struct DashboardReviewFilesModePresentationKey: Equatable {
  let filesRevision: UInt64
  let filteredFilesRevision: UInt64
  let viewedStateRevision: UInt64
  let timelineRevision: UInt64
  let onlyUnresolved: Bool
  let onlyUnviewed: Bool
  let bucketFilter: DashboardReviewFileBucket?
}

@MainActor
final class DashboardReviewFilesModePresentationCache {
  private var cachedKey: DashboardReviewFilesModePresentationKey?
  private var cachedPresentation = DashboardReviewFilesModePresentation.empty

  func presentation(
    files: [ReviewFile],
    filteredFiles: [ReviewFile],
    viewedByPath: [String: ReviewFileViewedState],
    threadIndex: DashboardReviewFileThreadIndex,
    key: DashboardReviewFilesModePresentationKey
  ) -> DashboardReviewFilesModePresentation {
    guard cachedKey != key else { return cachedPresentation }
    cachedKey = key
    cachedPresentation = Self.make(
      DashboardReviewFilesModePresentationInput(
        files: files,
        filteredFiles: filteredFiles,
        viewedByPath: viewedByPath,
        threadIndex: threadIndex,
        key: key
      )
    )
    return cachedPresentation
  }

  private static func make(
    _ input: DashboardReviewFilesModePresentationInput
  ) -> DashboardReviewFilesModePresentation {
    let summary = DashboardReviewFilesSummary.make(
      files: input.files,
      viewedByPath: input.viewedByPath,
      threadIndex: input.threadIndex
    )
    var visibleFiles: [ReviewFile] = []
    var rowsByFolder: [String: [DashboardReviewFilesModeRow]] = [:]
    visibleFiles.reserveCapacity(input.filteredFiles.count)
    rowsByFolder.reserveCapacity(input.filteredFiles.count)
    for file in input.filteredFiles {
      let viewedState = input.viewedByPath[file.path] ?? file.viewerViewedState
      if input.key.onlyUnviewed, viewedState == .viewed {
        continue
      }
      if input.key.onlyUnresolved, !input.threadIndex.hasUnresolvedAnchors(forPath: file.path) {
        continue
      }
      if let bucketFilter = input.key.bucketFilter,
        !DashboardReviewFileClassifier.matches(file, bucket: bucketFilter)
      {
        continue
      }
      let threads = input.threadIndex.anchors(forPath: file.path)
      let row = DashboardReviewFilesModeRow(
        file: file,
        viewedState: viewedState,
        threads: threads
      )
      visibleFiles.append(file)
      rowsByFolder[parentDirectory(for: file.path), default: []].append(row)
    }
    let groups = sortedFolders(in: rowsByFolder).map { folder in
      DashboardReviewFilesModeGroup(folder: folder, rows: rowsByFolder[folder] ?? [])
    }
    return DashboardReviewFilesModePresentation(
      summary: summary,
      visibleFiles: visibleFiles,
      groups: groups
    )
  }

  private static func sortedFolders(
    in rowsByFolder: [String: [DashboardReviewFilesModeRow]]
  ) -> [String] {
    rowsByFolder.keys.sorted { lhs, rhs in
      if lhs == rootFolder { return true }
      if rhs == rootFolder { return false }
      return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
  }

  private static func parentDirectory(for path: String) -> String {
    guard let slashIndex = path.lastIndex(of: "/") else { return rootFolder }
    return String(path[..<slashIndex])
  }

  private static let rootFolder = "Repository root"
}

private struct DashboardReviewFilesModePresentationInput {
  let files: [ReviewFile]
  let filteredFiles: [ReviewFile]
  let viewedByPath: [String: ReviewFileViewedState]
  let threadIndex: DashboardReviewFileThreadIndex
  let key: DashboardReviewFilesModePresentationKey
}

enum DashboardReviewFileClassifier {
  static func buckets(for file: ReviewFile) -> [DashboardReviewFileBucket] {
    if file.isBinary { return [.binary] }
    let path = file.path.lowercased()
    var buckets: [DashboardReviewFileBucket] = []
    if isGenerated(path) { buckets.append(.generated) }
    if isLockfile(path) { buckets.append(.lockfiles) }
    if isWorkflow(path) { buckets.append(.workflows) }
    if isTest(path) { buckets.append(.tests) }
    if isConfig(path) { buckets.append(.config) }
    if buckets.isEmpty { buckets.append(.source) }
    return buckets
  }

  static func matches(_ file: ReviewFile, bucket: DashboardReviewFileBucket) -> Bool {
    buckets(for: file).contains(bucket)
  }

  private static func isWorkflow(_ path: String) -> Bool {
    path.hasPrefix(".github/workflows/") || path.contains("/.github/workflows/")
  }

  private static func isTest(_ path: String) -> Bool {
    path.contains("/test/") || path.contains("/tests/") || path.contains("test.")
      || path.contains("tests.") || path.contains("_test.")
  }

  private static func isConfig(_ path: String) -> Bool {
    path.hasSuffix(".yml") || path.hasSuffix(".yaml") || path.hasSuffix(".toml")
      || path.hasSuffix(".json") || path.hasSuffix(".plist") || path.hasSuffix(".xcconfig")
  }

  private static func isLockfile(_ path: String) -> Bool {
    path.hasSuffix("package-lock.json") || path.hasSuffix("yarn.lock")
      || path.hasSuffix("pnpm-lock.yaml") || path.hasSuffix("cargo.lock")
      || path.hasSuffix("package.resolved") || path.hasSuffix("go.sum")
  }

  private static func isGenerated(_ path: String) -> Bool {
    path.contains("/generated/") || path.contains("/vendor/") || path.contains("/dist/")
      || path.hasSuffix(".pb.go") || path.hasSuffix(".generated.swift")
      || path.hasSuffix(".generated.ts") || path.hasSuffix(".generated.js")
  }
}

struct DashboardReviewFilesSummaryChip: View {
  let systemImage: String
  let title: String
  var tint: Color = .secondary

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.secondary.opacity(0.10), in: Capsule())
  }
}
