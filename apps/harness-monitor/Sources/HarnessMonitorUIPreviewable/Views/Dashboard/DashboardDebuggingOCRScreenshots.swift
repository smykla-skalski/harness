import Foundation
import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

enum DashboardOCRSystemScreenshotFolderEnvironment {
  static let folderPathKey = "HARNESS_MONITOR_DEBUGGING_OCR_SCREENSHOT_FOLDER"
}

struct DashboardOCRSystemScreenshotFolderSelection: Equatable {
  let url: URL
  let displayName: String
  let path: String

  init(url: URL) {
    self.url = url
    displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    path = url.path
  }
}

@MainActor
final class DashboardOCRSystemScreenshotFolderStore {
  static let shared = DashboardOCRSystemScreenshotFolderStore()

  private let fileURL: URL
  private let fileManager: FileManager

  init(
    fileURL: URL = HarnessMonitorPaths.generatedCacheRoot()
      .appendingPathComponent("debugging-ocr-screenshot-folder.json"),
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  func load() -> DashboardOCRSystemScreenshotFolderSelection? {
    guard
      let data = try? Data(contentsOf: fileURL),
      let record = try? JSONDecoder().decode(ScreenshotFolderBookmarkRecord.self, from: data)
    else {
      return nil
    }
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: record.bookmarkData,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else {
      clear()
      return nil
    }
    if isStale {
      _ = try? save(folderURL: url)
    }
    return DashboardOCRSystemScreenshotFolderSelection(url: url)
  }

  func save(folderURL: URL) throws -> DashboardOCRSystemScreenshotFolderSelection {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let bookmarkData = try folderURL.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let record = ScreenshotFolderBookmarkRecord(
      bookmarkData: bookmarkData,
      displayName: folderURL.lastPathComponent,
      path: folderURL.path
    )
    let data = try JSONEncoder().encode(record)
    try data.write(to: fileURL, options: .atomic)
    return DashboardOCRSystemScreenshotFolderSelection(url: folderURL)
  }

  func clear() {
    try? fileManager.removeItem(at: fileURL)
  }

  func selection(forFolderURL folderURL: URL) -> DashboardOCRSystemScreenshotFolderSelection {
    DashboardOCRSystemScreenshotFolderSelection(url: folderURL)
  }
}

private struct ScreenshotFolderBookmarkRecord: Codable {
  let bookmarkData: Data
  let displayName: String
  let path: String
}

@MainActor
final class DashboardOCRSystemScreenshotFolderWatcher {
  private var source: DispatchSourceFileSystemObject?
  private var scopedAccess: SecurityScopedURLAccess?
  private var folderURL: URL?
  private var knownImagePaths: Set<String> = []
  private var pendingScanTask: Task<Void, Never>?
  private var onCandidates: (@MainActor ([DashboardOCRImageCandidate]) -> Void)?

  var isWatching: Bool {
    source != nil
  }

  func start(
    folderURL: URL,
    onCandidates: @escaping @MainActor ([DashboardOCRImageCandidate]) -> Void
  ) -> String? {
    stop()
    let access = folderURL.beginSecurityScope()
    let scopedFolderURL = access.url
    guard directoryExists(at: scopedFolderURL) else {
      access.invalidate()
      return "Folder is not available"
    }

    let descriptor = open(scopedFolderURL.path, O_EVTONLY)
    guard descriptor >= 0 else {
      access.invalidate()
      return "Folder cannot be watched"
    }

    knownImagePaths = Set(Self.imageURLs(in: scopedFolderURL).map { Self.stablePath(for: $0) })
    self.folderURL = scopedFolderURL
    self.scopedAccess = access
    self.onCandidates = onCandidates

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .attrib, .extend],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      Task { @MainActor in
        self?.scheduleScan()
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    self.source = source
    source.resume()
    return nil
  }

  func stop() {
    pendingScanTask?.cancel()
    pendingScanTask = nil
    source?.cancel()
    source = nil
    scopedAccess?.invalidate()
    scopedAccess = nil
    folderURL = nil
    knownImagePaths = []
    onCandidates = nil
  }

  private func scheduleScan() {
    pendingScanTask?.cancel()
    pendingScanTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(550))
      guard !Task.isCancelled else { return }
      scanForNewImages()
    }
  }

  private func scanForNewImages() {
    guard let folderURL else { return }
    let urls = Self.imageURLs(in: folderURL)
      .filter { !knownImagePaths.contains(Self.stablePath(for: $0)) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !urls.isEmpty else { return }
    for url in urls {
      knownImagePaths.insert(Self.stablePath(for: url))
    }
    let candidates = DashboardOCRInputReader.candidates(fromFileURLs: Self.newestFirst(urls))
    if !candidates.isEmpty {
      onCandidates?(candidates)
    }
  }

  private func directoryExists(at url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func imageURLs(in folderURL: URL) -> [URL] {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return urls.filter(isSupportedImageFile)
  }

  private static func isSupportedImageFile(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let contentType = values.contentType
    else {
      return false
    }
    return contentType.conforms(to: .image)
  }

  private static func stablePath(for url: URL) -> String {
    url.standardizedFileURL.path
  }

  static func newestFirst(_ urls: [URL]) -> [URL] {
    urls.sorted { lhs, rhs in
      modificationDate(for: lhs) > modificationDate(for: rhs)
    }
  }

  private static func modificationDate(for url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }
}

enum DashboardOCRSystemScreenshotFolderState: Equatable {
  case inactive
  case watching(DashboardOCRSystemScreenshotFolderSelection)
  case failed(String)

  var selection: DashboardOCRSystemScreenshotFolderSelection? {
    switch self {
    case .watching(let selection):
      selection
    case .inactive, .failed:
      nil
    }
  }
}

struct DashboardOCRSystemScreenshotsSection: View {
  let state: DashboardOCRSystemScreenshotFolderState
  let onChooseFolder: () -> Void
  let onStopWatching: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "camera.viewfinder")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text("System Screenshots")
          .scaledFont(.subheadline.weight(.semibold))
        Text(statusText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardDebuggingOCRShotStatus
          )
      }
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      Button {
        onChooseFolder()
      } label: {
        Label(buttonTitle, systemImage: "folder")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.dashboardDebuggingOCRShotChooseButton
      )
      if state.selection != nil {
        Button {
          onStopWatching()
        } label: {
          Label("Stop", systemImage: "stop.circle")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.dashboardDebuggingOCRShotStopButton
        )
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(HarnessMonitorTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(tint.opacity(0.28), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRShotWatcher)
  }

  private var buttonTitle: String {
    state.selection == nil ? "Watch Folder..." : "Change..."
  }

  private var statusText: String {
    switch state {
    case .inactive:
      "Choose the folder where macOS saves Cmd-Shift screenshots"
    case .watching(let selection):
      "Watching \(selection.path)"
    case .failed(let message):
      message
    }
  }

  private var tint: Color {
    switch state {
    case .inactive:
      HarnessMonitorTheme.secondaryInk
    case .watching:
      HarnessMonitorTheme.success
    case .failed:
      HarnessMonitorTheme.danger
    }
  }
}
