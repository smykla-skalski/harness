import AppKit
import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DashboardDebuggingRouteView: View {
  @State private var items: [DashboardOCRImageItem] = []
  @State private var isImporterPresented = false
  @State private var isScreenshotFolderImporterPresented = false
  @State private var isDropTargeted = false
  @State private var hasClipboardImages = false
  @State private var intakeMessage: DashboardOCRIntakeMessage?
  @State private var handledPasteboardRequestID = 0
  @State private var previewItem: DashboardOCRImagePreviewItem?
  @State private var pasteFeedback: DashboardOCRPasteFeedback?
  @State private var highlightedItemIDs: Set<UUID> = []
  @State private var recentImages: [DashboardOCRRecentImage] = []
  @State private var screenshotFolderState: DashboardOCRSystemScreenshotFolderState = .inactive
  @State private var screenshotFolderWatcher = DashboardOCRSystemScreenshotFolderWatcher()
  @State private var policyCenter = AutomationPolicyCenter.shared
  @Environment(\.openDashboardRoute)
  private var openDashboardRoute
  private let recentStore: DashboardOCRRecentImageStore
  private let screenshotFolderStore: DashboardOCRSystemScreenshotFolderStore

  init(
    recentStore: DashboardOCRRecentImageStore = .shared,
    screenshotFolderStore: DashboardOCRSystemScreenshotFolderStore = .shared
  ) {
    self.recentStore = recentStore
    self.screenshotFolderStore = screenshotFolderStore
  }

  var body: some View {
    _ = HarnessMonitorPerfTrace.countBodyEval("DashboardDebuggingRouteView")
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
    .fileImporter(
      isPresented: $isScreenshotFolderImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false,
      onCompletion: handleScreenshotFolderImport
    )
    .onAppear {
      refreshClipboardAvailability()
      refreshRecentImages()
      restoreScreenshotFolderWatcherIfNeeded()
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

  private func handleFileImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      appendCandidates(DashboardOCRInputReader.candidates(fromFileURLs: urls), source: .file)
    case .failure(let error):
      intakeMessage = .failure(error.localizedDescription)
    }
    refreshClipboardAvailability()
  }

  private func handleScreenshotFolderImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        screenshotFolderState = .failed("No screenshot folder selected")
        return
      }
      do {
        let selection = try screenshotFolderStore.save(folderURL: url)
        startScreenshotFolderWatcher(selection)
      } catch {
        screenshotFolderState = .failed(error.localizedDescription)
      }
    case .failure(let error):
      screenshotFolderState = .failed(error.localizedDescription)
    }
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    Task {
      let candidates = await DashboardOCRInputReader.candidates(from: providers)
      appendCandidates(candidates, source: .drop)
    }
    return true
  }

  private func appendClipboardImages() {
    appendCandidates(DashboardOCRInputReader.candidatesFromClipboard(), source: .paste)
    refreshClipboardAvailability()
  }

  private func restoreScreenshotFolderWatcherIfNeeded() {
    guard !screenshotFolderWatcher.isWatching else {
      return
    }
    if let testFolderPath = ProcessInfo.processInfo.environment[
      DashboardOCRSystemScreenshotFolderEnvironment.folderPathKey
    ], !testFolderPath.isEmpty {
      let selection = screenshotFolderStore.selection(
        forFolderURL: URL(fileURLWithPath: testFolderPath, isDirectory: true)
      )
      startScreenshotFolderWatcher(selection)
      return
    }
    if let selection = screenshotFolderStore.load() {
      startScreenshotFolderWatcher(selection)
    }
  }

  private func startScreenshotFolderWatcher(
    _ selection: DashboardOCRSystemScreenshotFolderSelection
  ) {
    let result = screenshotFolderWatcher.start(folderURL: selection.url) { candidates in
      appendCandidates(candidates, source: .screenshot)
    }
    if let message = result {
      screenshotFolderState = .failed(message)
    } else {
      screenshotFolderState = .watching(selection)
    }
  }

  private func stopScreenshotFolderWatcher() {
    screenshotFolderWatcher.stop()
    screenshotFolderStore.clear()
    screenshotFolderState = .inactive
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
    appendCandidates(
      request.candidates,
      source: request.source,
      policyDecision: request.policyDecision
    )
    refreshClipboardAvailability()
  }

  private func appendCandidates(
    _ candidates: [DashboardOCRImageCandidate],
    source: DashboardOCRIntakeSource,
    policyDecision: AutomationPolicyDecision? = nil
  ) {
    let policyDecision = DashboardOCRPolicyDecisionResolver.decision(
      for: source, policyCenter: policyCenter, providedDecision: policyDecision)
    let intake = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: source,
      decision: policyDecision,
      candidates: candidates
    )
    intake.recordEvent(in: policyCenter)
    guard intake.shouldProcessImages else {
      intakeMessage = .failure(intake.failureMessage)
      return
    }
    var newItems: [DashboardOCRImageItem] = []
    var updatedExistingItems: [DashboardOCRImageItem] = []
    for candidate in intake.candidates {
      if let existingIndex = items.firstIndex(where: { $0.fingerprint == candidate.fingerprint }) {
        items[existingIndex].mergeSourceMetadata(from: candidate)
        updatedExistingItems.append(items[existingIndex])
        continue
      }
      newItems.append(DashboardOCRImageItem(candidate: candidate))
    }
    let recognitionPolicy = DashboardOCRRecognitionPolicy(source: source, decision: policyDecision)
    guard !newItems.isEmpty else {
      if recognitionPolicy.shouldPersistRecentScan {
        recentImages = recentStore.record(updatedExistingItems)
      }
      return
    }
    items.insert(contentsOf: newItems, at: 0)
    intakeMessage = .success(
      "Added \(newItems.count) \(newItems.count == 1 ? "image" : "images")"
    )
    if policyDecision.shouldShowFeedback {
      DashboardOCRPasteFeedbackController.show(
        for: newItems,
        pasteFeedback: $pasteFeedback,
        highlightedItemIDs: $highlightedItemIDs
      )
    }
    if recognitionPolicy.shouldPersistRecentScan {
      recentImages = recentStore.record(newItems + updatedExistingItems)
    }
    for item in newItems {
      Task {
        await recognize(itemID: item.id, image: item.image, policy: recognitionPolicy)
      }
    }
  }

  private func recognize(
    itemID: UUID,
    image: NSImage,
    policy: DashboardOCRRecognitionPolicy
  ) async {
    updateItem(itemID) { item in
      item.status = .recognizing
    }
    let result = await DashboardOCRRecognizer.recognizeText(in: image)
    let updatedItem = updateItem(itemID) { item in
      if let errorMessage = result.errorMessage {
        item.status = .failed(errorMessage)
        item.recognizedText = ""
        return
      }
      let text = policy.displayText(from: result.text, sourceMetadata: item.sourceMetadata)
      item.recognizedText = text
      item.status = text.isEmpty ? .empty : .recognized
    }
    guard let updatedItem else { return }
    var didPersistRecentScan = false
    if policy.shouldPersistRecentScan {
      recentImages = recentStore.record([updatedItem])
      didPersistRecentScan = true
    }
    if let event = policy.eventRecord(
      for: updatedItem,
      result: result,
      didPersistRecentScan: didPersistRecentScan
    ) {
      policyCenter.recordAutomationEvent(event)
    }
  }

  @discardableResult
  private func updateItem(
    _ itemID: UUID,
    update: (inout DashboardOCRImageItem) -> Void
  ) -> DashboardOCRImageItem? {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else {
      return nil
    }
    update(&items[index])
    return items[index]
  }

  private func refreshClipboardAvailability() {
    hasClipboardImages = DashboardOCRInputReader.clipboardContainsImages()
  }

  private func refreshRecentImages() {
    recentImages = recentStore.load()
  }

  private func clearRecentImages() {
    recentImages = recentStore.clear()
  }

}

