import Foundation

@MainActor
@Observable
public final class NewSessionViewModel {
  public enum ValidationError: Equatable, Sendable {
    case titleRequired
    case projectRequired
    case bookmarkUnavailable
  }

  public enum SubmitError: Error, Equatable, Sendable {
    case validation(ValidationError)
    case bookmarkRevoked(id: String)
    case bookmarkStale(id: String)
    case daemonUnreachable
    case worktreeCreateFailed(reason: String)
    case invalidBaseRef(ref: String, reason: String)
    case unexpected(String)
  }

  public typealias BookmarkResolver = @Sendable (String) async throws -> ResolvedBookmark

  public struct ResolvedBookmark: Sendable {
    public let projectDir: String
    public let isStale: Bool

    public init(projectDir: String, isStale: Bool) {
      self.projectDir = projectDir
      self.isStale = isStale
    }
  }

  public var title: String = ""
  public var context: String = ""
  public var baseRef: String = ""
  public var selectedBookmarkId: String?
  public private(set) var isSubmitting = false
  public private(set) var lastError: SubmitError?

  private let store: HarnessMonitorStore
  private let bookmarkStore: BookmarkStore
  private let client: any HarnessMonitorClientProtocol
  private let isSandboxedCheck: @Sendable () -> Bool
  private let bookmarkResolver: BookmarkResolver

  public init(
    store: HarnessMonitorStore,
    bookmarkStore: BookmarkStore,
    client: any HarnessMonitorClientProtocol,
    isSandboxed: @Sendable @escaping () -> Bool = NewSessionViewModel.liveIsSandboxed,
    bookmarkResolver: BookmarkResolver? = nil
  ) {
    self.store = store
    self.bookmarkStore = bookmarkStore
    self.client = client
    self.isSandboxedCheck = isSandboxed
    self.bookmarkResolver = bookmarkResolver
      ?? Self.makeDefaultResolver(bookmarkStore: bookmarkStore)
  }

  public func submit() async -> Result<SessionSummary, SubmitError> {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      let error = SubmitError.validation(.titleRequired)
      lastError = error
      return .failure(error)
    }
    guard let bookmarkId = selectedBookmarkId else {
      let error = SubmitError.validation(.projectRequired)
      lastError = error
      return .failure(error)
    }

    isSubmitting = true
    defer { isSubmitting = false }

    let resolved: ResolvedBookmark
    do {
      resolved = try await bookmarkResolver(bookmarkId)
    } catch let error as BookmarkStoreError {
      let submitError = classifyBookmarkError(error, bookmarkId: bookmarkId)
      lastError = submitError
      return .failure(submitError)
    } catch {
      let submitError = SubmitError.unexpected(String(describing: error))
      lastError = submitError
      return .failure(submitError)
    }

    if resolved.isStale {
      let error = SubmitError.bookmarkStale(id: bookmarkId)
      lastError = error
      return .failure(error)
    }

    let projectDir = isSandboxedCheck() ? bookmarkId : resolved.projectDir
    let request = SessionStartRequest(
      title: trimmedTitle,
      context: context,
      runtime: "claude",
      sessionId: nil,
      projectDir: projectDir,
      policyPreset: nil,
      baseRef: baseRef.isEmpty ? nil : baseRef
    )

    let summary: SessionSummary
    do {
      summary = try await client.startSession(request: request)
    } catch {
      let submitError = classify(error: error)
      lastError = submitError
      return .failure(submitError)
    }

    await store.selectSession(summary.sessionId)
    lastError = nil
    return .success(summary)
  }

  public func availableBookmarks() async -> [BookmarkStore.Record] {
    await bookmarkStore.all().filter { $0.kind == .projectRoot }
  }

  nonisolated public static func liveIsSandboxed() -> Bool {
    ProcessInfo.processInfo.environment["HARNESS_SANDBOXED"] != nil
  }

  // MARK: - Private

  private func classifyBookmarkError(
    _ error: BookmarkStoreError,
    bookmarkId: String
  ) -> SubmitError {
    switch error {
    case .unresolvable:
      return .bookmarkRevoked(id: bookmarkId)
    case .notFound:
      return .bookmarkRevoked(id: bookmarkId)
    default:
      return .unexpected(String(describing: error))
    }
  }

  private func classify(error: any Error) -> SubmitError {
    if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
      return .daemonUnreachable
    }
    if let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, let message) = apiError
    {
      if code == 500, message.contains("create session worktree") {
        return .worktreeCreateFailed(reason: message)
      }
      if code == 400, message.contains("base_ref") || message.contains("rev-parse") {
        return .invalidBaseRef(ref: baseRef, reason: message)
      }
    }
    return .unexpected(String(describing: error))
  }

  private static func makeDefaultResolver(bookmarkStore: BookmarkStore) -> BookmarkResolver {
    { id in
      let resolvedScope = try await bookmarkStore.resolve(id: id)
      return await resolvedScope.url.withSecurityScopeAsync { url in
        ResolvedBookmark(
          projectDir: url.path,
          isStale: resolvedScope.isStale
        )
      }
    }
  }
}
