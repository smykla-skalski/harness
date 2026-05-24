import Foundation
import Observation

public enum FilesViewMode: String, Codable, Equatable, Sendable, CaseIterable {
  case unified
  case split
}

/// Loading state for the metadata fetch of one PR's files.
public enum ReviewFilesLoadState: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case error(String)
}

/// Per-file patch state on the view model.
public enum ReviewFilePatchState: Equatable, Sendable {
  case notLoaded
  case loading
  case loaded(ReviewFilePatch)
  case failed(String)
}

/// Per-file first-lines preview state on the view model.
public enum ReviewFilePreviewState: Equatable, Sendable {
  case notLoaded
  case loading
  case loaded(ReviewFilePreview)
  case failed(String)
}

/// Filter snapshot consumed by `applyFilter`. Lives here so the view
/// layer can hand a Sendable value into the @MainActor view model.
public struct ReviewFilesFilter: Equatable, Sendable {
  public let searchText: String
  public let hideGenerated: Bool
  public let hideWhitespaceOnly: Bool
  public let generatedPathMatcher: ReviewFilesGeneratedPathMatcher

  public init(
    searchText: String = "",
    hideGenerated: Bool = false,
    hideWhitespaceOnly: Bool = false,
    generatedPathMatcher: ReviewFilesGeneratedPathMatcher = .empty
  ) {
    self.searchText = searchText
    self.hideGenerated = hideGenerated
    self.hideWhitespaceOnly = hideWhitespaceOnly
    self.generatedPathMatcher = generatedPathMatcher
  }
}

/// Pre-compiled "is this path generated" matcher. Wraps a closure so the
/// regex compile can happen off-main and the resulting matcher stays
/// `Sendable`.
public struct ReviewFilesGeneratedPathMatcher: Equatable, Sendable {
  private let matchClosure: @Sendable (String) -> Bool
  private let identifier: String

  public static let empty = Self(
    identifier: "empty",
    match: { _ in false }
  )

  public init(identifier: String, match: @escaping @Sendable (String) -> Bool) {
    self.identifier = identifier
    self.matchClosure = match
  }

  public func matches(_ path: String) -> Bool { matchClosure(path) }

  public static func == (
    lhs: Self,
    rhs: Self
  ) -> Bool {
    lhs.identifier == rhs.identifier
  }
}

public enum ReviewFilesSortMode: String, Codable, Equatable, Sendable, CaseIterable {
  case path
  case lineChangesDescending
  case viewedFirst
  case unviewedFirst

  fileprivate var dependsOnViewedState: Bool {
    switch self {
    case .path, .lineChangesDescending: false
    case .viewedFirst, .unviewedFirst: true
    }
  }
}

public struct ReviewFileTreeNode: Identifiable, Equatable, Sendable {
  public var id: String { fullPath.isEmpty ? name : fullPath }
  public let name: String
  public let fullPath: String
  public let children: [Self]

  public init(name: String, fullPath: String, children: [Self] = []) {
    self.name = name
    self.fullPath = fullPath
    self.children = children
  }
}

@Observable
@MainActor
public final class ReviewFilesViewModel {
  public let pullRequestID: String

  public var state: ReviewFilesLoadState = .idle
  public var headRefOid: String = ""
  /// PR's source branch name (`refs/heads/<x>` qualifier dropped).
  /// Used by the local-clone patch dispatch so the daemon fetches the
  /// actual PR ref. `nil` keeps the daemon on its default-branch fallback.
  public var headRefName: String?
  /// Merge-base OID; the local-clone patch dispatch needs this to
  /// compute `base..head` diffs. `nil` falls back to the REST path.
  public var baseRefOid: String?
  /// PR base branch name. The daemon fetches this ref before local diffing.
  public var baseRefName: String?
  /// `owner/name` of the PR's repository. `nil` falls back to REST.
  public var repositoryFullName: String?
  /// Pull request number, used to fetch `refs/pull/<number>/head`.
  public var number: UInt64?
  public var viewerCanMarkViewed: Bool = true
  public var paginationComplete: Bool = true
  public var files: [ReviewFile] = []
  public var sortedFiles: [ReviewFile] = []
  public var filteredFiles: [ReviewFile] = []
  public private(set) var filesRevision: UInt64 = 0
  public private(set) var filteredFilesRevision: UInt64 = 0
  public private(set) var viewedStateRevision: UInt64 = 0
  public private(set) var fileTreeNodes: [ReviewFileTreeNode] = []

