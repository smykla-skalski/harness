import Carbon
import Foundation
import HarnessMonitorKit

@MainActor
final class GlobalHotKeyController {
  // Carbon callback storage. The Carbon event handler runs on its own thread
  // and dereferences the controller via an `Unmanaged.passUnretained` pointer,
  // so the deinit cleanup must be safe to run from outside the main actor.
  // `nonisolated(unsafe)` lets `deinit` call `UnregisterEventHotKey` and
  // `RemoveEventHandler` without hopping back to MainActor (which is itself
  // unsafe from a deinit on a deallocating instance).
  nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
  nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
  private var installedDescriptor: OpenAnythingHotKeyDescriptor?
  private var onInvoke: (@MainActor @Sendable () -> Void)?

  deinit {
    // Tear down Carbon registrations inline to avoid leaking the event handler
    // ref or the hot key ref. The Carbon callback closes over
    // `Unmanaged.passUnretained(self).toOpaque()`, so the handler MUST be
    // removed before the hot key is unregistered: `RemoveEventHandler` blocks
    // any in-flight callback and prevents new invocations, making the
    // unretained pointer safe to abandon. Reversing this order leaves a window
    // where Carbon could dispatch into a deallocating controller.
    if let eventHandlerRef {
      RemoveEventHandler(eventHandlerRef)
    }
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
  }

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
    guard installEventHandlerIfNeeded() else {
      unregisterHotKey()
      installedDescriptor = nil
      return
    }
    guard installedDescriptor != descriptor else { return }
    unregisterHotKey()
    registerHotKey(descriptor)
  }

  func handleHotKey() {
    onInvoke?()
  }

  private func installEventHandlerIfNeeded() -> Bool {
    guard eventHandlerRef == nil else { return true }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let userData = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      globalOpenAnythingHotKeyHandler,
      1,
      &eventType,
      userData,
      &eventHandlerRef
    )
    if status != noErr {
      eventHandlerRef = nil
      UserDefaults.standard.set(false, forKey: OpenAnythingHotKeyDefaults.enabledKey)
      HarnessMonitorLogger.store.warning(
        "Failed to install Open Anything hot key handler: \(status, privacy: .public)"
      )
      return false
    }
    return true
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
      UserDefaults.standard.set(false, forKey: OpenAnythingHotKeyDefaults.enabledKey)
      HarnessMonitorLogger.store.warning(
        "Failed to register Open Anything hot key: \(status, privacy: .public)"
      )
    }
  }

  private func unregisterHotKey() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    hotKeyRef = nil
  }

  /// Carbon four-character code for the Open Anything hot key signature.
  ///
  /// ASCII bytes of `"OANY"` packed into a `UInt32`:
  /// `0x4F` ('O'), `0x41` ('A'), `0x4E` ('N'), `0x59` ('Y').
  /// Kept as a literal so the value is grep-able and obviously stable across
  /// releases — Carbon uses this signature to disambiguate our hot key from
  /// other apps registering the same key combination.
  private static let signature: OSType = 0x4F41_4E59
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
