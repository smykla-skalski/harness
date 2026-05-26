import Foundation

public enum AutomationPolicyEventSource: String, CaseIterable, Codable, Identifiable, Sendable {
  case clipboard
  case manualOCRPaste
  case ocrDrop
  case ocrFilePicker
  case screenshotFolder

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .clipboard: "Clipboard"
    case .manualOCRPaste: "Manual Paste"
    case .ocrDrop: "Drag and Drop"
    case .ocrFilePicker: "File Picker"
    case .screenshotFolder: "Screenshot Folder"
    }
  }

  public var detail: String {
    switch self {
    case .clipboard:
      "Watches NSPasteboard.general change counts while the app is running."
    case .manualOCRPaste:
      "Handles focused Cmd+V and SwiftUI paste destinations."
    case .ocrDrop:
      "Handles images dropped onto the Debugging OCR card."
    case .ocrFilePicker:
      "Handles images selected through the file picker."
    case .screenshotFolder:
      "Handles files created in the configured screenshot folder."
    }
  }
}

public enum AutomationClipboardContentKind: String, CaseIterable, Codable, Hashable, Sendable {
  case image
  case text
  case file
  case url
  case unknown

  public var title: String {
    switch self {
    case .image: "Images"
    case .text: "Text"
    case .file: "Files"
    case .url: "URLs"
    case .unknown: "Unknown"
    }
  }
}

public enum AutomationPolicyPreprocessor: String, CaseIterable, Codable, Identifiable, Sendable {
  case respectPasteboardPrivacy
  case skipSensitiveMarkers
  case filterSourceApplications
  case dedupeByFingerprint

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .respectPasteboardPrivacy: "Respect pasteboard privacy"
    case .skipSensitiveMarkers: "Skip concealed/transient content"
    case .filterSourceApplications: "Filter source applications"
    case .dedupeByFingerprint: "Dedupe by fingerprint"
    }
  }
}

public enum AutomationPolicyAction: String, CaseIterable, Codable, Identifiable, Sendable {
  case ocrImage
  case rememberRecentScan
  case showFeedback
  case openDashboardDebugging
  case recordMetadata

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .ocrImage: "OCR images"
    case .rememberRecentScan: "Remember recent scans"
    case .showFeedback: "Show feedback"
    case .openDashboardDebugging: "Open Debugging"
    case .recordMetadata: "Record metadata"
    }
  }
}

public enum AutomationPolicyPostprocessor: String, CaseIterable, Codable, Identifiable, Sendable {
  case sourceSpecificTextCleanup
  case persistResult
  case auditEvent

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .sourceSpecificTextCleanup: "Source-specific text cleanup"
    case .persistResult: "Persist result"
    case .auditEvent: "Audit event"
    }
  }
}

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
        $0.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
      }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

public struct AutomationPolicyMatch: Codable, Equatable, Sendable {
  public var contentKinds: Set<AutomationClipboardContentKind>
  public var sourceAppFilter: AutomationSourceAppFilter

  public init(
    contentKinds: Set<AutomationClipboardContentKind>,
    sourceAppFilter: AutomationSourceAppFilter = AutomationSourceAppFilter()
  ) {
    self.contentKinds = contentKinds
    self.sourceAppFilter = sourceAppFilter
  }
}

public struct AutomationPolicy: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var eventSource: AutomationPolicyEventSource
  public var isEnabled: Bool
  public var priority: Int
  public var match: AutomationPolicyMatch
  public var preprocessors: [AutomationPolicyPreprocessor]
  public var actions: [AutomationPolicyAction]
  public var postprocessors: [AutomationPolicyPostprocessor]

  public init(
    id: String,
    name: String,
    eventSource: AutomationPolicyEventSource,
    isEnabled: Bool,
    priority: Int,
    match: AutomationPolicyMatch,
    preprocessors: [AutomationPolicyPreprocessor],
    actions: [AutomationPolicyAction],
    postprocessors: [AutomationPolicyPostprocessor]
  ) {
    self.id = id
    self.name = name
    self.eventSource = eventSource
    self.isEnabled = isEnabled
    self.priority = priority
    self.match = match
    self.preprocessors = preprocessors
    self.actions = actions
    self.postprocessors = postprocessors
  }

  public func hasAction(_ action: AutomationPolicyAction) -> Bool {
    actions.contains(action)
  }

  public func hasPreprocessor(_ preprocessor: AutomationPolicyPreprocessor) -> Bool {
    preprocessors.contains(preprocessor)
  }
}

public struct AutomationPolicyDocument: Codable, Equatable, Sendable {
  public var version: Int
  public var isEnabled: Bool
  public var policies: [AutomationPolicy]
  public var updatedAt: Date

