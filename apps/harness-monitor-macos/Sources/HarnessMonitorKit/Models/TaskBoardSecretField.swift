import Foundation

/// Tri-state for a task-board secret in the settings UI.
///
/// - `.notConfigured`: no secret is currently held for this scope.
/// - `.configured`: the daemon (or Keychain) reports a secret is held, but the
///   plaintext is not in memory. The UI shows a "Configured" pill and a
///   "Replace…" affordance; saving without replacing keeps the secret untouched.
/// - `.editing(String)`: the user is entering a new value. Saving sends this
///   value through to the daemon; saving an empty editing value clears the
///   secret.
public enum TaskBoardSecretField: Equatable, Sendable {
  case notConfigured
  case configured
  case editing(String)

  public static func resolved(value: String?, configured: Bool) -> Self {
    if let value, !value.isEmpty {
      return .editing(value)
    }
    return configured ? .configured : .notConfigured
  }

  /// Materialize the field for the wire. Returns `nil` when the daemon should
  /// leave the existing secret untouched (i.e. `.configured`), an empty string
  /// when the user explicitly cleared the field, or the new plaintext value
  /// when the user typed one.
  public var wireValue: String? {
    switch self {
    case .notConfigured:
      return ""
    case .configured:
      return nil
    case .editing(let value):
      return value
    }
  }

  /// `true` when the field carries a new plaintext value or is being cleared
  /// (anything that should reach the daemon save path).
  public var hasPendingChange: Bool {
    switch self {
    case .notConfigured, .editing:
      return true
    case .configured:
      return false
    }
  }

  public var isConfigured: Bool {
    if case .configured = self { return true }
    return false
  }

  public var isEditing: Bool {
    if case .editing = self { return true }
    return false
  }
}
