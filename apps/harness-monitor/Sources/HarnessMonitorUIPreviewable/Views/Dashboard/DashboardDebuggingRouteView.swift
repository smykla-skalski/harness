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
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.image],
      allowsMultipleSelection: true,
      onCompletion: handleFileImport
    )
    .onAppear {
      refreshClipboardAvailability()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      refreshClipboardAvailability()
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
          DashboardOCRResultCard(item: item)
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

private struct DashboardOCRResultCard: View {
  let item: DashboardOCRImageItem

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingLG) {
      imagePreview
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        titleRow
        if let sourceDetail = item.sourceDetail {
          Text(sourceDetail)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        recognizedTextView
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.035))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.36), lineWidth: 1)
    }
  }

  private var imagePreview: some View {
    Image(nsImage: item.image)
      .resizable()
      .scaledToFit()
      .frame(width: 132, height: 96)
      .background(HarnessMonitorTheme.ink.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
          .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
      }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(item.sourceName)
        .scaledFont(.headline.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      DashboardOCRStatusBadge(status: item.status)
      Spacer()
      if !item.recognizedText.isEmpty {
        Button {
          HarnessMonitorClipboard.copy(item.recognizedText)
        } label: {
          Label("Copy", systemImage: "doc.on.clipboard")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    }
  }

  @ViewBuilder private var recognizedTextView: some View {
    switch item.status {
    case .pending, .recognizing:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
    case .recognized:
      Text(item.recognizedText)
        .scaledFont(.caption.monospaced())
        .textSelection(.enabled)
        .padding(HarnessMonitorTheme.spacingMD)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(HarnessMonitorTheme.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    case .empty:
      ContentUnavailableView("No text found", systemImage: "text.viewfinder")
        .frame(maxWidth: .infinity, minHeight: 96)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
    }
  }
}

private struct DashboardOCRStatusBadge: View {
  let status: DashboardOCRStatus

  var body: some View {
    Text(status.label)
      .scaledFont(.caption.weight(.bold))
      .foregroundStyle(tint)
      .harnessPillPadding()
      .background(tint.opacity(0.09), in: Capsule())
      .overlay {
        Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1)
      }
  }

  private var tint: Color {
    switch status {
    case .pending, .recognizing:
      HarnessMonitorTheme.secondaryInk
    case .recognized:
      HarnessMonitorTheme.success
    case .empty:
      HarnessMonitorTheme.caution
    case .failed:
      HarnessMonitorTheme.danger
    }
  }
}
