import AppKit
import CoreGraphics
import Foundation

enum ReviewScreenshotVisualStatus: String, Equatable, Sendable {
  case unknown
  case passing
  case failing
}

enum ReviewPullRequestExtractionReference: Equatable, Hashable, Sendable {
  case resolved(GitHubPullRequestReference)
  case bare(number: UInt64, rawMatch: String)

  var repository: String? {
    guard case .resolved(let reference) = self else { return nil }
    return reference.repository
  }

  var number: UInt64 {
    switch self {
    case .resolved(let reference): reference.number
    case .bare(let number, _): number
    }
  }

  var displayText: String {
    switch self {
    case .resolved(let reference): reference.displayText
    case .bare(let number, _): "#\(number)"
    }
  }
}

struct ReviewPullRequestExtractionRow: Equatable, Identifiable, Sendable {
  let rowIndex: Int
  let reference: ReviewPullRequestExtractionReference
  let text: String
  let titleText: String
  let branchText: String
  let visualStatus: ReviewScreenshotVisualStatus
  let normalizedBoundingBox: CGRect?

  var id: Int { rowIndex }
}

enum ReviewScreenshotPullRequestParser {
  static func rows(
    from result: DashboardOCRRecognitionResult,
    image: NSImage? = nil
  ) -> [ReviewPullRequestExtractionRow] {
    if result.observations.isEmpty {
      return rows(fromTranscript: result.text)
    }
    return rows(fromObservations: result.observations, image: image)
  }

  static func rows(fromTranscript text: String) -> [ReviewPullRequestExtractionRow] {
    text.split(whereSeparator: \.isNewline)
      .map(String.init)
      .enumerated()
      .compactMap { index, line in
        row(rowIndex: index, text: line, boundingBox: nil, image: nil)
      }
  }

  private static func rows(
    fromObservations observations: [DashboardOCRTextObservation],
    image: NSImage?
  ) -> [ReviewPullRequestExtractionRow] {
    let groups = groupedObservations(observations)
    return groups.enumerated().compactMap { index, group in
      let text = group.sorted { lhs, rhs in
        lhs.normalizedBoundingBox.minX < rhs.normalizedBoundingBox.minX
      }
      .map(\.text)
      .joined(separator: " ")
      return row(
        rowIndex: index,
        text: text,
        boundingBox: unionBoundingBox(group),
        image: image
      )
    }
  }

  private static func row(
    rowIndex: Int,
    text: String,
    boundingBox: CGRect?,
    image: NSImage?
  ) -> ReviewPullRequestExtractionRow? {
    guard let reference = firstReference(in: text) else { return nil }
    return ReviewPullRequestExtractionRow(
      rowIndex: rowIndex,
      reference: reference,
      text: text,
      titleText: titleText(from: text),
      branchText: branchText(from: text),
      visualStatus: visualStatus(in: text, boundingBox: boundingBox, image: image),
      normalizedBoundingBox: boundingBox
    )
  }

  private static func groupedObservations(
    _ observations: [DashboardOCRTextObservation]
  ) -> [[DashboardOCRTextObservation]] {
    let sorted = observations.sorted { lhs, rhs in
      lhs.normalizedBoundingBox.midY > rhs.normalizedBoundingBox.midY
    }
    let threshold = rowThreshold(sorted)
    var groups: [[DashboardOCRTextObservation]] = []
    for observation in sorted {
      append(observation, to: &groups, threshold: threshold)
    }
    return groups
  }

  private static func append(
    _ observation: DashboardOCRTextObservation,
    to groups: inout [[DashboardOCRTextObservation]],
    threshold: CGFloat
  ) {
    for index in groups.indices {
      let midY = averageMidY(groups[index])
      guard abs(midY - observation.normalizedBoundingBox.midY) <= threshold else { continue }
      groups[index].append(observation)
      return
    }
    groups.append([observation])
  }

  private static func rowThreshold(_ observations: [DashboardOCRTextObservation]) -> CGFloat {
    let heights = observations.map(\.normalizedBoundingBox.height).sorted()
    guard !heights.isEmpty else { return 0.03 }
    return max(0.025, heights[heights.count / 2] * 1.35)
  }

  private static func averageMidY(_ observations: [DashboardOCRTextObservation]) -> CGFloat {
    observations.map(\.normalizedBoundingBox.midY).reduce(0, +) / CGFloat(observations.count)
  }

  private static func unionBoundingBox(
    _ observations: [DashboardOCRTextObservation]
  ) -> CGRect? {
    observations.map(\.normalizedBoundingBox).reduce(nil) { partial, rect in
      partial?.union(rect) ?? rect
    }
  }

  private static func firstReference(in text: String) -> ReviewPullRequestExtractionReference? {
    if let reference = GitHubPullRequestReferenceParser.references(in: text).first {
      return .resolved(reference)
    }
    guard let bare = barePullRequestNumber(in: text) else { return nil }
    return .bare(number: bare.number, rawMatch: bare.rawMatch)
  }

  private static func barePullRequestNumber(in text: String) -> (number: UInt64, rawMatch: String)?
  {
    let pattern = #"(?<![A-Za-z0-9_/.-])#([0-9]+)(?![0-9])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    guard let fullRange = Range(match.range(at: 0), in: text),
      let numberRange = Range(match.range(at: 1), in: text),
      let number = UInt64(text[numberRange])
    else {
      return nil
    }
    return (number, String(text[fullRange]))
  }