extension DashboardDebuggingRouteView {
  fileprivate var ocrSection: some View {
    DashboardDiagnosticsSection(title: "OCR") {
      Text(
        DashboardOCRSummaryText.make(
          items: items,
          policyState: policyCenter.clipboardRuntimeState
        )
      )
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .monospacedDigit()
    } content: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        Button {
          openDashboardRoute(.policyCanvas)
        } label: {
          Label(
            "Configure OCR policy in Policies",
            systemImage: DashboardWindowRoute.policyCanvas.systemImage)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)

        actionRow
        DashboardOCRSystemScreenshotsSection(
          state: screenshotFolderState,
          onChooseFolder: { isScreenshotFolderImporterPresented = true },
          onStopWatching: stopScreenshotFolderWatcher
        )
        DashboardOCRDropZone(isTargeted: isDropTargeted) {
          isImporterPresented = true
        }
        .onDrop(
          of: [UTType.image.identifier, UTType.fileURL.identifier],
          isTargeted: $isDropTargeted,
          perform: handleDrop
        )
        if !recentImages.isEmpty {
          DashboardOCRRecentImagesSection(
            images: recentImages,
            onSelect: { image in
              previewItem = DashboardOCRImagePreviewItem(recentImage: image)
            },
            onClear: clearRecentImages
          )
        }
        if let intakeMessage {
          DashboardOCRIntakeMessageView(message: intakeMessage)
        }
        resultList
      }
    }
    .overlay(alignment: .topTrailing) {
      if let pasteFeedback {
        DashboardOCRPasteFeedbackView(feedback: pasteFeedback)
          .padding(.top, HarnessMonitorTheme.spacingSM)
          .padding(.trailing, HarnessMonitorTheme.spacingMD)
          .transition(
            .scale(scale: 1.10, anchor: .topTrailing)
              .combined(with: .opacity)
          )
          .allowsHitTesting(false)
      }
    }
    .animation(.bouncy(duration: 0.32, extraBounce: 0.18), value: pasteFeedback?.id)
    .sensoryFeedback(
      .impact(weight: .medium, intensity: 0.85),
      trigger: pasteFeedback?.id
    ) { _, newValue in
      newValue != nil
    }
  }

  // actionRow and resultList read/write the view's @State, so they stay in the
  // same file as that state (SwiftLint's private_swiftui_state keeps @State
  // private, unreachable from a cross-file extension).
  var actionRow: some View {
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
        pasteFeedback = nil
        highlightedItemIDs = []
      } label: {
        Label("Clear", systemImage: "trash")
      }
      .disabled(items.isEmpty)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRClearButton)
    }
  }

  var resultList: some View {
    DashboardDebuggingResultList(
      items: items,
      highlightedItemIDs: highlightedItemIDs,
      onPreview: { previewItem = DashboardOCRImagePreviewItem(item: $0) }
    )
  }
}
