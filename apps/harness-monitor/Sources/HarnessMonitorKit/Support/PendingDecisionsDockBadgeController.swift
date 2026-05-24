import AppKit

@MainActor
protocol DockTileBadgeWriting: AnyObject {
  var badgeLabel: String? { get set }
  func display()
}

extension NSDockTile: DockTileBadgeWriting {}

@MainActor
public final class PendingDecisionsDockBadgeController {
  private let dockTileProvider: @MainActor () -> (any DockTileBadgeWriting)?
  private var dockTile: (any DockTileBadgeWriting)?

  public init() {
    dockTileProvider = Self.defaultDockTile
  }

  init(dockTile: any DockTileBadgeWriting) {
    dockTileProvider = { dockTile }
    self.dockTile = dockTile
  }

  init(dockTileProvider: @escaping @MainActor () -> (any DockTileBadgeWriting)?) {
    self.dockTileProvider = dockTileProvider
  }

  public func sync(count: Int) {
    guard let dockTile = resolveDockTile() else {
      return
    }
    let badgeLabel = Self.badgeLabel(for: count)
    guard dockTile.badgeLabel != badgeLabel else {
      return
    }
    dockTile.badgeLabel = badgeLabel
    dockTile.display()
  }

  public static func badgeLabel(for count: Int) -> String? {
    guard count > 0 else {
      return nil
    }
    return String(count)
  }

  private func resolveDockTile() -> (any DockTileBadgeWriting)? {
    if let dockTile {
      return dockTile
    }
    let resolvedDockTile = dockTileProvider()
    dockTile = resolvedDockTile
    return resolvedDockTile
  }

  private static func defaultDockTile() -> (any DockTileBadgeWriting)? {
    NSApp?.dockTile
  }
}
