import AppKit

@MainActor
final class HarnessMonitorApplicationPresenceController {
  enum Mode: Equatable, Sendable {
    case dynamic
    case alwaysRegular
    case alwaysAccessory
  }

  static let shared = HarnessMonitorApplicationPresenceController()

  private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
  nonisolated(unsafe) private var closeObserver: NSObjectProtocol?
  private var mode = Mode.alwaysRegular
  private var applicationWindowIDs: Set<ObjectIdentifier> = []
  private var appliedActivationPolicy: NSApplication.ActivationPolicy?

  init(
    setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool = {
      NSApplication.shared.setActivationPolicy($0)
    }
  ) {
    self.setActivationPolicy = setActivationPolicy
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      let windowID = ObjectIdentifier(window)
      Task { @MainActor [weak self] in
        self?.applicationWindowWillClose(windowID)
      }
    }
  }

  deinit {
    if let closeObserver {
      NotificationCenter.default.removeObserver(closeObserver)
    }
  }

  func configure(mode: Mode) {
    self.mode = mode
    applicationWindowIDs.removeAll()
    appliedActivationPolicy = nil
    applyDesiredActivationPolicy()
  }

  func applicationWindowDidOpen(_ windowID: ObjectIdentifier) {
    guard applicationWindowIDs.insert(windowID).inserted else { return }
    applyDesiredActivationPolicy()
  }

  func prepareToPresentApplicationWindow() {
    guard mode != .alwaysAccessory else { return }
    applyActivationPolicy(.regular)
  }

  func applicationWindowWillClose(_ windowID: ObjectIdentifier) {
    guard applicationWindowIDs.remove(windowID) != nil else { return }
    applyDesiredActivationPolicy()
  }

  private func applyDesiredActivationPolicy() {
    let desiredPolicy: NSApplication.ActivationPolicy =
      switch mode {
      case .dynamic:
        applicationWindowIDs.isEmpty ? .accessory : .regular
      case .alwaysRegular:
        .regular
      case .alwaysAccessory:
        .accessory
      }
    applyActivationPolicy(desiredPolicy)
  }

  private func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
    guard appliedActivationPolicy != policy else { return }
    guard setActivationPolicy(policy) else { return }
    appliedActivationPolicy = policy
  }
}
