import Foundation
import SwiftUI

enum PolicyCanvasDisplayMode: String, CaseIterable, Identifiable {
  case canvas
  case json

  var id: String { rawValue }

  var label: String {
    switch self {
    case .canvas:
      "Canvas"
    case .json:
      "JSON"
    }
  }
}

private let policyCanvasJSONDocumentEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return encoder
}()

struct PolicyCanvasJSONDocumentView: View {
  let viewModel: PolicyCanvasViewModel

  @State private var jsonText = "{}"

  var body: some View {
    ScrollView([.vertical, .horizontal]) {
      Text(verbatim: jsonText)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(PolicyCanvasVisualStyle.canvasBackground)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasJSONView)
    .task {
      refreshPresentation()
    }
    .onChange(of: viewModel.nodes) { _, _ in
      refreshPresentation()
    }
    .onChange(of: viewModel.groups) { _, _ in
      refreshPresentation()
    }
    .onChange(of: viewModel.edges) { _, _ in
      refreshPresentation()
    }
    .onChange(of: viewModel.zoom) { _, _ in
      refreshPresentation()
    }
    .onChange(of: viewModel.backingDocument?.revision) { _, _ in
      refreshPresentation()
    }
  }

  @MainActor
  private func refreshPresentation() {
    let document = viewModel.documentExportPayload().exportDocument()
    guard
      let data = try? policyCanvasJSONDocumentEncoder.encode(document),
      let rawJSON = String(data: data, encoding: .utf8)
    else {
      jsonText = "{}"
      return
    }
    jsonText = rawJSON
  }
}
