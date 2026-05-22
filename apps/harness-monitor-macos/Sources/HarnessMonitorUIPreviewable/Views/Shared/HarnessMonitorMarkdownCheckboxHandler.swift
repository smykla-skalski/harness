import SwiftUI

/// Handler invoked when an interactive markdown checkbox is toggled. The
/// `sourceOffset` is the UTF-8 byte offset (in the original markdown body) of
/// the marker character inside `[ ]` / `[x]`, as recorded by
/// `HarnessMarkdownParser`.
public struct HarnessMarkdownCheckboxToggleHandler: Sendable {
  let perform: @MainActor (Int, Bool) -> Void

  public init(_ perform: @escaping @MainActor (Int, Bool) -> Void) {
    self.perform = perform
  }
}

private struct HarnessMarkdownCheckboxToggleHandlerKey: EnvironmentKey {
  static let defaultValue: HarnessMarkdownCheckboxToggleHandler? = nil
}

extension EnvironmentValues {
  var harnessMarkdownCheckboxToggleHandler: HarnessMarkdownCheckboxToggleHandler? {
    get { self[HarnessMarkdownCheckboxToggleHandlerKey.self] }
    set { self[HarnessMarkdownCheckboxToggleHandlerKey.self] = newValue }
  }
}

extension View {
  /// Make checkboxes in any descendant `HarnessMonitorMarkdownText` interactive.
  /// The closure receives `(sourceOffset, newValue)` so the caller can flip the
  /// single character in the source markdown body.
  public func markdownCheckboxToggle(
    _ perform: @escaping @MainActor (Int, Bool) -> Void
  ) -> some View {
    environment(
      \.harnessMarkdownCheckboxToggleHandler,
      HarnessMarkdownCheckboxToggleHandler(perform)
    )
  }
}
