import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board operations inspector width")
struct TaskBoardOperationsInspectorWidthTests {
  @Test("Width defaults wide and clamps restored values")
  func defaultsWideAndClampsRestoredValues() {
    #expect(TaskBoardOperationsInspectorWidth.defaultValue == 480)
    #expect(TaskBoardOperationsInspectorWidth.defaultValue > 380)
    #expect(
      TaskBoardOperationsInspectorWidth.resolved(0)
        == TaskBoardOperationsInspectorWidth.minimum
    )
    #expect(
      TaskBoardOperationsInspectorWidth.resolved(10_000)
        == TaskBoardOperationsInspectorWidth.maximum
    )
    #expect(
      TaskBoardOperationsInspectorWidth.resolved(.infinity)
        == TaskBoardOperationsInspectorWidth.defaultValue
    )
  }

  @Test("Resize translation expands leftward and clamps")
  func resizeTranslationExpandsLeftwardAndClamps() {
    #expect(TaskBoardOperationsInspectorWidth.resized(from: 480, translation: -100) == 580)
    #expect(
      TaskBoardOperationsInspectorWidth.resized(from: 480, translation: 1_000)
        == TaskBoardOperationsInspectorWidth.minimum
    )
  }

  @Test("Inspector uses untinted regular glass with an accessible fallback")
  func usesUntintedRegularGlassWithAccessibleFallback() throws {
    let source = try inspectorGlassSource()

    #expect(source.contains("private struct HarnessMonitorInspectorGlassModifier"))
    #expect(source.contains(".glassEffect(.regular, in: .rect)"))
    #expect(source.contains(".fill(.background)"))
    #expect(source.contains("func harnessInspectorGlass(isActive: Bool)"))
    #expect(source.contains(".ignoresSafeArea(.container, edges: .top)"))
  }

  private func inspectorGlassSource() throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Theme/HarnessMonitorGlass.swift")
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}

func expectPersistentResizableInspectorSource(_ source: String) {
  #expect(source.contains("static let defaultValue: CGFloat = 480"))
  #expect(source.contains("@AppStorage(TaskBoardOperationsInspectorWidth.storageKey)"))
  #expect(source.contains("ScrollView(.vertical)"))
  #expect(!source.contains("topContentInset"))
  #expect(source.contains(".harnessInspectorGlass(isActive: isVisible)"))
  #expect(source.contains(".clipped()\n    .harnessInspectorGlass(isActive: isVisible)"))
  #expect(!source.contains("HarnessMonitorTheme.controlBorder.opacity(0.7)"))
  #expect(!source.contains("thinMaterial"))
  #expect(!source.contains("inspectorSurfaceFill"))
  #expect(!source.contains("Color(red:"))
  #expect(source.contains("TaskBoardOperationsPanel("))
  #expect(source.contains("taskBoardItems: isVisible ? taskBoardItems : []"))
  #expect(source.contains("isActive: isVisible"))
  #expect(source.contains("@GestureState private var resizeTranslation"))
  #expect(source.contains("DragGesture(minimumDistance: 0)"))
  #expect(source.contains(".updating($resizeTranslation)"))
  #expect(source.contains(".onEnded { value in"))
  #expect(source.contains(".accessibilityAdjustableAction"))
  #expect(!source.contains("@objc"))
  #expect(!source.contains(": NSObject"))
  #expect(!source.contains("Timer"))
  #expect(source.contains(".frame(width: isVisible ? displayedWidth : 0)"))
  #expect(!source.contains("private static let width: CGFloat = 380"))
  #expect(source.contains(".allowsHitTesting(isVisible)"))
  #expect(source.contains(".accessibilityHidden(!isVisible)"))
}
