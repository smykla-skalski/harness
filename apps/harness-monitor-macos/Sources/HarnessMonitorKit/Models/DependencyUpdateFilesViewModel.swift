import Foundation
import Observation

public enum FilesViewMode: String, Codable, Equatable, Sendable, CaseIterable {
  case unified
  case split
}

/// Loading state for the metadata fetch of one PR's files.
public enum DependencyUpdateFilesLoadState: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case error(String)
}

/// Per-file patch state on the view model.
public enum DependencyUpdateFilePatchState: Equatable, Sendable {
  case notLoaded
  case loading
  case loaded(DependencyUpdateFilePatch)
  case failed(String)
}

/// Filter snapshot consumed by `applyFilter`. Lives here so the view
/// layer can hand a Sendable value into the @MainActor view model.
public struct DependencyUpdateFilesFilter: Equatable, Sendable {
  public let searchText: String
  public let hideGenerated: Bool
  public let hideWhitespaceOnly: Bool
  public let generatedPathMatcher: DependencyUpdateFilesGeneratedPathMatcher

  public init(
    searchText: String = "",
    hideGenerated: Bool = false,
    hideWhitespaceOnly: Bool = false,
    generatedPathMatcher: DependencyUpdateFilesGeneratedPathMatcher = .empty
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
public struct DependencyUpdateFilesGeneratedPathMatcher: Equatable, Sendable {
  private let matchClosure: @Sendable (String) -> Bool
  private let identifier: String

  public static let empty = DependencyUpdateFilesGeneratedPathMatcher(
    identifier: "empty",
    match: { _ in false }
  )

  public init(identifier: String, match: @escaping @Sendable (String) -> Bool) {
    self.identifier = identifier
    self.matchClosure = match
  }

  public func matches(_ path: String) -> Bool { matchClosure(path) }

  public static func == (
    lhs: DependencyUpdateFilesGeneratedPathMatcher,
    rhs: DependencyUpdateFilesGeneratedPathMatcher
  ) -> Bool {
    lhs.identifier == rhs.identifier
  }
}

public enum DependencyUpdateFilesSortMode: String, Codable, Equatable, Sendable, CaseIterable {
  case path
  case lineChangesDescending
  case viewedFirst
  case unviewedFirst
}

@Observable
@MainActor
public final class DependencyUpdateFilesViewModel {
  public let pullRequestID: String

  public var state: DependencyUpdateFilesLoadState = .idle
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
  public var files: [DependencyUpdateFile] = []
  public var sortedFiles: [DependencyUpdateFile] = []
  public var filteredFiles: [DependencyUpdateFile] = []

  public var patches: [String: DependencyUpdateFilePatchState] = [:]
  public var viewedByPath: [String: DependencyUpdateFileViewedState] = [:]
  public var expandedPaths: Set<String> = []
  public var viewModeByPath: [String: FilesViewMode] = [:]

  public var sortMode: DependencyUpdateFilesSortMode = .path
  public var filter: DependencyUpdateFilesFilter = .init()
  public var defaultViewMode: FilesViewMode = .unified

  public init(pullRequestID: String) {
    self.pullRequestID = pullRequestID
  }

  // MARK: - Ingest

  public func ingest(response: DependencyUpdatesFilesListResponse) {
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
    viewedByPath = Dictionary(
      uniqueKeysWithValues: response.files.map { ($0.path, $0.viewerViewedState) }
    )
    // Drop patches whose path is no longer in the response, but keep the
    // patches that survive (e.g. on refresh of an unchanged file list).
    let validPaths = Set(response.files.map(\.path))
    patches = patches.filter { validPaths.contains($0.key) }
    recomputeSortedAndFiltered()
  }

  public func setLoading() { state = .loading }
  public func setError(_ message: String) { state = .error(message) }

  public func setPatchState(path: String, state: DependencyUpdateFilePatchState) {
    patches[path] = state
  }

  public func ingest(patches incoming: [DependencyUpdateFilePatch]) {
    for patch in incoming {
      patches[patch.path] = .loaded(patch)
    }
  }

  // MARK: - Viewed

  public func setViewedState(
    path: String,
    state: DependencyUpdateFileViewedState
  ) {
    viewedByPath[path] = state
    recomputeSortedAndFiltered()
  }

  public func markViewedBatch(
    paths: [String],
    state: DependencyUpdateFileViewedState
  ) {
    for path in paths {
      viewedByPath[path] = state
    }
    recomputeSortedAndFiltered()
  }

  // MARK: - Filter + sort

  public func applyFilter(_ filter: DependencyUpdateFilesFilter) {
    self.filter = filter
    recomputeSortedAndFiltered()
  }

  public func applySort(_ mode: DependencyUpdateFilesSortMode) {
    self.sortMode = mode
    recomputeSortedAndFiltered()
  }

  // MARK: - Expansion / view mode

  public func toggleExpansion(path: String) {
    if expandedPaths.contains(path) {
      expandedPaths.remove(path)
    } else {
      expandedPaths.insert(path)
    }
  }

  public func viewMode(forPath path: String) -> FilesViewMode {
    viewModeByPath[path] ?? defaultViewMode
  }

  public func setViewMode(_ mode: FilesViewMode, forPath path: String) {
    viewModeByPath[path] = mode
  }

  // MARK: - Internals

  func recomputeSortedAndFiltered() {
    sortedFiles = files.sorted(by: comparator(for: sortMode))
    filteredFiles = sortedFiles.filter { passesFilter($0, snapshot: filter) }
  }

  private func passesFilter(
    _ file: DependencyUpdateFile,
    snapshot: DependencyUpdateFilesFilter
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
    for mode: DependencyUpdateFilesSortMode
  ) -> (DependencyUpdateFile, DependencyUpdateFile) -> Bool {
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
