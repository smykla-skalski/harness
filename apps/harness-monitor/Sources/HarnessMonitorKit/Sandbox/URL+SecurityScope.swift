import Foundation

public final class SecurityScopedURLAccess {
  public let url: URL
  private let started: Bool
  private var isActive: Bool

  fileprivate init(url: URL) {
    self.url = url
    started = url.startAccessingSecurityScopedResource()
    isActive = true
  }

  deinit {
    invalidate()
  }

  public func invalidate() {
    guard isActive else { return }
    isActive = false
    if started {
      url.stopAccessingSecurityScopedResource()
    }
  }
}

extension URL {
  /// Runs `body` with `startAccessingSecurityScopedResource` held for the
  /// duration of the call. The scope is released even when `body` throws.
  ///
  /// If the URL does not carry a security scope (e.g. it's inside the app
  /// container), `body` still runs - `startAccessing...` returns `false`
  /// and we simply don't pair it with a `stopAccessing...` call.
  public func withSecurityScope<T>(_ body: (URL) throws -> T) rethrows -> T {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try body(self)
  }

  /// Begins a security-scoped access window that the caller explicitly owns.
  ///
  /// Use this for long-lived file presenters or dispatch-source watchers where
  /// a synchronous `withSecurityScope` closure would release access too early.
  public func beginSecurityScope() -> SecurityScopedURLAccess {
    SecurityScopedURLAccess(url: self)
  }

  /// Async counterpart to `withSecurityScope`.
  ///
  /// Named separately because Swift 6 overload resolution between sync and
  /// async throwing closures causes spurious `await` warnings when the two
  /// share a name. Callers use `withSecurityScopeAsync` in async contexts.
  public func withSecurityScopeAsync<T>(
    _ body: @Sendable (URL) async throws -> T
  ) async rethrows -> T {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try await body(self)
  }
}
