import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

private enum AccessibilityQueryDefaults {
  static let preferredBundleIdentifiers = [
    "io.harnessmonitor.app",
    "io.harnessmonitor.app.ui-testing"
  ]
  static let maximumWindowMatchScore = 240
}

private enum AccessibilityAttributeName {
  static let identifier = "AXIdentifier"
  static let selected = "AXSelected"
  static let windowNumber = "AXWindowNumber"
}

private enum AccessibilityTraversalDefaults {
  static let excludedAttributes: Set<String> = [
    kAXParentAttribute as String,
    kAXWindowAttribute as String,
    "AXTopLevelUIElement",
  ]
}

private struct AccessibilityQueryRect: Codable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  init(_ rect: CGRect) {
    x = rect.origin.x
    y = rect.origin.y
    width = rect.size.width
    height = rect.size.height
  }
}

private enum AccessibilityQueryElementKind: String, Codable {
  case button
  case toggle
  case textField
  case text
  case link
  case list
  case row
  case tab
  case menuItem
  case image
  case other
}

private struct AccessibilityQueryElement: Codable {
  let identifier: String
  let label: String?
  let value: String?
  let hint: String?
  let kind: AccessibilityQueryElementKind
  let frame: AccessibilityQueryRect
  let windowID: Int?
  let enabled: Bool
  let selected: Bool
  let focused: Bool
}

private struct AccessibilityListElementsOutput: Codable {
  let elements: [AccessibilityQueryElement]
}

private struct AccessibilityGetElementOutput: Codable {
  let element: AccessibilityQueryElement
}

private struct AccessibilityQueryWindowCandidate {
  let id: Int
  let title: String?
  let frame: CGRect
}

private struct AccessibilityListArguments {
  let bundleIdentifier: String?
  let windowID: Int?
  let kind: AccessibilityQueryElementKind?

  init(_ args: [String]) throws {
    var bundleIdentifier: String?
    var windowID: Int?
    var kind: AccessibilityQueryElementKind?
    var index = 0
    while index < args.count {
      let argument = args[index]
      switch argument {
      case "--bundle-id":
        guard index + 1 < args.count else {
          throw InputToolError.usage("list-elements [--bundle-id id] [--window-id id] [--kind kind]")
        }
        bundleIdentifier = args[index + 1]
        index += 2
      case "--window-id":
        guard index + 1 < args.count else {
          throw InputToolError.usage("list-elements [--bundle-id id] [--window-id id] [--kind kind]")
        }
        guard let parsed = Int(args[index + 1]) else {
          throw InputToolError.invalidNumber(args[index + 1])
        }
        windowID = parsed
        index += 2
      case "--kind":
        guard index + 1 < args.count else {
          throw InputToolError.usage("list-elements [--bundle-id id] [--window-id id] [--kind kind]")
        }
        guard let parsed = AccessibilityQueryElementKind(rawValue: args[index + 1]) else {
          throw InputToolError.usage("unknown kind: \(args[index + 1])")
        }
        kind = parsed
        index += 2
      default:
        throw InputToolError.usage("unknown flag: \(argument)")
      }
    }

    self.bundleIdentifier = bundleIdentifier
    self.windowID = windowID
    self.kind = kind
  }
}

private struct AccessibilityGetArguments {
  let bundleIdentifier: String?
  let identifier: String

  init(_ args: [String]) throws {
    var bundleIdentifier: String?
    var identifier: String?
    var index = 0
    while index < args.count {
      let argument = args[index]
      switch argument {
      case "--bundle-id":
        guard index + 1 < args.count else {
          throw InputToolError.usage("get-element [--bundle-id id] <identifier>")
        }
        bundleIdentifier = args[index + 1]
        index += 2
      default:
        guard identifier == nil else {
          throw InputToolError.usage("get-element [--bundle-id id] <identifier>")
        }
        identifier = argument
        index += 1
      }
    }

    guard let identifier, !identifier.isEmpty else {
      throw InputToolError.usage("get-element [--bundle-id id] <identifier>")
    }

    self.bundleIdentifier = bundleIdentifier
    self.identifier = identifier
  }
}

