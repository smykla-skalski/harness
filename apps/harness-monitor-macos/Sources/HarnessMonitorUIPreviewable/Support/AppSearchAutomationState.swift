import Observation

public struct AppSearchAutomationCommand: Equatable, Sendable {
  public var generation: UInt64
  public var query: String
  public var isPresented: Bool

  public static let idle = Self(
    generation: 0,
    query: "",
    isPresented: false
  )
}

@MainActor
@Observable
public final class AppSearchAutomationState {
  public private(set) var command = AppSearchAutomationCommand.idle
  @ObservationIgnored public var handler: ((AppSearchAutomationCommand) -> Void)?

  public init() {}

  public func present(query: String) {
    update(query: query, isPresented: true)
  }

  public func dismiss() {
    update(query: "", isPresented: false)
  }

  private func update(query: String, isPresented: Bool) {
    command = AppSearchAutomationCommand(
      generation: command.generation &+ 1,
      query: query,
      isPresented: isPresented
    )
    handler?(command)
  }
}
