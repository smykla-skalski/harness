import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

extension DashboardPolicyCanvasRouteView {
  // MARK: - Canvas selection preview

  @MainActor
  func applyCanvasSelectionPreview(for canvas: TaskBoardPolicyCanvasSummary) {
    let preview = DashboardPolicyCanvasSelectionPreview(
      workspace: workspace,
      selectedCanvasId: canvas.canvasId
    )
    selectedCanvasPreview = preview
    guard let preview else {
      return
    }
    if preview.showsLoadingPlaceholder {
      policyCanvasViewModel = PolicyCanvasViewModel.liveStartupState(
        document: nil,
        simulation: nil,
        audit: nil,
        activeCanvasId: preview.snapshot.activeCanvasId
      )
      return
    }
    policyCanvasViewModel.applyDocument(
      document: preview.snapshot.document,
      simulation: preview.snapshot.simulation,
      audit: preview.snapshot.audit,
      activeCanvasId: preview.snapshot.activeCanvasId,
      forceDocumentReload: true
    )
  }

  @MainActor
  func clearCanvasSelectionPreview() {
    guard selectedCanvasPreview != nil else {
      return
    }
    selectedCanvasPreview = nil
  }

  var nextCanvasTitle: String {
    let nextIndex = (workspace?.canvases.count ?? 0) + 1
    return "Policy Canvas \(nextIndex)"
  }

  // MARK: - Export / Import

  @MainActor
  func requestExportCanvas() {
    Task { await performExportCanvas() }
  }

  @MainActor
  func requestImportCanvas() {
    Task { await performImportCanvas() }
  }

  @MainActor
  private func performExportCanvas() async {
    guard let canvasId = workspace?.activeCanvasId else { return }
    let rawTitle = workspace?.canvases.first(where: { $0.canvasId == canvasId })?.title
      ?? "policy-canvas"
    let filename =
      rawTitle.lowercased().replacingOccurrences(of: " ", with: "-") + ".json"
    guard let destination = Self.runExportSavePanel(suggestedFilename: filename) else { return }
    guard let response = await store.exportTaskBoardPolicyCanvas(canvasId: canvasId)
    else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(response.document) else { return }
    try? data.write(to: destination)
  }

  @MainActor
  private func performImportCanvas() async {
    guard let source = Self.runImportOpenPanel() else { return }
    guard let data = try? Data(contentsOf: source) else { return }
    let title = source.deletingPathExtension().lastPathComponent
    guard
      let document = try? JSONDecoder().decode(TaskBoardPolicyPipelineDocument.self, from: data)
    else { return }
    _ = await store.importTaskBoardPolicyCanvas(document: document, title: title)
  }

  @MainActor
  private static func runExportSavePanel(suggestedFilename: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export Policy Canvas"
    panel.prompt = "Export"
    panel.nameFieldStringValue = suggestedFilename
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.json]
    return panel.runModal() == .OK ? panel.url : nil
  }

  @MainActor
  private static func runImportOpenPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import Policy Canvas"
    panel.prompt = "Import"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.json]
    return panel.runModal() == .OK ? panel.urls.first : nil
  }
}
