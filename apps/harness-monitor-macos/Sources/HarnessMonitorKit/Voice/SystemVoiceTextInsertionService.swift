import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum SystemVoiceTextInsertionResult: Equatable, Sendable {
  case insertedWithAccessibility
  case copiedToPasteboard
  case accessibilityPermissionRequired
  case emptyText
}

@MainActor
public struct SystemVoiceTextInsertionService: Sendable {
  public init() {}

  public func accessibilityIsTrusted(prompt: Bool) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  @discardableResult
  public func insertConfirmedText(_ text: String, promptForAccessibility: Bool = true)
    -> SystemVoiceTextInsertionResult
  {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      return .emptyText
    }

    guard accessibilityIsTrusted(prompt: promptForAccessibility) else {
      copyToPasteboard(trimmedText)
      return .accessibilityPermissionRequired
    }

    if insertWithAccessibility(trimmedText) {
      return .insertedWithAccessibility
    }
    copyToPasteboard(trimmedText)
    return .copiedToPasteboard
  }

  private func insertWithAccessibility(_ text: String) -> Bool {
    let systemElement = AXUIElementCreateSystemWide()
    var focusedValue: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(
      systemElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    )
    guard focusedResult == .success,
      let focusedElement = focusedValue
    else {
      return false
    }

    guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
      return false
    }
    let element = focusedElement as! AXUIElement
    let result = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      text as CFTypeRef
    )
    return result == .success
  }

  private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
