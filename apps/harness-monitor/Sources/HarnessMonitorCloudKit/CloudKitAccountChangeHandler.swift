import Foundation

public struct CloudKitAccountChangeHandler: Sendable {
  public let invalidate: @Sendable () async -> Void
  public let register: @Sendable () async -> Void
  public let onChange: (@Sendable () -> Void)?

  public init(
    invalidate: @escaping @Sendable () async -> Void,
    register: @escaping @Sendable () async -> Void,
    onChange: (@Sendable () -> Void)? = nil
  ) {
    self.invalidate = invalidate
    self.register = register
    self.onChange = onChange
  }

  public func handle() async {
    await invalidate()
    await register()
    onChange?()
  }

  public static func live(onChange: (@Sendable () -> Void)? = nil) -> Self {
    Self(
      invalidate: { await NeedsMeCloudKitSubscriptionService.shared.invalidateForAccountChange() },
      register: { await NeedsMeCloudKitSubscriptionService.shared.registerIfNeeded() },
      onChange: onChange
    )
  }
}
