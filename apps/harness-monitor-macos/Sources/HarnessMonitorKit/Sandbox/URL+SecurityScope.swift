import Foundation

extension URL {
  /// Runs `body` with `startAccessingSecurityScopedResource` held for the
  /// duration of the call. The scope is released even when `body` throws.
  ///
  /// If the URL does not carry a security scope (e.g. it's inside the app
  /// container), `body` still runs - `startAccessing...` returns `false`
  /// and we simply don't pair it with a `stopAccessing...` call.
  public func withSecurityScope<T>(_ body: (URL) throws -> T) throws -> T {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try body(self)
  }

  /// Async counterpart to `withSecurityScope` for awaiting bodies.
  public func withSecurityScopeAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try await body(self)
  }
}
