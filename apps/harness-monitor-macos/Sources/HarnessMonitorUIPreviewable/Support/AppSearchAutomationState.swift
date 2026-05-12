import Observation

public struct AppSearchAutomationCommand: Equatable, Sendable {
  public var generation: UInt64
  public var query: String
  public var isPresented: Bool
  public var isFocused: Bool

  public static let idle = Self(
    generation: 0,
    query: "",
    isPresented: false,
    isFocused: false
  )
}

@MainActor
@Observable
public final class AppSearchAutomationState {
  public private(set) var command = AppSearchAutomationCommand.idle

  public init() {}

  public func present(query: String, focused: Bool = true) {
    update(query: query, isPresented: true, isFocused: focused)
  }

  public func dismiss() {
    update(query: "", isPresented: false, isFocused: false)
  }

  private func update(query: String, isPresented: Bool, isFocused: Bool) {
    command = AppSearchAutomationCommand(
      generation: command.generation &+ 1,
      query: query,
      isPresented: isPresented,
      isFocused: isFocused
    )
  }
}
