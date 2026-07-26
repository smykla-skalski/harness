import HarnessMonitorKit
import SwiftUI

enum TaskBoardOperationsInspectorVisibility {
  static let storageKey = "taskBoard.operationsInspectorVisible"
  static let defaultValue = false
}

enum TaskBoardOperationsInspectorWidth {
  static let storageKey = "taskBoard.operationsInspectorWidth"
  static let defaultValue: CGFloat = 480
  static let minimum: CGFloat = 320
  static let maximum: CGFloat = 720

  static func resolved(_ width: CGFloat) -> CGFloat {
    guard width.isFinite else { return defaultValue }
    return min(max(width, minimum), maximum)
  }

  static func resized(from width: CGFloat, translation: CGFloat) -> CGFloat {
    resolved(width - translation)
  }
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
  let store: HarnessMonitorStore
  let taskBoardItems: [TaskBoardItem]
  let isVisible: Bool
  @AppStorage(TaskBoardOperationsInspectorWidth.storageKey)
  private var storedWidth = Double(TaskBoardOperationsInspectorWidth.defaultValue)
  @GestureState private var resizeTranslation: CGFloat = 0

  private var resolvedWidth: CGFloat {
    TaskBoardOperationsInspectorWidth.resolved(CGFloat(storedWidth))
  }

  private var displayedWidth: CGFloat {
    TaskBoardOperationsInspectorWidth.resized(
      from: resolvedWidth,
      translation: resizeTranslation
    )
  }

  var body: some View {
    TaskBoardOperationsInspectorContent(
      store: store,
      taskBoardItems: isVisible ? taskBoardItems : [],
      isActive: isVisible
    )
    .frame(width: displayedWidth)
    .clipped()
    .harnessInspectorGlass(isActive: isVisible)
    .overlay(alignment: .leading) {
      if isVisible {
        resizeHandle
      }
    }
    .opacity(isVisible ? 1 : 0)
    .allowsHitTesting(isVisible)
    .accessibilityHidden(!isVisible)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.taskBoardOperationsInspector)
  }

  private var resizeHandle: some View {
    Color.clear
      .frame(width: 24)
      .contentShape(.rect)
      .gesture(resizeGesture)
      .accessibilityElement()
      .accessibilityLabel("Task Board Operations inspector width")
      .accessibilityValue("\(Int(displayedWidth)) points")
      .accessibilityHint("Drag horizontally or use adjustments to resize the inspector")
      .accessibilityAdjustableAction { direction in
        adjustWidth(for: direction)
      }
      .help("Drag to resize the inspector")
  }

  private var resizeGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($resizeTranslation) { value, translation, _ in
        translation = value.translation.width
      }
      .onEnded { value in
        storeWidth(
          TaskBoardOperationsInspectorWidth.resized(
            from: resolvedWidth,
            translation: value.translation.width
          )
        )
      }
  }

  private func adjustWidth(for direction: AccessibilityAdjustmentDirection) {
    switch direction {
    case .increment:
      storeWidth(resolvedWidth + 40)
    case .decrement:
      storeWidth(resolvedWidth - 40)
    @unknown default:
      break
    }
  }

  private func storeWidth(_ width: CGFloat) {
    storedWidth = Double(TaskBoardOperationsInspectorWidth.resolved(width))
  }
}

private struct TaskBoardOperationsInspectorContent: View {
  let store: HarnessMonitorStore
  let taskBoardItems: [TaskBoardItem]
  let isActive: Bool

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        TaskBoardAutomationInspector(store: store, isActive: isActive)
        TaskBoardTriageRulesEditor(store: store, isActive: isActive)
        TaskBoardOperationsPanel(
          store: store,
          taskBoardItems: taskBoardItems,
          isActive: isActive
        )
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