func handleListElements(_ args: [String]) throws {
  let arguments = try AccessibilityListArguments(args)
  try requireTrustedAccessibility()
  let elements = try accessibilityElements(
    bundleIdentifier: arguments.bundleIdentifier,
    windowID: arguments.windowID,
    kind: arguments.kind
  )
  try writeJSON(AccessibilityListElementsOutput(elements: elements))
}

func handleGetElement(_ args: [String]) throws {
  let arguments = try AccessibilityGetArguments(args)
  try requireTrustedAccessibility()
  let elements = try accessibilityElements(bundleIdentifier: arguments.bundleIdentifier)
  guard let element = elements.first(where: { $0.identifier == arguments.identifier }) else {
    throw InputToolError.notFound(arguments.identifier)
  }
  try writeJSON(AccessibilityGetElementOutput(element: element))
}

private func accessibilityElements(
  bundleIdentifier: String? = nil,
  windowID: Int? = nil,
  kind: AccessibilityQueryElementKind? = nil
) throws -> [AccessibilityQueryElement] {
  let app = try resolveHarnessMonitorApplication(bundleIdentifier: bundleIdentifier)
  let windowCandidates = cgWindowCandidates(processID: app.processIdentifier)
  let windows = accessibilityWindows(for: app)

  var harvested: [String: AccessibilityQueryElement] = [:]
  for window in windows {
    let matchedWindowID = matchWindowID(for: window, candidates: windowCandidates)
    if let windowID, matchedWindowID != windowID {
      continue
    }
    for element in collectElements(in: window, windowID: matchedWindowID) {
      if let kind, element.kind != kind {
        continue
      }
      harvested[element.identifier] = element
    }
  }

  return harvested.values.sorted { $0.identifier < $1.identifier }
}

private func resolveHarnessMonitorApplication(
  bundleIdentifier: String?
) throws -> NSRunningApplication {
  let candidates: [NSRunningApplication]
  if let bundleIdentifier {
    candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
  } else {
    candidates = AccessibilityQueryDefaults.preferredBundleIdentifiers.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }
  }

  guard !candidates.isEmpty else {
    throw InputToolError.appNotRunning(
      bundleIdentifier ?? AccessibilityQueryDefaults.preferredBundleIdentifiers.joined(separator: ", ")
    )
  }

  return candidates.max { lhs, rhs in
    let lhsDate = lhs.launchDate ?? .distantPast
    let rhsDate = rhs.launchDate ?? .distantPast
    if lhsDate != rhsDate {
      return lhsDate < rhsDate
    }
    return preferredBundlePriority(lhs.bundleIdentifier) > preferredBundlePriority(rhs.bundleIdentifier)
  }!
}

private func preferredBundlePriority(_ bundleIdentifier: String?) -> Int {
  guard
    let bundleIdentifier,
    let index = AccessibilityQueryDefaults.preferredBundleIdentifiers.firstIndex(of: bundleIdentifier)
  else {
    return AccessibilityQueryDefaults.preferredBundleIdentifiers.count
  }
  return index
}

private func accessibilityWindows(for app: NSRunningApplication) -> [AXUIElement] {
  let appElement = AXUIElementCreateApplication(app.processIdentifier)
  var windows = axElementArray(appElement, kAXWindowsAttribute)
  if let focusedWindow = axElement(appElement, kAXFocusedWindowAttribute) {
    windows.append(focusedWindow)
  }
  if let mainWindow = axElement(appElement, kAXMainWindowAttribute) {
    windows.append(mainWindow)
  }

  var deduped: [AXUIElement] = []
  var seen: Set<OpaquePointer> = []
  for window in windows {
    let pointer = Unmanaged.passUnretained(window).toOpaque()
    let opaque = OpaquePointer(pointer)
    if seen.insert(opaque).inserted {
      deduped.append(window)
    }
  }
  return deduped
}