  private static func titleText(from text: String) -> String {
    GitHubPullRequestReferenceParser.references(in: text)
      .reduce(text) { partial, reference in
        partial.replacingOccurrences(of: reference.rawMatch, with: "")
      }
      .replacingOccurrences(
        of: #"(?<![A-Za-z0-9_/.-])#[0-9]+(?![0-9])"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func branchText(from text: String) -> String {
    let patterns = [
      #"(?i)\b(?:branch|from)\s+([A-Za-z0-9_./:-]+)"#,
      #"(?i)\b([A-Za-z0-9_.-]+:[A-Za-z0-9_./-]+)"#,
    ]
    for pattern in patterns {
      guard let value = firstCapture(pattern: pattern, in: text) else { continue }
      return value
    }
    return ""
  }

  private static func firstCapture(pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      match.numberOfRanges > 1,
      let stringRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[stringRange])
  }

  private static func visualStatus(
    in text: String,
    boundingBox: CGRect?,
    image: NSImage?
  ) -> ReviewScreenshotVisualStatus {
    let textualStatus = visualStatusFromText(text)
    let pixelStatus = visualStatusFromPixels(boundingBox: boundingBox, image: image)
    if textualStatus == .failing || pixelStatus == .failing { return .failing }
    if textualStatus == .passing || pixelStatus == .passing { return .passing }
    return .unknown
  }

  private static func visualStatusFromText(_ text: String) -> ReviewScreenshotVisualStatus {
    let normalized = text.lowercased()
    let failingMarkers = ["failed", "failure", "failing", "checks failing", "✕", "×", "❌", "🔴"]
    if failingMarkers.contains(where: normalized.contains) { return .failing }
    let passingMarkers = ["passed", "passing", "checks passed", "success", "✓", "✔", "✅", "🟢"]
    if passingMarkers.contains(where: normalized.contains) { return .passing }
    return .unknown
  }

  private static func visualStatusFromPixels(
    boundingBox: CGRect?,
    image: NSImage?
  ) -> ReviewScreenshotVisualStatus {
    guard let boundingBox, let cgImage = image?.dashboardOCRCGImage else { return .unknown }
    let sampler = ReviewScreenshotPixelSampler(cgImage: cgImage)
    return sampler.status(in: boundingBox)
  }
}

private struct ReviewScreenshotPixelSampler {
  let cgImage: CGImage

  func status(in normalizedBox: CGRect) -> ReviewScreenshotVisualStatus {
    guard let provider = cgImage.dataProvider,
      let data = provider.data,
      let bytes = CFDataGetBytePtr(data),
      cgImage.bitsPerPixel / 8 >= 3
    else {
      return .unknown
    }
    let rect = pixelRect(from: normalizedBox)
    guard rect.width > 0, rect.height > 0 else { return .unknown }
    let counts = sampleCounts(bytes: bytes, rect: rect)
    if counts.red >= 6 && counts.red >= counts.green { return .failing }
    if counts.green >= 6 { return .passing }
    return .unknown
  }

  private func pixelRect(from normalizedBox: CGRect) -> CGRect {
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)
    var rect = CGRect(
      x: normalizedBox.minX * width,
      y: (1 - normalizedBox.maxY) * height,
      width: normalizedBox.width * width,
      height: normalizedBox.height * height
    ).integral
    rect.origin.x += rect.width * 0.10
    rect.size.width *= 0.90
    return rect
  }

  private func sampleCounts(
    bytes: UnsafePointer<UInt8>,
    rect: CGRect
  ) -> (red: Int, green: Int) {
    let stepX = max(1, Int(rect.width) / 80)
    let stepY = max(1, Int(rect.height) / 12)
    var red = 0
    var green = 0
    for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: stepY) {
      for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: stepX) {
        let sample = pixel(bytes: bytes, x: x, y: y)
        if sample.isRed { red += 1 }
        if sample.isGreen { green += 1 }
      }
    }
    return (red, green)
  }

  private func pixel(bytes: UnsafePointer<UInt8>, x: Int, y: Int) -> ReviewScreenshotPixel {
    let safeX = min(max(x, 0), cgImage.width - 1)
    let safeY = min(max(y, 0), cgImage.height - 1)
    let offset = safeY * cgImage.bytesPerRow + safeX * max(1, cgImage.bitsPerPixel / 8)
    return ReviewScreenshotPixel(c0: bytes[offset], c1: bytes[offset + 1], c2: bytes[offset + 2])
  }
}

private struct ReviewScreenshotPixel {
  let c0: UInt8
  let c1: UInt8
  let c2: UInt8

  var isRed: Bool {
    redDominates(red: c0, green: c1, blue: c2) || redDominates(red: c2, green: c1, blue: c0)
  }

  var isGreen: Bool {
    c1 > 130 && c0 < 140 && c2 < 140 && Int(c1) > Int(max(c0, c2)) + 35
  }

  private func redDominates(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
    red > 150 && green < 120 && blue < 120 && Int(red) > Int(green) + 40
  }
}