  public var patches: [String: ReviewFilePatchState] = [:]
  public var previews: [String: ReviewFilePreviewState] = [:]
  public var viewedByPath: [String: ReviewFileViewedState] = [:]
  public var expandedPaths: Set<String> = []
  public var selectedPath: String?

  public var sortMode: ReviewFilesSortMode = .path
  public var filter: ReviewFilesFilter = .init()
  public var defaultViewMode: FilesViewMode = .unified
  private var filesByPath: [String: ReviewFile] = [:]
  private var filteredPathSet: Set<String> = []

  public init(pullRequestID: String) {
    self.pullRequestID = pullRequestID
  }

  // MARK: - Ingest

  public func ingest(response: ReviewsFilesListResponse) {
    state = .loaded
    headRefOid = response.headRefOid
    headRefName = response.headRefName
    baseRefOid = response.baseRefOid
    baseRefName = response.baseRefName
    repositoryFullName = response.repositoryFullName
    number = response.number
    viewerCanMarkViewed = response.viewerCanMarkViewed
    paginationComplete = response.paginationComplete
    files = response.files
    filesRevision &+= 1
    filesByPath = Dictionary(
      response.files.map { ($0.path, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    fileTreeNodes = ReviewFileTreeBuilder.build(files: response.files)
    viewedByPath = Dictionary(
      uniqueKeysWithValues: response.files.map { ($0.path, $0.viewerViewedState) }
    )
    viewedStateRevision &+= 1
    // Drop patches whose path is no longer in the response, but keep the
    // patches that survive (e.g. on refresh of an unchanged file list).
    let validPaths = Set(response.files.map(\.path))
    patches = patches.filter { validPaths.contains($0.key) }
    previews = previews.filter { validPaths.contains($0.key) }
    recomputeSortedAndFiltered()
    ensureSelectedPath()
  }

  public func setLoading() { state = .loading }
  public func setError(_ message: String) { state = .error(message) }

  public func setPatchState(path: String, state: ReviewFilePatchState) {
    patches[path] = state
  }

  public func setPreviewState(path: String, state: ReviewFilePreviewState) {
    previews[path] = state
  }

  public func ingest(patches incoming: [ReviewFilePatch]) {
    for patch in incoming {
      patches[patch.path] = .loaded(patch)
    }
  }

  public func ingest(previews incoming: [ReviewFilePreview]) {
    for preview in incoming {
      previews[preview.path] = .loaded(preview)
    }
  }

  // MARK: - Viewed

  public func setViewedState(
    path: String,
    state: ReviewFileViewedState
  ) {
    let previous = viewedByPath[path]
    viewedByPath[path] = state
    if previous != state {
      viewedStateRevision &+= 1
    }
    recomputeSortedAndFilteredIfViewedSortDependsOnIt()
  }

  public func markViewedBatch(
    paths: [String],
    state: ReviewFileViewedState
  ) {
    var didChange = false
    for path in paths {
      if viewedByPath[path] != state {
        didChange = true
      }
      viewedByPath[path] = state
    }
    if didChange {
      viewedStateRevision &+= 1
    }
    recomputeSortedAndFilteredIfViewedSortDependsOnIt()
  }

  // MARK: - Filter + sort

  public func applyFilter(_ filter: ReviewFilesFilter) {
    self.filter = filter
    recomputeSortedAndFiltered()
    ensureSelectedPath()
  }

  public func applySort(_ mode: ReviewFilesSortMode) {
    self.sortMode = mode
    recomputeSortedAndFiltered()
    ensureSelectedPath()
  }

  // MARK: - Expansion / view mode

  public func toggleExpansion(path: String) {
    if expandedPaths.contains(path) {
      expandedPaths.remove(path)
    } else {
      expandedPaths.insert(path)
    }
  }

  public func viewMode(forPath _: String) -> FilesViewMode {
    defaultViewMode
  }

  // MARK: - Selection

  public var selectedFile: ReviewFile? {
    guard let selectedPath else { return nil }
    return filesByPath[selectedPath]
  }

  public func select(path: String?) {
    guard let path else {
      selectedPath = nil
      return
    }
    if filesByPath[path] != nil {
      selectedPath = path
    }
  }

  public func ensureSelectedPath() {
    if let selectedPath, filteredPathSet.contains(selectedPath) {
      return
    }
    selectedPath = preferredSelection(in: filteredFiles)?.path
  }

  public func selectNextUnviewed() {
    guard !filteredFiles.isEmpty else {
      selectedPath = nil
      return
    }
    let startIndex =
      selectedPath.flatMap { selected in
        filteredFiles.firstIndex { $0.path == selected }
      } ?? -1
    for index in filteredFiles.indices.dropFirst(startIndex + 1)
    where isUnviewed(filteredFiles[index]) {
      selectedPath = filteredFiles[index].path
      return
    }
    for index in filteredFiles.indices.prefix(max(startIndex + 1, 0))
    where isUnviewed(filteredFiles[index]) {
      selectedPath = filteredFiles[index].path
      return
    }
  }

  // MARK: - Internals

  func recomputeSortedAndFiltered() {
    sortedFiles = files.sorted(by: comparator(for: sortMode))
    filteredFiles = sortedFiles.filter { passesFilter($0, snapshot: filter) }
    filteredPathSet = Set(filteredFiles.map(\.path))
    filteredFilesRevision &+= 1
  }

  private func recomputeSortedAndFilteredIfViewedSortDependsOnIt() {
    guard sortMode.dependsOnViewedState else { return }
    recomputeSortedAndFiltered()
  }

  private func preferredSelection(in candidates: [ReviewFile]) -> ReviewFile? {
    candidates.first { file in
      isUnviewed(file)
    } ?? candidates.first
  }

  private func isUnviewed(_ file: ReviewFile) -> Bool {
    (viewedByPath[file.path] ?? file.viewerViewedState) != .viewed
  }

  private func passesFilter(
    _ file: ReviewFile,
    snapshot: ReviewFilesFilter
  ) -> Bool {
    if snapshot.hideGenerated, snapshot.generatedPathMatcher.matches(file.path) {
      return false
    }
    if snapshot.hideWhitespaceOnly, file.additions == 0, file.deletions == 0 {
      return false
    }
    if !snapshot.searchText.isEmpty {
      return file.path.localizedCaseInsensitiveContains(snapshot.searchText)
    }
    return true
  }

  private func comparator(
    for mode: ReviewFilesSortMode
  ) -> (ReviewFile, ReviewFile) -> Bool {
    let viewedSnapshot = self.viewedByPath
    switch mode {
    case .path:
      return { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    case .lineChangesDescending:
      return {
        let lhs = Int($0.additions) + Int($0.deletions)
        let rhs = Int($1.additions) + Int($1.deletions)
        if lhs != rhs { return lhs > rhs }
        return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
      }
    case .viewedFirst:
      return { lhs, rhs in
        let lhsViewed = (viewedSnapshot[lhs.path] ?? lhs.viewerViewedState) == .viewed
        let rhsViewed = (viewedSnapshot[rhs.path] ?? rhs.viewerViewedState) == .viewed
        if lhsViewed != rhsViewed { return lhsViewed }
        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
      }
    case .unviewedFirst:
      return { lhs, rhs in
        let lhsViewed = (viewedSnapshot[lhs.path] ?? lhs.viewerViewedState) == .viewed
        let rhsViewed = (viewedSnapshot[rhs.path] ?? rhs.viewerViewedState) == .viewed
        if lhsViewed != rhsViewed { return !lhsViewed }
        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
      }
    }
  }
}