private func cgWindowCandidates(processID: pid_t) -> [AccessibilityQueryWindowCandidate] {
  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  let windowInfo =
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

  return windowInfo.compactMap { info in
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID else {
      return nil
    }
    let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    guard alpha > 0 else {
      return nil
    }
    guard
      let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
      bounds.isEmpty == false,
      let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue
    else {
      return nil
    }

    let title = normalizedString(info[kCGWindowName as String] as? String)
    return AccessibilityQueryWindowCandidate(id: number, title: title, frame: bounds)
  }
}

private func matchWindowID(
  for window: AXUIElement,
  candidates: [AccessibilityQueryWindowCandidate]
) -> Int? {
  if let directWindowNumber = axInt(window, AccessibilityAttributeName.windowNumber) {
    return directWindowNumber
  }
  guard !candidates.isEmpty else {
    return nil
  }

  let title = normalizedString(axString(window, kAXTitleAttribute))
  let frame = axFrame(window)
  let scored = candidates.map { candidate in
    (
      score: windowMatchScore(
        title: title,
        frame: frame,
        candidate: candidate
      ),
      id: candidate.id
    )
  }
  guard let best = scored.min(by: { $0.score < $1.score }) else {
    return nil
  }
  guard best.score <= AccessibilityQueryDefaults.maximumWindowMatchScore else {
    return nil
  }
  return best.id
}

private func windowMatchScore(
  title: String?,
  frame: CGRect?,
  candidate: AccessibilityQueryWindowCandidate
) -> Int {
  var score = 0
  if title != candidate.title {
    score += 1_000
  }
  if let frame {
    score += intDistance(frame.origin.x, candidate.frame.origin.x)
    score += intDistance(frame.origin.y, candidate.frame.origin.y)
    score += intDistance(frame.size.width, candidate.frame.size.width)
    score += intDistance(frame.size.height, candidate.frame.size.height)
  }
  return score
}

private func intDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> Int {
  Int((lhs - rhs).magnitude.rounded())
}

private func collectElements(
  in window: AXUIElement,
  windowID: Int?
) -> [AccessibilityQueryElement] {
  var queue = [window]
  var visited: Set<OpaquePointer> = []
  var harvested: [String: AccessibilityQueryElement] = [:]

  while !queue.isEmpty {
    let node = queue.removeFirst()
    let pointer = Unmanaged.passUnretained(node).toOpaque()
    let opaque = OpaquePointer(pointer)
    guard visited.insert(opaque).inserted else {
      continue
    }

    if let element = accessibilityElement(from: node, windowID: windowID) {
      harvested[element.identifier] = element
    }
    queue.append(contentsOf: axRelatedElements(node))
  }

  return harvested.values.sorted { $0.identifier < $1.identifier }
}

private func accessibilityElement(
  from node: AXUIElement,
  windowID: Int?
) -> AccessibilityQueryElement? {
  guard let identifier = normalizedString(axString(node, AccessibilityAttributeName.identifier)) else {
    return nil
  }
  guard let frame = axFrame(node), frame.isEmpty == false, frame.isInfinite == false else {
    return nil
  }

  let role = axString(node, kAXRoleAttribute) ?? ""
  if role == kAXWindowRole as String {
    return nil
  }

  let label =
    normalizedString(axString(node, kAXTitleAttribute))
    ?? normalizedString(axString(node, kAXDescriptionAttribute))
  let hint = normalizedString(axString(node, kAXHelpAttribute))

  return AccessibilityQueryElement(
    identifier: identifier,
    label: label,
    value: normalizedAccessibilityValue(axAttributeValue(node, kAXValueAttribute)),
    hint: hint,
    kind: elementKind(forRole: role),
    frame: AccessibilityQueryRect(frame),
    windowID: windowID,
    enabled: axBool(node, kAXEnabledAttribute) ?? true,
    selected: axBool(node, AccessibilityAttributeName.selected) ?? false,
    focused: axBool(node, kAXFocusedAttribute) ?? false
  )
}

