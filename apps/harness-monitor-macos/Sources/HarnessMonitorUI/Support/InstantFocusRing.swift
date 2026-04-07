import AppKit
import SwiftUI

/// Eliminates the system focus ring fade-in animation.
///
/// macOS animates focus ring appearance over ~150-200ms using NSAnimationContext.
/// This creates a perceptible delay between clicking a text field and seeing the
/// focus ring and cursor. InstantFocusRing suppresses that animation by wrapping
/// `NSWindow.makeFirstResponder(_:)` in a zero-duration animation context.
///
/// Apply once at the root of each scene via `.instantFocusRing()`.
public struct InstantFocusRingModifier: ViewModifier {
  public init() {}

  public func body(content: Content) -> some View {
    content.background(InstantFocusRingConfigurator())
  }
}

public extension View {
  func instantFocusRing() -> some View {
    modifier(InstantFocusRingModifier())
  }
}

private struct InstantFocusRingConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = FocusAcceleratorView()
    view.alphaValue = 0
    view.setAccessibilityHidden(true)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusAcceleratorView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    InstantFocusRingWindowSwap.install(on: window)
  }
}

/// Replaces the window's runtime class with a subclass that overrides
/// `makeFirstResponder(_:)` to suppress focus ring animation.
///
/// Uses `object_setClass` (ISA swizzle) rather than method swizzling so
/// only windows that opt in are affected. System panels, alerts, and
/// other NSWindow instances keep their default behavior.
@MainActor
private enum InstantFocusRingWindowSwap {
  private static var installedWindows: Set<ObjectIdentifier> = []

  static func install(on window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    guard !installedWindows.contains(windowID) else { return }

    let currentClass: AnyClass = type(of: window)
    let subclassName = "HarnessInstantFocus_\(NSStringFromClass(currentClass))"

    if let existingSubclass = NSClassFromString(subclassName) {
      object_setClass(window, existingSubclass)
      installedWindows.insert(windowID)
      return
    }

    guard let subclass = objc_allocateClassPair(currentClass, subclassName, 0) else {
      return
    }

    let selector = #selector(NSWindow.makeFirstResponder(_:))
    guard let originalMethod = class_getInstanceMethod(currentClass, selector) else {
      return
    }

    let originalIMP = method_getImplementation(originalMethod)
    let typeEncoding = method_getTypeEncoding(originalMethod)

    typealias MakeFirstResponderFn = @convention(c) (AnyObject, Selector, NSResponder?) -> Bool
    let originalFn = unsafeBitCast(originalIMP, to: MakeFirstResponderFn.self)

    let block: @convention(block) (AnyObject, NSResponder?) -> Bool = { obj, responder in
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
      NSAnimationContext.current.allowsImplicitAnimation = false
      let result = originalFn(obj, selector, responder)
      NSAnimationContext.endGrouping()
      return result
    }

    let implementation = imp_implementationWithBlock(block)
    class_addMethod(subclass, selector, implementation, typeEncoding)
    objc_registerClassPair(subclass)
    object_setClass(window, subclass)
    installedWindows.insert(windowID)
  }
}
