import AppKit
import CoreGraphics
import Foundation

public protocol HarnessMonitorNotificationAssetWriting: Sendable {
  @MainActor
  func sampleImageURL() throws -> URL

  @MainActor
  func sampleSoundName() throws -> String
}

public struct HarnessMonitorNotificationAssetWriter: HarnessMonitorNotificationAssetWriting {
  private static let sampleImageName = "harness-monitor-notification-sample.png"
  private static let sampleSoundName = "HarnessMonitorNotificationSample.wav"

  private let environment: HarnessMonitorEnvironment

  public init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  public func sampleImageURL() throws -> URL {
    let directory = HarnessMonitorPaths.harnessRoot(using: environment)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("notifications", isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = directory.appendingPathComponent(Self.sampleImageName)
    if !fileManager.fileExists(atPath: url.path) {
      try Self.makeSampleImageData().write(to: url, options: .atomic)
    }
    return url
  }

  public func sampleSoundName() throws -> String {
    let directory = environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Sounds", isDirectory: true)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = directory.appendingPathComponent(Self.sampleSoundName)
    if !fileManager.fileExists(atPath: url.path) {
      try Self.makeSampleWaveData().write(to: url, options: .atomic)
    }
    return Self.sampleSoundName
  }

  private static func makeSampleImageData() throws -> Data {
    let width = 640
    let height = 360
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("sample PNG")
    }

    context.setFillColor(CGColor(red: 0.08, green: 0.1, blue: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let tilePath = CGPath(
      roundedRect: CGRect(x: 56, y: 64, width: 180, height: 180),
      cornerWidth: 18,
      cornerHeight: 18,
      transform: nil
    )
    context.addPath(tilePath)
    context.setFillColor(CGColor(red: 0.0, green: 0.72, blue: 0.88, alpha: 1))
    context.fillPath()

    context.setFillColor(CGColor(red: 0.96, green: 0.82, blue: 0.2, alpha: 1))
    context.fillEllipse(in: CGRect(x: 360, y: 126, width: 136, height: 136))

    context.setStrokeColor(CGColor(red: 0.85, green: 0.92, blue: 0.88, alpha: 1))
    context.setLineWidth(16)
    context.setLineCap(.round)
    context.beginPath()
    context.move(to: CGPoint(x: 108, y: 164))
    context.addLine(to: CGPoint(x: 172, y: 116))
    context.addLine(to: CGPoint(x: 252, y: 244))
    context.addLine(to: CGPoint(x: 340, y: 170))
    context.addLine(to: CGPoint(x: 444, y: 222))
    context.addLine(to: CGPoint(x: 548, y: 118))
    context.strokePath()

    guard let image = context.makeImage() else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("sample PNG")
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:])
    else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("sample PNG")
    }
    return data
  }

  private static func makeSampleWaveData() -> Data {
    let sampleRate = 44_100
    let durationSeconds = 0.45
    let channelCount = 1
    let bitsPerSample = 16
    let byteRate = sampleRate * channelCount * bitsPerSample / 8
    let blockAlign = channelCount * bitsPerSample / 8
    let sampleCount = Int(Double(sampleRate) * durationSeconds)
    let dataByteCount = sampleCount * blockAlign

    var data = Data()
    data.appendASCII("RIFF")
    data.appendLittleEndianUInt32(UInt32(36 + dataByteCount))
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendLittleEndianUInt32(16)
    data.appendLittleEndianUInt16(1)
    data.appendLittleEndianUInt16(UInt16(channelCount))
    data.appendLittleEndianUInt32(UInt32(sampleRate))
    data.appendLittleEndianUInt32(UInt32(byteRate))
    data.appendLittleEndianUInt16(UInt16(blockAlign))
    data.appendLittleEndianUInt16(UInt16(bitsPerSample))
    data.appendASCII("data")
    data.appendLittleEndianUInt32(UInt32(dataByteCount))

    for sampleIndex in 0..<sampleCount {
      let progress = Double(sampleIndex) / Double(sampleRate)
      let envelope = max(0.0, 1.0 - (progress / durationSeconds))
      let value = sin(2.0 * Double.pi * 880.0 * progress) * 0.36 * envelope
      data.appendLittleEndianInt16(Int16(value * Double(Int16.max)))
    }

    return data
  }
}

extension Data {
  fileprivate mutating func appendASCII(_ value: String) {
    append(contentsOf: value.utf8)
  }

  fileprivate mutating func appendLittleEndianUInt16(_ value: UInt16) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
  }

  fileprivate mutating func appendLittleEndianInt16(_ value: Int16) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
  }

  fileprivate mutating func appendLittleEndianUInt32(_ value: UInt32) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
  }
}
