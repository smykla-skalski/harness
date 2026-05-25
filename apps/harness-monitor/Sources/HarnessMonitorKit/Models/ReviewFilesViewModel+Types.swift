import Foundation

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