  public init(
    version: Int = 1,
    isEnabled: Bool = true,
    policies: [AutomationPolicy] = Self.defaultPolicies,
    updatedAt: Date = Date()
  ) {
    self.version = version
    self.isEnabled = isEnabled
    self.policies = Self.mergedWithDefaults(policies)
    self.updatedAt = updatedAt
  }

  public func policy(for source: AutomationPolicyEventSource) -> AutomationPolicy {
    policies(for: source).first ?? Self.defaultPolicy(for: source)
  }

  public func policy(id: String) -> AutomationPolicy? {
    Self.mergedWithDefaults(policies).first { $0.id == id }
  }

  public func policies(for source: AutomationPolicyEventSource) -> [AutomationPolicy] {
    Self.mergedWithDefaults(policies)
      .filter { $0.eventSource == source }
      .sorted { $0.priority < $1.priority }
  }

  public func replacingPolicy(_ policy: AutomationPolicy) -> Self {
    var nextPolicies = policies.filter { $0.id != policy.id }
    nextPolicies.append(policy)
    nextPolicies.sort { $0.priority < $1.priority }
    return Self(
      version: version,
      isEnabled: isEnabled,
      policies: nextPolicies,
      updatedAt: Date()
    )
  }

  public func replacingEnabled(_ isEnabled: Bool) -> Self {
    Self(
      version: version,
      isEnabled: isEnabled,
      policies: policies,
      updatedAt: Date()
    )
  }

  public func deletingPolicy(id: String) -> Self {
    guard !Self.defaultPolicyIDs.contains(id) else {
      return self
    }
    return Self(
      version: version,
      isEnabled: isEnabled,
      policies: policies.filter { $0.id != id },
      updatedAt: Date()
    )
  }

  public static var defaultPolicyIDs: Set<String> {
    Set(defaultPolicies.map(\.id))
  }

  public static let defaultPolicies: [AutomationPolicy] = [
    AutomationPolicy(
      id: "clipboard.image-ocr",
      name: "Clipboard Image OCR",
      eventSource: .clipboard,
      isEnabled: false,
      priority: 10,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [
        .respectPasteboardPrivacy,
        .skipSensitiveMarkers,
        .filterSourceApplications,
        .dedupeByFingerprint,
      ],
      actions: [.ocrImage, .rememberRecentScan, .showFeedback, .recordMetadata],
      postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    ),
    AutomationPolicy(
      id: "clipboard.metadata",
      name: "Clipboard Metadata",
      eventSource: .clipboard,
      isEnabled: false,
      priority: 12,
      match: AutomationPolicyMatch(contentKinds: [.text, .file, .url, .unknown]),
      preprocessors: [
        .respectPasteboardPrivacy,
        .skipSensitiveMarkers,
        .filterSourceApplications,
      ],
      actions: [.recordMetadata],
      postprocessors: [.auditEvent]
    ),
    userOriginatedOCRPolicy(
      id: "ocr.manual-paste",
      name: "Manual OCR Paste",
      eventSource: .manualOCRPaste,
      priority: 20,
      actions: [.ocrImage, .rememberRecentScan, .showFeedback, .recordMetadata]
    ),
    userOriginatedOCRPolicy(
      id: "ocr.drop",
      name: "Drag and Drop OCR",
      eventSource: .ocrDrop,
      priority: 30
    ),
    userOriginatedOCRPolicy(
      id: "ocr.file-picker",
      name: "File Picker OCR",
      eventSource: .ocrFilePicker,
      priority: 40
    ),
    userOriginatedOCRPolicy(
      id: "ocr.screenshot-folder",
      name: "Screenshot Folder OCR",
      eventSource: .screenshotFolder,
      priority: 50
    ),
  ]

  public static func defaultPolicy(for source: AutomationPolicyEventSource) -> AutomationPolicy {
    defaultPolicies.first { $0.eventSource == source }
      ?? userOriginatedOCRPolicy(
        id: "policy.\(source.rawValue)",
        name: source.title,
        eventSource: source,
        priority: 1_000
      )
  }

  private static func mergedWithDefaults(_ policies: [AutomationPolicy]) -> [AutomationPolicy] {
    var policiesByID = Dictionary(uniqueKeysWithValues: defaultPolicies.map { ($0.id, $0) })
    for policy in policies {
      policiesByID[policy.id] = policy
    }
    return policiesByID.values.sorted { $0.priority < $1.priority }
  }

  private static func userOriginatedOCRPolicy(
    id: String,
    name: String,
    eventSource: AutomationPolicyEventSource,
    priority: Int,
    actions: [AutomationPolicyAction] = [.ocrImage, .rememberRecentScan, .recordMetadata]
  ) -> AutomationPolicy {
    AutomationPolicy(
      id: id,
      name: name,
      eventSource: eventSource,
      isEnabled: true,
      priority: priority,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: actions,
      postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    )
  }
}
