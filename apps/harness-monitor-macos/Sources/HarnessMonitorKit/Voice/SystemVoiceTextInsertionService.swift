import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum SystemVoiceTextInsertionResult: Equatable, Sendable {
  case insertedWithAccessibility
  case manualInsertionRequired
  case accessibilityPermissionRequired
  case emptyText
}

@MainActor
public struct SystemVoiceTextInsertionService: Sendable {
  private let accessibilityTrustCheck: @MainActor @Sendable (Bool) -> Bool
  private let accessibilityInserter: @MainActor @Sendable (String) -> Bool
  private let pasteboardWriter: @MainActor @Sendable (String) -> Void

  public init() {
    self.init(
      accessibilityTrustCheck: Self.defaultAccessibilityTrustCheck(prompt:),
      accessibilityInserter: Self.insertWithAccessibilitySystem(_:),
      pasteboardWriter: Self.writeToPasteboard(_:))
  }

  init(
    accessibilityTrustCheck: @escaping @MainActor @Sendable (Bool) -> Bool,
    accessibilityInserter: @escaping @MainActor @Sendable (String) -> Bool,
    pasteboardWriter: @escaping @MainActor @Sendable (String) -> Void
  ) {
    self.accessibilityTrustCheck = accessibilityTrustCheck
    self.accessibilityInserter = accessibilityInserter
    self.pasteboardWriter = pasteboardWriter
  }

  public func accessibilityIsTrusted(prompt: Bool) -> Bool {
    accessibilityTrustCheck(prompt)
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
      return .accessibilityPermissionRequired
    }

    if insertWithAccessibility(trimmedText) {
      return .insertedWithAccessibility
    }
    return .manualInsertionRequired
  }

  @discardableResult
  public func copyTextToPasteboard(_ text: String) -> Bool {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      return false
    }
    pasteboardWriter(trimmedText)
    return true
  }

  private func insertWithAccessibility(_ text: String) -> Bool {
    accessibilityInserter(text)
  }

  private static func defaultAccessibilityTrustCheck(prompt: Bool) -> Bool {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private static func insertWithAccessibilitySystem(_ text: String) -> Bool {
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

    guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID(),
      let element = focusedElement as? AXUIElement
    else {
      return false
    }
    let result = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      text as CFTypeRef
    )
    return result == .success
  }

  private static func writeToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
