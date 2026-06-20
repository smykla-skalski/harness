import AppKit
import UniformTypeIdentifiers

struct ClipboardAutomationSnapshot: Equatable {
  let reason: ClipboardAutomationEvaluationReason
  let accessBehaviorDescription: String
  let declaredTypes: [String]
  let detectedContentType: String?
  let contentKinds: Set<AutomationClipboardContentKind>
  let containsSensitiveContent: Bool
  let sourceApplication: AutomationSourceApplication?

  var summary: String {
    let kinds = contentKinds.map(\.title).sorted().joined(separator: ", ")
    let appName = sourceApplication?.displayName ?? "Unknown app"
    return "\(kinds.isEmpty ? "Unknown" : kinds) from \(appName)"
  }

  var sourceMetadata: [DashboardOCRImageSourceMetadata] {
    var metadata = [
      DashboardOCRImageSourceMetadata(
        name: "Clipboard",
        detail: "NSPasteboard.general"
      )
    ]
    if let sourceApplication {
      metadata.append(
        DashboardOCRImageSourceMetadata(
          name: sourceApplication.displayName,
          detail: sourceApplication.bundleIdentifier
        )
      )
    }
    if let detectedContentType {
      metadata.append(
        DashboardOCRImageSourceMetadata(
          name: "Detected content type",
          detail: detectedContentType
        )
      )
    }
    return metadata
  }

  static func make(
    from pasteboard: NSPasteboard,
    reason: ClipboardAutomationEvaluationReason,
    observedSourceApplication: AutomationSourceApplication? = nil
  ) async -> Self {
    let declaredTypes = (pasteboard.types ?? []).map(\.rawValue)
    let detectedContentType = await detectedContentType(from: pasteboard)
    let detectedPatterns = await detectedPatterns(from: pasteboard)
    let contentKinds = contentKinds(
      declaredTypes: declaredTypes,
      detectedContentType: detectedContentType,
      detectedPatterns: detectedPatterns
    )
    return Self(
      reason: reason,
      accessBehaviorDescription: pasteboard.accessBehavior.automationDescription,
      declaredTypes: declaredTypes,
      detectedContentType: detectedContentType,
      contentKinds: contentKinds,
      containsSensitiveContent: containsSensitiveType(declaredTypes),
      sourceApplication: observedSourceApplication
        ?? ClipboardAutomationSourceApplicationResolver.current(
          confidence: "frontmost-application-at-read"
        )
    )
  }

  private static func detectedContentType(from pasteboard: NSPasteboard) async -> String? {
    let keyPaths: Set<PartialKeyPath<NSPasteboard.DetectedMetadata>> = [\.contentType]
    guard
      let metadata = try? await pasteboard.detectedMetadata(for: keyPaths),
      let contentType = metadata.contentType
    else {
      return nil
    }
    return contentType.identifier
  }

  private static func detectedPatterns(
    from pasteboard: NSPasteboard
  ) async -> Set<PartialKeyPath<NSPasteboard.DetectedValues>> {
    let keyPaths: Set<PartialKeyPath<NSPasteboard.DetectedValues>> = [
      \.probableWebURL,
      \.probableWebSearch,
      \.number,
      \.links,
      \.emailAddresses,
    ]
    return (try? await pasteboard.detectedPatterns(for: keyPaths)) ?? []
  }

  private static func contentKinds(
    declaredTypes: [String],
    detectedContentType: String?,
    detectedPatterns: Set<PartialKeyPath<NSPasteboard.DetectedValues>>
  ) -> Set<AutomationClipboardContentKind> {
    var kinds = Set<AutomationClipboardContentKind>()
    let declaredContentTypes = declaredTypes.compactMap(UTType.init)
    if declaredContentTypes.contains(where: { $0.conforms(to: .image) })
      || detectedContentType.map({ UTType($0)?.conforms(to: .image) == true }) == true
    {
      kinds.insert(.image)
    }
    if declaredContentTypes.contains(where: { $0.conforms(to: .fileURL) })
      || detectedContentType.map({ UTType($0)?.conforms(to: .fileURL) == true }) == true
    {
      kinds.insert(.file)
    }
    if declaredContentTypes.contains(where: { $0.conforms(to: .url) }) {
      kinds.insert(.url)
    }
    if declaredContentTypes.contains(where: { $0.conforms(to: .text) })
      || !detectedPatterns.isEmpty
    {
      kinds.insert(.text)
    }
    if detectedPatterns.contains(\NSPasteboard.DetectedValues.probableWebURL)
      || detectedPatterns.contains(\NSPasteboard.DetectedValues.links)
    {
      kinds.insert(.url)
    }
    if kinds.isEmpty {
      kinds.insert(.unknown)
    }
    return kinds
  }

  private static func containsSensitiveType(_ declaredTypes: [String]) -> Bool {
    let sensitiveTypes = Set([
      "org.nspasteboard.ConcealedType",
      "org.nspasteboard.TransientType",
      "com.agilebits.onepassword",
      "com.agilebits.onepassword.concealed",
    ])
    return declaredTypes.contains { sensitiveTypes.contains($0) }
  }
}

extension NSPasteboard.AccessBehavior {
  fileprivate var automationDescription: String {
    switch self {
    case .default:
      "default"
    case .ask:
      "ask"
    case .alwaysAllow:
      "alwaysAllow"
    case .alwaysDeny:
      "alwaysDeny"
    @unknown default:
      "unknown"
    }
  }
}
