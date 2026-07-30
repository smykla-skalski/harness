import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

enum TaskBoardCardContextMenuEdge: CaseIterable, Hashable, Identifiable, Sendable {
  case top
  case bottom

  var id: Self { self }

  var title: String {
    switch self {
    case .top:
      "Move to Top"
    case .bottom:
      "Move to Bottom"
    }
  }

  func isCurrentEdge(itemID: String, orderedItemIDs: [String]) -> Bool {
    switch self {
    case .top:
      orderedItemIDs.first == itemID
    case .bottom:
      orderedItemIDs.last == itemID
    }
  }
}

struct TaskBoardCardContextMenuActions {
  let selectedIDs: Set<TaskBoardCardID>
  let orderedVisibleIDs: [TaskBoardCardID]
  let isActionInFlight: Bool
  let canOpen: (TaskBoardCardID) -> Bool
  let open: (TaskBoardCardID) -> Void
  let canOpenAgent: (TaskBoardCardID) -> Bool
  let openAgent: (TaskBoardCardID) -> Void
  let githubURL: (TaskBoardCardID) -> URL?
  let openGitHubURL: (URL) -> Void
  let canMove: ([TaskBoardCardID], TaskBoardInboxLane) -> Bool
  let move: (TaskBoardCardID, [TaskBoardCardID], TaskBoardInboxLane) -> Void
  let canMoveToEdge: (TaskBoardCardID, TaskBoardCardContextMenuEdge) -> Bool
  let moveToEdge: (TaskBoardCardID, TaskBoardCardContextMenuEdge) -> Void
  let canResetPosition: (TaskBoardCardID) -> Bool
  let resetPosition: (TaskBoardCardID) -> Void
  let deletionTargets: ([TaskBoardCardID]) -> [TaskBoardDeletionTarget]
  let canDelete: ([TaskBoardCardID]) -> Bool
  let deleteTargets: (([TaskBoardDeletionTarget]) -> Void)?
  let primeSelection: ([TaskBoardCardID]) -> Void
}

extension TaskBoardCardContextMenuActions {
  /// Environment default before `TaskBoardOverviewView` installs the real
  /// value. The native menu is only built when it opens, by which point the
  /// environment carries the real actions. This only backstops previews/tests
  /// that mount a card in isolation, so every branch is disabled/no-op.
  static var inert: TaskBoardCardContextMenuActions {
    TaskBoardCardContextMenuActions(
      selectedIDs: [],
      orderedVisibleIDs: [],
      isActionInFlight: true,
      canOpen: { _ in false },
      open: { _ in },
      canOpenAgent: { _ in false },
      openAgent: { _ in },
      githubURL: { _ in nil },
      openGitHubURL: { _ in },
      canMove: { _, _ in false },
      move: { _, _, _ in },
      canMoveToEdge: { _, _ in false },
      moveToEdge: { _, _ in },
      canResetPosition: { _ in false },
      resetPosition: { _ in },
      deletionTargets: { _ in [] },
      canDelete: { _ in false },
      deleteTargets: nil,
      primeSelection: { _ in }
    )
  }
}

extension EnvironmentValues {
  @Entry var taskBoardCardContextMenuActions: TaskBoardCardContextMenuActions = .inert
}

struct TaskBoardCardContextMenu: NSViewRepresentable {
  let cardID: TaskBoardCardID
  @Environment(\.taskBoardCardContextMenuActions)
  private var actions

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> InstallerView {
    let view = InstallerView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ view: InstallerView, context: Context) {
    context.coordinator.update(cardID: cardID, actions: actions)
    context.coordinator.install(from: view)
  }

