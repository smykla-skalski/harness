import AppKit
import HarnessMonitorKit
import UniformTypeIdentifiers
import Vision

struct DashboardOCRPasteboardRequest {
  let id: Int
  let candidates: [DashboardOCRImageCandidate]
}

@MainActor
public enum DashboardDebuggingOCRPasteboardRequests {
  public static let changedNotification = Notification.Name(
    "DashboardDebuggingOCRPasteboardRequests.changed"
  )

  private static var nextRequestID = 0
  private static var pendingRequest: DashboardOCRPasteboardRequest?

  public static func pasteboardContainsImages() -> Bool {
    DashboardOCRInputReader.clipboardContainsImages()
  }

  @discardableResult
  public static func requestPasteFromClipboard() -> Bool {
    requestPaste(fromPasteboard: .general)
  }

  @discardableResult
  public static func requestPaste(from providers: [NSItemProvider]) async -> Bool {
    let candidates = await DashboardOCRInputReader.candidates(from: providers)
    return enqueue(candidates)
  }

  @discardableResult
  static func requestPaste(from transferImages: [DashboardOCRTransferImage]) -> Bool {
    let candidates = transferImages.compactMap(\.candidate)
    return enqueue(candidates)
  }

  @discardableResult
  static func requestPaste(fromPasteboard pasteboard: NSPasteboard) -> Bool {
    let candidates = DashboardOCRInputReader.candidates(fromPasteboard: pasteboard)
    return enqueue(candidates)
  }

  private static func enqueue(_ candidates: [DashboardOCRImageCandidate]) -> Bool {
    let candidatesToQueue = DashboardOCRImageCandidate.mergedByFingerprint(candidates)
    guard !candidatesToQueue.isEmpty else {
      return false
    }
    if let pendingRequest {
      self.pendingRequest = DashboardOCRPasteboardRequest(
        id: pendingRequest.id,
        candidates: DashboardOCRImageCandidate.mergedByFingerprint(
          pendingRequest.candidates + candidatesToQueue
        )
      )
      NotificationCenter.default.post(name: changedNotification, object: nil)
      return true
    }
    nextRequestID += 1
    pendingRequest = DashboardOCRPasteboardRequest(
      id: nextRequestID,
      candidates: candidatesToQueue
    )
    NotificationCenter.default.post(name: changedNotification, object: nil)
    return true
  }

  static func takePendingRequest(after handledRequestID: Int) -> DashboardOCRPasteboardRequest? {
    guard let request = pendingRequest, request.id > handledRequestID else {
      return nil
    }
    pendingRequest = nil
    return request
  }

  static func resetForTesting() {
    nextRequestID = 0
    pendingRequest = nil
  }
}

enum DashboardOCRStatus: Equatable {
  case pending
  case recognizing
  case recognized
  case empty
  case failed(String)

  var label: String {
    switch self {
    case .pending:
      "Queued"
    case .recognizing:
      "Scanning"
    case .recognized:
      "Text found"
    case .empty:
      "No text"
    case .failed:
      "Failed"
    }
  }
}

struct DashboardOCRImageItem: Identifiable {
  let id: UUID
  let image: NSImage
  let sourceName: String
  let sourceDetail: String?
  let fingerprint: String
  var sourceMetadata: [DashboardOCRImageSourceMetadata]
  var status: DashboardOCRStatus
  var recognizedText: String

  init(candidate: DashboardOCRImageCandidate) {
    id = UUID()
    image = candidate.image
    sourceName = candidate.sourceName
    sourceDetail = candidate.sourceDetail
    fingerprint = candidate.fingerprint
    sourceMetadata = candidate.sourceMetadata
    status = .pending
    recognizedText = ""
  }

  mutating func mergeSourceMetadata(from candidate: DashboardOCRImageCandidate) {
    sourceMetadata =
      DashboardOCRImageCandidate
      .mergedByFingerprint([
        DashboardOCRImageCandidate(
          image: image,
          sourceName: sourceName,
          sourceDetail: sourceDetail,
          fingerprint: fingerprint,
          sourceMetadata: sourceMetadata
        ),
        candidate,
      ])
      .first?
      .sourceMetadata ?? sourceMetadata
  }
}

struct DashboardOCRRecognitionResult: Equatable {
  let text: String
  let errorMessage: String?

  static func success(_ text: String) -> Self {
    Self(text: text, errorMessage: nil)
  }

  static func failure(_ message: String) -> Self {
    Self(text: "", errorMessage: message)
  }
}

@MainActor
enum DashboardOCRInputReader {
  nonisolated static func providerCanProvideImage(_ provider: NSItemProvider) -> Bool {
    if provider.canLoadObject(ofClass: NSImage.self) {
      return true
    }
    return provider.registeredTypeIdentifiers.contains { identifier in
      guard let contentType = UTType(identifier) else {
        return false
      }
      return contentType.conforms(to: .image) || contentType.conforms(to: .fileURL)
    }
  }

  static func candidates(fromFileURLs urls: [URL]) -> [DashboardOCRImageCandidate] {
    urls.compactMap { candidate(fromFileURL: $0) }
  }

  static func clipboardContainsImages() -> Bool {
    clipboardContainsImages(on: .general)
  }

  static func clipboardContainsImages(on pasteboard: NSPasteboard) -> Bool {
    if NSImage(pasteboard: pasteboard) != nil {
      return true
    }
    return fileURLs(from: pasteboard).contains { isImageURL($0) }
  }

