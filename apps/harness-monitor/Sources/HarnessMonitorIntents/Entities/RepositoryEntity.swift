import AppIntents
import Foundation
import HarnessMonitorKit

public struct RepositoryEntity: AppEntity, Identifiable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Repository", numericFormat: "\(placeholder: .int) repositories")
  }

  public static var defaultQuery: RepositoryQuery { RepositoryQuery() }

  public let id: String
  public let owner: String
  public let name: String

  public init(id: String, owner: String, name: String) {
    self.id = id
    self.owner = owner
    self.name = name
  }

  public init?(rawIdentifier: String) {
    let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let owner = String(parts[0])
    let name = String(parts[1])
    guard !owner.isEmpty, !name.isEmpty else { return nil }
    self.init(id: "\(owner)/\(name)", owner: owner, name: name)
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: id),
      subtitle: LocalizedStringResource(stringLiteral: owner)
    )
  }
}
