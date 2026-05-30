import Foundation

public enum AutomationSourceAppMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case allExceptDenied
  case allowedOnly

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .allExceptDenied: "All except denied"
    case .allowedOnly: "Allowed apps only"
    }
  }
}

public struct AutomationSourceApplication: Codable, Equatable, Sendable {
  public var bundleIdentifier: String?
  public var localizedName: String?
  public var processIdentifier: Int32?
  public var confidence: String

  public init(
    bundleIdentifier: String?,
    localizedName: String?,
    processIdentifier: Int32?,
    confidence: String = "frontmost-application"
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.localizedName = localizedName
    self.processIdentifier = processIdentifier
    self.confidence = confidence
  }

  public var displayName: String {
    localizedName ?? bundleIdentifier ?? "Unknown app"
  }
}

public struct AutomationSourceAppFilter: Codable, Equatable, Sendable {
  public var mode: AutomationSourceAppMode
  public var allowedBundleIdentifiers: [String]
  public var deniedBundleIdentifiers: [String]

  public init(
    mode: AutomationSourceAppMode = .allExceptDenied,
    allowedBundleIdentifiers: [String] = [],
    deniedBundleIdentifiers: [String] = []
  ) {
    self.mode = mode
    self.allowedBundleIdentifiers = Self.normalizedIdentifiers(allowedBundleIdentifiers)
    self.deniedBundleIdentifiers = Self.normalizedIdentifiers(deniedBundleIdentifiers)
  }

  public func allows(_ sourceApplication: AutomationSourceApplication?) -> Bool {
    let bundleIdentifier = sourceApplication?.bundleIdentifier?.lowercased()
    if let bundleIdentifier, deniedBundleIdentifiers.contains(bundleIdentifier) {
      return false
    }
    switch mode {
    case .allExceptDenied:
      return true
    case .allowedOnly:
      guard let bundleIdentifier else {
        return false
      }
      return allowedBundleIdentifiers.contains(bundleIdentifier)
    }
  }

  static func normalizedIdentifiers(_ identifiers: [String]) -> [String] {
    var seen = Set<String>()
    return
      identifiers
      .flatMap {
        $0.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
      }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}
