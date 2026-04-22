import Foundation
import OSLog

// MARK: - Log sink protocol

public protocol NewSessionLogSink: Sendable {
  func info(_ message: String)
  func error(_ message: String)
  func debug(_ message: String)
}

public struct LiveNewSessionLogSink: NewSessionLogSink {
  private static let logger = Logger(subsystem: "io.harnessmonitor", category: "sessions")
  public init() {}
  public func info(_ message: String) { Self.logger.info("\(message, privacy: .public)") }
  public func error(_ message: String) { Self.logger.error("\(message, privacy: .public)") }
  public func debug(_ message: String) { Self.logger.debug("\(message)") }
}

@MainActor
@Observable
public final class NewSessionViewModel {
  public enum ValidationError: Equatable, Sendable {
    case titleRequired
    case projectRequired
  }

  public enum SubmitError: Error, Equatable, Sendable {
    case validation(ValidationError)
    case bookmarkRevoked(id: String)
    case bookmarkStale(id: String)
    case daemonUnreachable
    case invalidProject(reason: String)
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
  private let logSink: any NewSessionLogSink

  public init(
    store: HarnessMonitorStore,
    bookmarkStore: BookmarkStore,
    client: any HarnessMonitorClientProtocol,
    isSandboxed: @Sendable @escaping () -> Bool = NewSessionViewModel.liveIsSandboxed,
    bookmarkResolver: BookmarkResolver? = nil,
    logSink: any NewSessionLogSink = LiveNewSessionLogSink()
  ) {
    self.store = store
    self.bookmarkStore = bookmarkStore
    self.client = client
    self.isSandboxedCheck = isSandboxed
    self.bookmarkResolver =
      bookmarkResolver
      ?? Self.makeDefaultResolver(bookmarkStore: bookmarkStore)
    self.logSink = logSink
  }

  public func submit() async -> Result<SessionStartResult, SubmitError> {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      let error = SubmitError.validation(.titleRequired)
      lastError = error
      logSink.error("new-session submit failed kind=titleRequired")
      return .failure(error)
    }
    guard let bookmarkId = selectedBookmarkId else {
      let error = SubmitError.validation(.projectRequired)
      lastError = error
      logSink.error("new-session submit failed kind=projectRequired")
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
      logSink.debug("new-session bookmark resolution failed id=\(bookmarkId)")
      logSink.error("new-session submit failed kind=bookmarkRevoked")
      return .failure(submitError)
    } catch {
      let submitError = SubmitError.unexpected(String(describing: error))
      lastError = submitError
      logSink.error("new-session submit failed kind=unexpected")
      return .failure(submitError)
    }

    if resolved.isStale {
      let error = SubmitError.bookmarkStale(id: bookmarkId)
      lastError = error
      logSink.error("new-session submit failed kind=bookmarkStale")
      return .failure(error)
    }

    logSink.info("new-session submit started")
    logSink.debug("new-session bookmark id=\(bookmarkId)")

    let projectDir = isSandboxed() ? bookmarkId : resolved.projectDir
    let request = SessionStartRequest(
      title: trimmedTitle,
      context: context,
      sessionId: nil,
      projectDir: projectDir,
      policyPreset: nil,
      baseRef: baseRef.isEmpty ? nil : baseRef
    )

    let startedSession: SessionStartResult
    do {
      startedSession = try await client.startSession(request: request)
    } catch {
      let submitError = classify(error: error)
      lastError = submitError
      logSink.error("new-session submit failed kind=\(submitErrorKind(submitError))")
      return .failure(submitError)
    }

    logSink.info("new-session submit succeeded id=\(startedSession.sessionId)")
    await store.selectSession(startedSession.sessionId)
    lastError = nil
    return .success(startedSession)
  }

  public func availableBookmarks() async -> [BookmarkStore.Record] {
    await bookmarkStore.all().filter { $0.kind == .projectRoot }
  }

  nonisolated public static func liveIsSandboxed() -> Bool {
    ProcessInfo.processInfo.environment["HARNESS_SANDBOXED"] != nil
  }

  // MARK: - Private

  private func isSandboxed() -> Bool {
    store.daemonStatus?.manifest?.sandboxed ?? isSandboxedCheck()
  }

  private func submitErrorKind(_ error: SubmitError) -> String {
    switch error {
    case .validation(let validationError):
      switch validationError {
      case .titleRequired: return "titleRequired"
      case .projectRequired: return "projectRequired"
      }
    case .bookmarkRevoked: return "bookmarkRevoked"
    case .bookmarkStale: return "bookmarkStale"
    case .daemonUnreachable: return "daemonUnreachable"
    case .invalidProject: return "invalidProject"
    case .worktreeCreateFailed: return "worktreeCreateFailed"
    case .invalidBaseRef: return "invalidBaseRef"
    case .unexpected: return "unexpected"
    }
  }

  private func classifyBookmarkError(
    _ error: BookmarkStoreError,
    bookmarkId: String
  ) -> SubmitError {
    switch error {
    case .unresolvable:
      return .bookmarkRevoked(id: bookmarkId)
    case .notFound:
      return .bookmarkRevoked(id: bookmarkId)
    case .ioError, .unsupportedSchemaVersion:
      return .unexpected(String(describing: error))
    }
  }

  private func classify(error: any Error) -> SubmitError {
    if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
      return .daemonUnreachable
    }
    if let serverError = normalizedServerError(from: error) {
      if isBookmarkResolutionFailure(message: serverError.message),
        let bookmarkId = selectedBookmarkId
      {
        return .bookmarkRevoked(id: bookmarkId)
      }
      if isInvalidProjectFailure(message: serverError.message) {
        return .invalidProject(reason: serverError.message)
      }
      if isInvalidBaseRefFailure(message: serverError.message) {
        return .invalidBaseRef(ref: baseRef, reason: serverError.message)
      }
      if isWorktreeCreateFailure(message: serverError.message) {
        return .worktreeCreateFailed(reason: serverError.message)
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

  private func isInvalidProjectFailure(message: String) -> Bool {
    let normalized = message.lowercased()
    guard normalized.contains("create session worktree") else {
      return false
    }
    return normalized.contains("no head")
      || normalized.contains("not a git repository")
      || normalized.contains("not in a git directory")
  }

  private func isBookmarkResolutionFailure(message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("resolve bookmark")
      && normalized.contains("resolution failed")
  }

  private func isInvalidBaseRefFailure(message: String) -> Bool {
    guard !baseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    let normalized = message.lowercased()
    return normalized.contains("base_ref")
      || normalized.contains("rev-parse")
      || normalized.contains("invalid reference")
      || normalized.contains("unknown revision")
      || normalized.contains("not a valid object name")
      || normalized.contains("ambiguous argument")
  }

  private func isWorktreeCreateFailure(message: String) -> Bool {
    message.lowercased().contains("create session worktree")
  }

  private func normalizedServerError(from error: any Error) -> (code: String?, message: String)? {
    if let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, let message) = apiError
    {
      return (String(code), message)
    }
    if let transportError = error as? WebSocketTransportError,
      case .serverError(let code, let message) = transportError
    {
      return (code, message)
    }
    return nil
  }
}
