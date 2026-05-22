import AppKit
import Foundation
import HarnessMonitorKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Cached ISO8601 formatter for the suggested export filename. Module-scope
/// allocation keeps view-body cost flat across rapid toolbar refreshes.
@MainActor private let auditExportFilenameTimestampFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter
}()

/// Toolbar button that exports the active Supervisor Audit Timeline view to a
/// JSONL file via `SupervisorAuditExporter`. The save panel runs on the main
/// actor; the actual write hops to a detached task so the menu bar does not
/// stall on large audit logs.
@MainActor
public struct AuditTimelineExportButton: View {
  private let filters: SupervisorAuditFilters
  private let modelContainer: ModelContainer?
  private let presentSavePanel: @MainActor (String) -> URL?

  @State private var isExporting = false
  @State private var lastError: String?
  @State private var showingErrorAlert = false

  public init(
    filters: SupervisorAuditFilters,
    modelContainer: ModelContainer? = nil
  ) {
    self.init(
      filters: filters,
      modelContainer: modelContainer,
      presentSavePanel: AuditTimelineExportButton.runDefaultSavePanel(suggestedFilename:)
    )
  }

  init(
    filters: SupervisorAuditFilters,
    modelContainer: ModelContainer?,
    presentSavePanel: @escaping @MainActor (String) -> URL?
  ) {
    self.filters = filters
    self.modelContainer = modelContainer
    self.presentSavePanel = presentSavePanel
  }

  public var body: some View {
    Button {
      Task { @MainActor in
        await beginExport()
      }
    } label: {
      Label("Export\u{2026}", systemImage: "square.and.arrow.up")
    }
    .disabled(isExporting)
    .help("Export the visible audit events as JSONL")
    .accessibilityIdentifier("harness.audit.export")
    .accessibilityLabel(Text("Export audit timeline"))
    .alert(
      "Audit export failed",
      isPresented: $showingErrorAlert,
      presenting: lastError
    ) { _ in
      Button("OK", role: .cancel) { showingErrorAlert = false }
    } message: { error in
      Text(error)
    }
  }

  private func beginExport() async {
    let suggestedFilename = Self.makeSuggestedFilename(at: Date())
    guard let destination = presentSavePanel(suggestedFilename) else {
      return
    }
    isExporting = true
    defer { isExporting = false }
    do {
      let trimmed = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      try await SupervisorAuditExporter.exportEvents(
        toURL: destination,
        filter: trimmed.isEmpty ? nil : trimmed,
        modelContainer: modelContainer
      )
    } catch {
      lastError = error.localizedDescription
      showingErrorAlert = true
    }
  }

  static func makeSuggestedFilename(at date: Date) -> String {
    let stamp = auditExportFilenameTimestampFormatter.string(from: date)
    let safeStamp =
      stamp
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "/", with: "-")
    return "harness-audit-\(safeStamp).jsonl"
  }

  @MainActor
  private static func runDefaultSavePanel(suggestedFilename: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export Audit Events"
    panel.prompt = "Export"
    panel.nameFieldStringValue = suggestedFilename
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    if let jsonlType = UTType(filenameExtension: "jsonl") {
      panel.allowedContentTypes = [jsonlType]
    }
    return panel.runModal() == .OK ? panel.url : nil
  }
}
