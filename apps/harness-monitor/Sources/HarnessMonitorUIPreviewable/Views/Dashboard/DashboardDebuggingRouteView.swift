import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DashboardDebuggingRouteView: View {
  @State private var items: [DashboardOCRImageItem] = []
  @State private var isImporterPresented = false
  @State private var isDropTargeted = false
  @State private var hasClipboardImages = false
  @State private var intakeMessage: DashboardOCRIntakeMessage?
  @State private var handledPasteboardRequestID = 0
  @State private var previewItem: DashboardOCRImagePreviewItem?

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDebuggingRoot,
      scrollSurfaceLabel: "Debugging"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        header
        ocrSection
      }
      .frame(maxWidth: 1_020, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingRoot)
    .sheet(item: $previewItem) { item in
      DashboardOCRImagePreviewSheet(item: item)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.image],
      allowsMultipleSelection: true,
      onCompletion: handleFileImport
    )
    .onAppear {
      refreshClipboardAvailability()
      consumePendingPasteboardRequest()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      refreshClipboardAvailability()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: DashboardDebuggingOCRPasteboardRequests.changedNotification
      )
    ) { _ in
      consumePendingPasteboardRequest()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
        Label("Debugging", systemImage: DashboardWindowRoute.debugging.systemImage)
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        Spacer()
        Text(summaryText)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .monospacedDigit()
      }
      Text("Scratch space for local Monitor experiments")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var ocrSection: some View {
    DashboardDiagnosticsSection(title: "OCR") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        actionRow
        DashboardOCRDropZone(isTargeted: isDropTargeted)
          .onDrop(
            of: [UTType.image.identifier, UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: handleDrop
          )
        if let intakeMessage {
          DashboardOCRIntakeMessageView(message: intakeMessage)
        }
        resultList
      }
    }
  }

  private var actionRow: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      Button {
        isImporterPresented = true
      } label: {
        Label("Choose Images...", systemImage: "photo.on.rectangle.angled")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRChooseButton)

      Button {
        appendClipboardImages()
      } label: {
        Label("Use Clipboard", systemImage: "clipboard")
      }
      .disabled(!hasClipboardImages)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRClipboardButton)

      Button {
        items.removeAll()
        intakeMessage = nil
      } label: {
        Label("Clear", systemImage: "trash")
      }
      .disabled(items.isEmpty)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRClearButton)
    }
  }

  @ViewBuilder private var resultList: some View {
    if items.isEmpty {
      ContentUnavailableView {
        Label("No Images", systemImage: "photo")
      } description: {
        Text("Drop images, choose files, or use an image from the clipboard")
      }
      .frame(maxWidth: .infinity, minHeight: 260)
    } else {
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(items) { item in
          DashboardOCRResultCard(item: item) {
            previewItem = DashboardOCRImagePreviewItem(item: item)
          }
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRResultList)
    }
  }

  private var summaryText: String {
    guard !items.isEmpty else {
      return "0 images"
    }
    let completed = items.count { item in
      switch item.status {
      case .recognized, .empty, .failed:
        true
      case .pending, .recognizing:
        false
      }
    }
    return "\(completed) of \(items.count) scanned"
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      appendCandidates(DashboardOCRInputReader.candidates(fromFileURLs: urls))
    case .failure(let error):
      intakeMessage = .failure(error.localizedDescription)
    }
    refreshClipboardAvailability()
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    Task {
      let candidates = await DashboardOCRInputReader.candidates(from: providers)
      appendCandidates(candidates)
    }
    return true
  }

  private func appendClipboardImages() {
    appendCandidates(DashboardOCRInputReader.candidatesFromClipboard())
    refreshClipboardAvailability()
  }

  private func consumePendingPasteboardRequest() {
    guard
      let request = DashboardDebuggingOCRPasteboardRequests.takePendingRequest(
        after: handledPasteboardRequestID
      )
    else {
      return
    }
    handledPasteboardRequestID = request.id
    appendCandidates(request.candidates)
    refreshClipboardAvailability()
  }

  private func appendCandidates(_ candidates: [DashboardOCRImageCandidate]) {
    guard !candidates.isEmpty else {
      intakeMessage = .failure("No readable images found")
      return
    }
    let newItems = candidates.map(DashboardOCRImageItem.init(candidate:))
    items.append(contentsOf: newItems)
    intakeMessage = .success(
      "Added \(newItems.count) \(newItems.count == 1 ? "image" : "images")"
    )
    for item in newItems {
      Task {
        await recognize(itemID: item.id, image: item.image)
      }
    }
  }

  private func recognize(itemID: UUID, image: NSImage) async {
    updateItem(itemID) { item in
      item.status = .recognizing
    }
    let result = await DashboardOCRRecognizer.recognizeText(in: image)
    updateItem(itemID) { item in
      if let errorMessage = result.errorMessage {
        item.status = .failed(errorMessage)
        return
      }
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      item.recognizedText = text
      item.status = text.isEmpty ? .empty : .recognized
    }
  }

  private func updateItem(_ itemID: UUID, update: (inout DashboardOCRImageItem) -> Void) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else {
      return
    }
    update(&items[index])
  }

  private func refreshClipboardAvailability() {
    hasClipboardImages = DashboardOCRInputReader.clipboardContainsImages()
  }
}

enum DashboardOCRIntakeMessage: Equatable {
  case success(String)
  case failure(String)

  var text: String {
    switch self {
    case .success(let text), .failure(let text):
      text
    }
  }

  var tint: Color {
    switch self {
    case .success:
      HarnessMonitorTheme.success
    case .failure:
      HarnessMonitorTheme.danger
    }
  }

  var systemImage: String {
    switch self {
    case .success:
      "checkmark.circle"
    case .failure:
      "exclamationmark.triangle"
    }
  }
}

private struct DashboardOCRIntakeMessageView: View {
  let message: DashboardOCRIntakeMessage

  var body: some View {
    Label(message.text, systemImage: message.systemImage)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(message.tint)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background(message.tint.opacity(0.08), in: Capsule())
  }
}

private struct DashboardOCRDropZone: View {
  let isTargeted: Bool

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "photo.stack")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(isTargeted ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
      Text(isTargeted ? "Release Images" : "Drop Images")
        .scaledFont(.headline.weight(.semibold))
      Text("PNG, JPEG, TIFF, HEIC")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, minHeight: 190)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(isTargeted ? 0.07 : 0.03))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(
          isTargeted ? HarnessMonitorTheme.accent : HarnessMonitorTheme.controlBorder,
          style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
        )
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRDropZone)
  }
}
