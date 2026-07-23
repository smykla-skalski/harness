import HarnessMonitorKit
import SwiftUI

enum TaskBoardOperationsInspectorVisibility {
  static let storageKey = "taskBoard.operationsInspectorVisible"
  static let defaultValue = false
}

@MainActor
public final class TaskBoardOperationsInspectorFocusDispatcher {
  public var toggleInspector: (() -> Void)?

  public init() {}

  public func performToggleInspector() {
    toggleInspector?()
  }
}

public struct TaskBoardOperationsInspectorFocus: Equatable {
  public let isVisible: Bool
  public let canToggle: Bool
  public let dispatcher: TaskBoardOperationsInspectorFocusDispatcher

  public init(
    isVisible: Bool,
    canToggle: Bool,
    dispatcher: TaskBoardOperationsInspectorFocusDispatcher
  ) {
    self.isVisible = isVisible
    self.canToggle = canToggle
    self.dispatcher = dispatcher
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isVisible == rhs.isVisible
      && lhs.canToggle == rhs.canToggle
      && lhs.dispatcher === rhs.dispatcher
  }
}

struct TaskBoardOperationsInspector: View {
  private static let width: CGFloat = 380

  let store: HarnessMonitorStore
  let taskBoardItems: [TaskBoardItem]
  let isVisible: Bool

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.7))
        .frame(width: 1)
        .frame(maxHeight: .infinity)

      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          TaskBoardAutomationInspector(store: store, isActive: isVisible)
          TaskBoardOperationsPanel(
            store: store,
            taskBoardItems: isVisible ? taskBoardItems : [],
            isActive: isVisible
          )
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(.background)
    }
    // Preserve the inspector subtree's 380-point layout while the outer frame
    // collapses only its clipped container, keeping form state and geometry stable.
    .frame(width: Self.width)
    .frame(width: isVisible ? Self.width : 0, alignment: .leading)
    .clipped()
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .accessibilityHidden(!isVisible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.taskBoardOperationsInspector)
  }
}
