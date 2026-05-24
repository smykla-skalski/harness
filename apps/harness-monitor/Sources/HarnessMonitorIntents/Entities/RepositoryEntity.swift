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
      subtitle: LocalizedStringResource(stringLiteral: owner),
      image: Self.image(forOwner: owner)
    )
  }

  /// GitHub org/user avatars are served at the same `<login>.png` path
  /// as user avatars. Spotlight fetches lazily so the picker shows the
  /// org logo for disambiguation without any sync cost
  static func image(forOwner owner: String) -> DisplayRepresentation.Image {
    let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      let url = URL(string: "https://github.com/\(trimmed).png")
    else {
      return DisplayRepresentation.Image(systemName: "folder")
    }
    return DisplayRepresentation.Image(url: url)
  }
}
