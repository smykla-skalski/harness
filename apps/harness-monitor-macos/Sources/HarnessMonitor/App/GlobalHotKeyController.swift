import Carbon
import HarnessMonitorKit

@MainActor
final class GlobalHotKeyController {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private var installedDescriptor: OpenAnythingHotKeyDescriptor?
  private var onInvoke: (@MainActor @Sendable () -> Void)?

  func configure(
    enabled: Bool,
    descriptor: OpenAnythingHotKeyDescriptor,
    onInvoke: @escaping @MainActor @Sendable () -> Void
  ) {
    self.onInvoke = onInvoke
    guard enabled, descriptor.isValid else {
      unregisterHotKey()
      installedDescriptor = nil
      return
    }
    installEventHandlerIfNeeded()
    guard installedDescriptor != descriptor else { return }
    unregisterHotKey()
    registerHotKey(descriptor)
  }

  func handleHotKey() {
    onInvoke?()
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandlerRef == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let userData = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      globalOpenAnythingHotKeyHandler,
      1,
      &eventType,
      userData,
      &eventHandlerRef
    )
  }

  private func registerHotKey(_ descriptor: OpenAnythingHotKeyDescriptor) {
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    let status = RegisterEventHotKey(
      descriptor.keyCode,
      descriptor.modifiers.carbonFlags,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
    if status == noErr {
      installedDescriptor = descriptor
    } else {
      installedDescriptor = nil
      hotKeyRef = nil
    }
  }

  private func unregisterHotKey() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    hotKeyRef = nil
  }

  private static let signature: OSType = {
    var result: UInt32 = 0
    for scalar in "OANY".unicodeScalars {
      result = (result << 8) + UInt32(scalar.value)
    }
    return OSType(result)
  }()
}

private let globalOpenAnythingHotKeyHandler: EventHandlerUPP = { _, _, userData in
  guard let userData else { return noErr }
  let controller = Unmanaged<GlobalHotKeyController>
    .fromOpaque(userData)
    .takeUnretainedValue()
  Task { @MainActor in
    controller.handleHotKey()
  }
  return noErr
}

extension OpenAnythingHotKeyModifiers {
  fileprivate var carbonFlags: UInt32 {
    var flags: UInt32 = 0
    if contains(.control) { flags |= UInt32(controlKey) }
    if contains(.option) { flags |= UInt32(optionKey) }
    if contains(.command) { flags |= UInt32(cmdKey) }
    if contains(.shift) { flags |= UInt32(shiftKey) }
    return flags
  }
}