private func elementKind(forRole role: String) -> AccessibilityQueryElementKind {
  let normalizedRole = role.lowercased()
  if normalizedRole.contains("checkbox")
    || normalizedRole.contains("radio")
    || normalizedRole.contains("switch")
    || normalizedRole.contains("toggle")
  {
    return .toggle
  }
  if normalizedRole.contains("searchfield")
    || normalizedRole.contains("textfield")
    || normalizedRole.contains("text field")
  {
    return .textField
  }
  if normalizedRole.contains("statictext") || normalizedRole.contains("text area") {
    return .text
  }
  if normalizedRole.contains("button") {
    return .button
  }
  if normalizedRole.contains("table") || normalizedRole.contains("list") {
    return .list
  }
  if normalizedRole.contains("row") {
    return .row
  }
  if normalizedRole.contains("tab") {
    return .tab
  }
  if normalizedRole.contains("image") {
    return .image
  }
  if normalizedRole.contains("link") {
    return .link
  }
  if normalizedRole.contains("menuitem") || normalizedRole.contains("menu item") {
    return .menuItem
  }
  return .other
}

private func writeJSON<T: Encodable>(_ payload: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data: Data
  do {
    data = try encoder.encode(payload)
  } catch {
    throw InputToolError.queryFailed(error.localizedDescription)
  }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

private func axAttributeValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
  guard error == .success else {
    return nil
  }
  return value
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
  axAttributeValue(element, attribute) as? String
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
  (axAttributeValue(element, attribute) as? NSNumber)?.boolValue
}

private func axInt(_ element: AXUIElement, _ attribute: String) -> Int? {
  (axAttributeValue(element, attribute) as? NSNumber)?.intValue
}

private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
  guard let value = axAttributeValue(element, attribute) else {
    return nil
  }
  return unsafeDowncast(value, to: AXUIElement.self)
}

private func axElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
  (axAttributeValue(element, attribute) as? [AXUIElement]) ?? []
}

private func axRelatedElements(_ element: AXUIElement) -> [AXUIElement] {
  var attributeNames: CFArray?
  guard AXUIElementCopyAttributeNames(element, &attributeNames) == .success,
    let names = attributeNames as? [String]
  else {
    return []
  }

  var related: [AXUIElement] = []
  var seen: Set<OpaquePointer> = []
  for attribute in names.sorted() {
    guard !AccessibilityTraversalDefaults.excludedAttributes.contains(attribute) else {
      continue
    }
    if let relatedElement = axElement(element, attribute) {
      appendRelatedElement(relatedElement, to: &related, seen: &seen)
    }
    for relatedElement in axElementArray(element, attribute) {
      appendRelatedElement(relatedElement, to: &related, seen: &seen)
    }
  }
  return related
}

private func appendRelatedElement(
  _ element: AXUIElement,
  to related: inout [AXUIElement],
  seen: inout Set<OpaquePointer>
) {
  let pointer = Unmanaged.passUnretained(element).toOpaque()
  let opaque = OpaquePointer(pointer)
  guard seen.insert(opaque).inserted else {
    return
  }
  related.append(element)
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
  guard
    let positionValue = axAttributeValue(element, kAXPositionAttribute),
    let sizeValue = axAttributeValue(element, kAXSizeAttribute),
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else {
    return nil
  }

  let positionAX = unsafeDowncast(positionValue, to: AXValue.self)
  let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)
  guard
    AXValueGetType(positionAX) == .cgPoint,
    AXValueGetType(sizeAX) == .cgSize
  else {
    return nil
  }

  var position = CGPoint.zero
  var size = CGSize.zero
  guard
    AXValueGetValue(positionAX, .cgPoint, &position),
    AXValueGetValue(sizeAX, .cgSize, &size)
  else {
    return nil
  }

  return CGRect(origin: position, size: size)
}

private func normalizedString(_ value: String?) -> String? {
  guard let value else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func normalizedAccessibilityValue(_ value: CFTypeRef?) -> String? {
  switch value {
  case let string as String:
    return normalizedString(string)
  case let attributed as NSAttributedString:
    return normalizedString(attributed.string)
  case let number as NSNumber:
    return number.stringValue
  case let text as NSString:
    return normalizedString(text as String)
  case nil:
    return nil
  default:
    return normalizedString(String(describing: value))
  }
}
