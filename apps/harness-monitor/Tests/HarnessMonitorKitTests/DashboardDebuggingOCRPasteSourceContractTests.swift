import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Debugging OCR paste uses SwiftUI paste command routing")
  func debuggingOCRPasteUsesSwiftUIPasteCommandRouting() throws {
    let pasteCommandSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRPasteCommand.swift"
    )
    let routeSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingRouteView.swift"
    )
    let controlsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRControls.swift"
    )
    let recentsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRRecents.swift"
    )
    let previewSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRPreview.swift"
    )
    let postProcessingSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRPostProcessing.swift"
    )
    let screenshotsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDebuggingOCRScreenshots.swift"
    )
    let sceneContentSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+SceneContent.swift"
    )

    #expect(pasteCommandSource.contains(".pasteDestination("))
    #expect(pasteCommandSource.contains("DashboardOCRTransferImage.self"))
    #expect(pasteCommandSource.contains("NSEvent.addLocalMonitorForEvents"))
    #expect(pasteCommandSource.contains("DashboardImagePastePolicyDispatcher.requestPaste"))
    #expect(pasteCommandSource.contains("requestPasteFromClipboard("))
    #expect(!pasteCommandSource.contains("DashboardReviewsScreenshotPasteboardRequests"))
    #expect(!pasteCommandSource.contains("requestManualPasteFromClipboard()"))
    #expect(!pasteCommandSource.contains("requestManualPaste("))
    #expect(pasteCommandSource.contains("requestDashboardRoute(.debugging)"))
    #expect(!pasteCommandSource.contains("@objc"))
    #expect(!pasteCommandSource.contains("NSResponder"))
    #expect(routeSource.contains("DashboardDiagnosticsSection(title: \"OCR\")"))
    #expect(routeSource.contains("DashboardOCRSummaryText.make("))
    #expect(!routeSource.contains("Text(summaryText)"))
    #expect(!routeSource.contains("Label(\"No Images\""))
    #expect(routeSource.contains("items.insert(contentsOf: newItems, at: 0)"))
    #expect(routeSource.contains("DashboardOCRPasteFeedbackView"))
    #expect(routeSource.contains(".sensoryFeedback("))
    #expect(routeSource.contains(".impact(weight: .medium, intensity: 0.85)"))
    #expect(controlsSource.contains(".symbolEffect("))
    #expect(controlsSource.contains(".bounce.up.wholeSymbol"))
    #expect(routeSource.contains("DashboardOCRRecentImagesSection"))
    #expect(routeSource.contains("DashboardOCRSystemScreenshotsSection"))
    #expect(routeSource.contains("allowedContentTypes: [.folder]"))
    #expect(routeSource.contains("recentStore.record(newItems + updatedExistingItems)"))
    #expect(routeSource.contains("mergeSourceMetadata(from: candidate)"))
    #expect(routeSource.contains("recentStore.record([updatedItem])"))
    #expect(postProcessingSource.contains("DashboardOCRTextSourceProfile"))
    #expect(postProcessingSource.contains("case slack"))
    #expect(postProcessingSource.contains("normalizeURLs"))
    #expect(screenshotsSource.contains("DispatchSource.makeFileSystemObjectSource"))
    #expect(screenshotsSource.contains("beginSecurityScope()"))
    #expect(screenshotsSource.contains("HARNESS_MONITOR_DEBUGGING_OCR_SCREENSHOT_FOLDER"))
    #expect(screenshotsSource.contains("contentType.conforms(to: .image)"))
    #expect(controlsSource.contains("Button(action: onChooseImages)"))
    #expect(controlsSource.contains("DashboardOCRDropZoneButtonStyle"))
    #expect(controlsSource.contains(".pointerStyle(.link)"))
    #expect(!controlsSource.contains("NSCursor"))
    #expect(recentsSource.contains("ScrollView(.horizontal, showsIndicators: false)"))
    #expect(recentsSource.contains(".aspectRatio(contentMode: .fill)"))
    #expect(routeSource.contains("sourceMetadata: item.sourceMetadata"))
    #expect(recentsSource.contains("recognizedText: item.recognizedText"))
    #expect(previewSource.contains("NSScreen.main?.visibleFrame.size"))
    #expect(previewSource.contains("idealWindowSize(fitting visibleSize"))
    #expect(previewSource.contains("func displaySize(fitting availableSize"))
    #expect(previewSource.contains("init(recentImage: DashboardOCRRecentImage)"))
    #expect(previewSource.contains("Text(\"Scanned Text\")"))
    #expect(previewSource.contains("recognizedTextBodyMaximumHeight"))
    #expect(previewSource.contains(".frame(height: bodyHeight)"))
    #expect(previewSource.contains("dashboardDebuggingOCRPreviewText"))
    #expect(sceneContentSource.contains(".dashboardDebuggingOCRPasteCommand()"))
  }
}