  static func candidatesFromClipboard() -> [DashboardOCRImageCandidate] {
    candidates(fromPasteboard: .general)
  }

  static func candidates(fromPasteboard pasteboard: NSPasteboard) -> [DashboardOCRImageCandidate] {
    guard let items = pasteboard.pasteboardItems else {
      return []
    }
    return items.compactMap(candidate(fromPasteboardItem:))
  }

  static func candidates(from providers: [NSItemProvider]) async -> [DashboardOCRImageCandidate] {
    var candidates: [DashboardOCRImageCandidate] = []
    for provider in providers {
      if let candidate = await candidate(from: provider) {
        candidates.append(candidate)
      }
    }
    return candidates
  }

  private static func candidate(from provider: NSItemProvider) async -> DashboardOCRImageCandidate?
  {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
      let url = await fileURL(from: provider)
    {
      return candidate(fromFileURL: url)
    }
    if provider.canLoadObject(ofClass: NSImage.self),
      let image = await imageObject(from: provider)
    {
      return DashboardOCRImageCandidate(
        image: image,
        sourceName: "Dropped image",
        sourceDetail: nil,
        fingerprint: DashboardOCRImageFingerprint.make(image: image)
      )
    }
    if let data = await imageData(from: provider),
      let image = NSImage(data: data)
    {
      return DashboardOCRImageCandidate(
        image: image,
        sourceName: "Dropped image",
        sourceDetail: nil,
        fingerprint: DashboardOCRImageFingerprint.make(data: data)
      )
    }
    return nil
  }

  private static func candidate(
    fromPasteboardItem item: NSPasteboardItem
  ) -> DashboardOCRImageCandidate? {
    if let value = item.string(forType: .fileURL),
      let url = URL(string: value),
      isImageURL(url),
      let candidate = candidate(fromFileURL: url)
    {
      return candidate
    }
    guard let data = imageData(from: item), let image = NSImage(data: data) else {
      return nil
    }
    return DashboardOCRImageCandidate(
      image: image,
      sourceName: "Clipboard image",
      sourceDetail: nil,
      fingerprint: DashboardOCRImageFingerprint.make(data: data)
    )
  }

  private static func candidate(fromFileURL url: URL) -> DashboardOCRImageCandidate? {
    url.withSecurityScope { scopedURL in
      guard let data = try? Data(contentsOf: scopedURL), let image = NSImage(data: data) else {
        return nil
      }
      return DashboardOCRImageCandidate(
        image: image,
        sourceName: scopedURL.lastPathComponent.isEmpty
          ? "Image file" : scopedURL.lastPathComponent,
        sourceDetail: scopedURL.deletingLastPathComponent().path,
        fingerprint: DashboardOCRImageFingerprint.make(data: data)
      )
    }
  }

  private static func imageData(from item: NSPasteboardItem) -> Data? {
    for type in imagePasteboardTypes {
      if let data = item.data(forType: type) {
        return data
      }
    }
    return nil
  }

  private static var imagePasteboardTypes: [NSPasteboard.PasteboardType] {
    [
      .tiff,
      .png,
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("public.heic"),
    ]
  }

  private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    guard let items = pasteboard.pasteboardItems else {
      return []
    }
    return items.compactMap { item in
      guard let value = item.string(forType: .fileURL) else {
        return nil
      }
      return URL(string: value)
    }
  }

  private static func isImageURL(_ url: URL) -> Bool {
    guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
      return false
    }
    return contentType.conforms(to: .image)
  }

  private static func fileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        continuation.resume(returning: resolvedFileURL(from: item))
      }
    }
  }

  nonisolated private static func resolvedFileURL(from item: (any NSSecureCoding)?) -> URL? {
    if let url = item as? URL {
      return url
    }
    if let data = item as? Data {
      return URL(dataRepresentation: data, relativeTo: nil)
    }
    if let string = item as? String {
      return URL(string: string)
    }
    return nil
  }

  private static func imageObject(from provider: NSItemProvider) async -> NSImage? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
        continuation.resume(returning: object as? NSImage)
      }
    }
  }

  private static func imageData(from provider: NSItemProvider) async -> Data? {
    for identifier in imageTypeIdentifiers(from: provider) {
      if let data = await dataRepresentation(from: provider, typeIdentifier: identifier) {
        return data
      }
    }
    return nil
  }

  nonisolated private static func imageTypeIdentifiers(from provider: NSItemProvider) -> [String] {
    provider.registeredTypeIdentifiers.filter { identifier in
      guard let contentType = UTType(identifier) else {
        return false
      }
      return contentType.conforms(to: .image)
    }
  }

  private static func dataRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }
}

@MainActor
enum DashboardOCRRecognizer {
  static func recognizeText(in image: NSImage) async -> DashboardOCRRecognitionResult {
    guard let cgImage = image.dashboardOCRCGImage else {
      return .failure("Image cannot be decoded")
    }

    do {
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.automaticallyDetectsLanguage = true
      request.usesLanguageCorrection = true
      let observations = try await request.perform(on: cgImage)
      let text = observations.map(\.transcript).joined(separator: "\n")
      return .success(text)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

extension NSImage {
  var dashboardOCRCGImage: CGImage? {
    guard size.width > 0, size.height > 0 else {
      return nil
    }
    var proposedRect = CGRect(origin: .zero, size: size)
    return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
  }
}