  static func dismantleNSView(_ view: InstallerView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class InstallerView: NSView {
    weak var coordinator: Coordinator?

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      coordinator?.install(from: self)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.install(from: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSGestureRecognizerDelegate {
    private weak var installedView: NSView?
    private var installedFocusRingType: NSFocusRingType?
    private let menu = NSMenu()
    private lazy var rightClickRecognizer: NSClickGestureRecognizer = {
      let recognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(showMenu)
      )
      recognizer.buttonMask = 0x2
      recognizer.delaysSecondaryMouseButtonEvents = true
      return recognizer
    }()
    private lazy var controlClickRecognizer: NSClickGestureRecognizer = {
      let recognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(showMenu)
      )
      recognizer.buttonMask = 0x1
      recognizer.delaysPrimaryMouseButtonEvents = true
      recognizer.delegate = self
      return recognizer
    }()
    private var cardID: TaskBoardCardID?
    private var actions = TaskBoardCardContextMenuActions.inert
    private var currentScope: TaskBoardCardContextMenuScope?

    override init() {
      super.init()
      menu.autoenablesItems = false
    }

    func update(
      cardID: TaskBoardCardID,
      actions: TaskBoardCardContextMenuActions
    ) {
      self.cardID = cardID
      self.actions = actions
    }

    func install(from installer: NSView) {
      guard let cell = installer.taskBoardAncestor(of: NSTableCellView.self) else {
        return
      }
      if installedView !== cell {
        detach()
        cell.addGestureRecognizer(rightClickRecognizer)
        cell.addGestureRecognizer(controlClickRecognizer)
        installedFocusRingType = cell.focusRingType
        cell.focusRingType = .none
        installedView = cell
      } else {
        cell.focusRingType = .none
      }
    }

    func detach() {
      if rightClickRecognizer.view === installedView {
        installedView?.removeGestureRecognizer(rightClickRecognizer)
      }
      if controlClickRecognizer.view === installedView {
        installedView?.removeGestureRecognizer(controlClickRecognizer)
      }
      if let installedFocusRingType {
        installedView?.focusRingType = installedFocusRingType
      }
      installedFocusRingType = nil
      installedView = nil
    }

    static func acceptsControlClick(
      modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
      modifierFlags.contains(.control)
    }

    func gestureRecognizer(
      _ gestureRecognizer: NSGestureRecognizer,
      shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
      guard gestureRecognizer === controlClickRecognizer else { return true }
      return Self.acceptsControlClick(modifierFlags: event.modifierFlags)
    }

    @objc
    private func showMenu() {
      guard
        let cardID,
        let event = NSApp.currentEvent,
        let installedView,
        let scope = TaskBoardCardContextMenuScope.resolve(
          menuSelection: [cardID],
          selectedIDs: actions.selectedIDs,
          orderedVisibleIDs: actions.orderedVisibleIDs
        )
      else {
        return
      }
      currentScope = scope
      rebuildMenu(for: scope)
      actions.primeSelection(scope.cardIDs)
      NSMenu.popUpContextMenu(menu, with: event, for: installedView)
    }

    private func rebuildMenu(for scope: TaskBoardCardContextMenuScope) {
      menu.removeAllItems()
      if scope.isSingle {
        addItem(
          title: "Open",
          action: #selector(openCard),
          isEnabled: actions.canOpen(scope.primaryID)
        )
        if actions.canOpenAgent(scope.primaryID) {
          addItem(
            title: "Open Spawned Task",
            symbol: "arrow.up.forward.app",
            action: #selector(openAgent)
          )
        }
        if actions.githubURL(scope.primaryID) != nil {
          addItem(
            title: "Open on GitHub",
            symbol: "arrow.up.right.square",
            action: #selector(openGitHub)
          )
        }
        if actions.canResetPosition(scope.primaryID) {
          addItem(
            title: "Reset Position",
            symbol: "arrow.uturn.backward",
            action: #selector(resetPosition),
            isEnabled: !actions.isActionInFlight
          )
        }
      }
      addItem(title: scope.copyIDsLabel, action: #selector(copyTaskIDs))
      menu.addItem(.separator())
      addMoveToMenu(for: scope)
      if scope.isSingle, case .api = scope.primaryID {
        for edge in TaskBoardCardContextMenuEdge.allCases {
          let item = addItem(
            title: edge.title,
            action: #selector(moveToEdge(_:)),
            isEnabled: !actions.isActionInFlight
              && actions.canMoveToEdge(scope.primaryID, edge)
          )
          item.tag = edge == .top ? 0 : 1
        }
      }
      menu.addItem(.separator())
      let targets = actions.deletionTargets(scope.cardIDs)
      addItem(
        title: scope.deleteLabel,
        symbol: "trash",
        action: #selector(deleteTasks),
        isEnabled: !actions.isActionInFlight
          && actions.deleteTargets != nil
          && actions.canDelete(scope.cardIDs)
          && targets.count == scope.count
      )
    }

    private func addMoveToMenu(for scope: TaskBoardCardContextMenuScope) {
      let submenu = NSMenu()
      submenu.autoenablesItems = false
      for lane in TaskBoardInboxLane.allCases where lane != .umbrella {
        let item = makeItem(
          title: lane.title,
          symbol: lane.systemImage,
          action: #selector(moveToLane(_:)),
          isEnabled: actions.canMove(scope.cardIDs, lane)
        )
        item.representedObject = lane.rawValue as NSString
        submenu.addItem(item)
      }
      let parent = NSMenuItem(title: "Move to...", action: nil, keyEquivalent: "")
      parent.submenu = submenu
      parent.isEnabled = !actions.isActionInFlight
      menu.addItem(parent)
    }

    @discardableResult
    private func addItem(
      title: String,
      symbol: String? = nil,
      action: Selector,
      isEnabled: Bool = true
    ) -> NSMenuItem {
      let item = makeItem(
        title: title,
        symbol: symbol,
        action: action,
        isEnabled: isEnabled
      )
      menu.addItem(item)
      return item
    }

    private func makeItem(
      title: String,
      symbol: String?,
      action: Selector,
      isEnabled: Bool
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.isEnabled = isEnabled
      if let symbol {
        item.image = NSImage(
          systemSymbolName: symbol,
          accessibilityDescription: title
        )
      }
      return item
    }

    @objc
    private func openCard() {
      withScope { actions.open($0.primaryID) }
    }

    @objc
    private func openAgent() {
      withScope { actions.openAgent($0.primaryID) }
    }

    @objc
    private func openGitHub() {
      withScope {
        if let url = actions.githubURL($0.primaryID) {
          actions.openGitHubURL(url)
        }
      }
    }

    @objc
    private func resetPosition() {
      withScope { actions.resetPosition($0.primaryID) }
    }

    @objc
    private func copyTaskIDs() {
      withScope { HarnessMonitorClipboard.copy($0.clipboardText) }
    }

    @objc
    private func moveToLane(_ sender: NSMenuItem) {
      guard
        let rawValue = sender.representedObject as? NSString,
        let lane = TaskBoardInboxLane(rawValue: rawValue as String)
      else {
        return
      }
      withScope { actions.move($0.primaryID, $0.cardIDs, lane) }
    }

    @objc
    private func moveToEdge(_ sender: NSMenuItem) {
      let edge: TaskBoardCardContextMenuEdge = sender.tag == 0 ? .top : .bottom
      withScope { actions.moveToEdge($0.primaryID, edge) }
    }

    @objc
    private func deleteTasks() {
      withScope { scope in
        let targets = actions.deletionTargets(scope.cardIDs)
        guard targets.count == scope.count else { return }
        actions.deleteTargets?(targets)
      }
    }

    private func withScope(
      _ action: (TaskBoardCardContextMenuScope) -> Void
    ) {
      guard let currentScope else { return }
      action(currentScope)
    }
  }
}

extension NSView {
  fileprivate func taskBoardAncestor<View: NSView>(of type: View.Type) -> View? {
    var candidate: NSView? = self
    while let view = candidate {
      if let match = view as? View {
        return match
      }
      candidate = view.superview
    }
    return nil
  }
}
