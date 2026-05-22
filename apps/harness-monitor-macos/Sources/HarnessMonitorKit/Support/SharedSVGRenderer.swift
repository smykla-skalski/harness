import AppKit
import CoreGraphics
import Foundation
import WebKit

/// Singleton SVG rasterizer for the Dependencies > Files image preview.
///
/// Two paths:
/// - AppKit native: `NSImage(data:)` handles most SVGs on macOS 13+; if
///   it succeeds, the WKWebView fallback is skipped entirely.
/// - WebKit fallback: a single off-screen `WKWebView` rasterizes SVGs the
///   AppKit decoder rejects (e.g. animated SMIL, foreign objects). The
///   actor serializes every fallback request through the singleton
///   webview so concurrent callers can't race the snapshot pipeline.
public actor SharedSVGRenderer {
  public static let shared = SharedSVGRenderer()

  public struct Rasterized: @unchecked Sendable, Equatable {
    public let cgImage: CGImage
    public let intrinsicSize: CGSize
    public let usedWebKitFallback: Bool

    public init(cgImage: CGImage, intrinsicSize: CGSize, usedWebKitFallback: Bool) {
      self.cgImage = cgImage
      self.intrinsicSize = intrinsicSize
      self.usedWebKitFallback = usedWebKitFallback
    }

    public static func == (lhs: Rasterized, rhs: Rasterized) -> Bool {
      lhs.cgImage === rhs.cgImage
        && lhs.intrinsicSize == rhs.intrinsicSize
        && lhs.usedWebKitFallback == rhs.usedWebKitFallback
    }
  }

  public enum RenderError: Error, Equatable, Sendable {
    case nativeDecodeUnavailable
    case webKitDecodeFailed
  }

  public init() {}

  /// Rasterize the supplied SVG bytes to a CGImage. Tries the AppKit
  /// native path first; falls back to WKWebView (serialized through the
  /// shared off-screen webview) only when AppKit refuses.
  public func rasterize(
    data: Data,
    maxDimension: Int
  ) async throws -> Rasterized {
    if let native = Self.rasterizeNative(data: data, maxDimension: maxDimension) {
      return native
    }
    return try await Self.rasterizeViaWebKit(data: data, maxDimension: maxDimension)
  }

  // MARK: - Native AppKit path

  static func rasterizeNative(data: Data, maxDimension: Int) -> Rasterized? {
    guard let image = NSImage(data: data) else { return nil }
    let dimension = CGFloat(max(maxDimension, 1))
    let intrinsicSize = image.size
    let scale: CGFloat
    if intrinsicSize.width <= 0 || intrinsicSize.height <= 0 {
      scale = 1
    } else {
      scale = min(
        dimension / intrinsicSize.width,
        dimension / intrinsicSize.height,
        1
      )
    }
    let targetWidth = max(Int(intrinsicSize.width * scale), 1)
    let targetHeight = max(Int(intrinsicSize.height * scale), 1)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard
      let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: targetWidth * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
      )
    else {
      return nil
    }
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    image.draw(
      in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
      from: .zero,
      operation: .copy,
      fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = context.makeImage() else { return nil }
    return Rasterized(
      cgImage: cgImage,
      intrinsicSize: intrinsicSize,
      usedWebKitFallback: false
    )
  }

  // MARK: - WebKit fallback

  static func rasterizeViaWebKit(
    data: Data,
    maxDimension: Int
  ) async throws -> Rasterized {
    try await SVGWebKitRasterizer.shared.rasterize(data: data, maxDimension: maxDimension)
  }
}

@MainActor
final class SVGWebKitRasterizer: NSObject, WKNavigationDelegate {
  static let shared = SVGWebKitRasterizer()

  private let webView: WKWebView
  private var pendingContinuation: CheckedContinuation<Void, Error>?

  private override init() {
    let config = WKWebViewConfiguration()
    self.webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    self.webView.navigationDelegate = self
  }

  func rasterize(
    data: Data,
    maxDimension: Int
  ) async throws -> SharedSVGRenderer.Rasterized {
    let dimension = max(maxDimension, 1)
    webView.frame = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    guard let html = makeHTML(svgData: data, dimension: dimension) else {
      throw SharedSVGRenderer.RenderError.webKitDecodeFailed
    }
    try await loadHTML(html)
    let snapshotConfig = WKSnapshotConfiguration()
    snapshotConfig.rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    let snapshot: NSImage
    do {
      snapshot = try await webView.takeSnapshot(configuration: snapshotConfig)
    } catch {
      throw SharedSVGRenderer.RenderError.webKitDecodeFailed
    }
    guard
      let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
      throw SharedSVGRenderer.RenderError.webKitDecodeFailed
    }
    return SharedSVGRenderer.Rasterized(
      cgImage: cgImage,
      intrinsicSize: CGSize(width: cgImage.width, height: cgImage.height),
      usedWebKitFallback: true
    )
  }

  private func loadHTML(_ html: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
      pendingContinuation = continuation
      webView.loadHTMLString(html, baseURL: nil)
    }
  }

  private func makeHTML(svgData: Data, dimension: Int) -> String? {
    guard let svgText = String(data: svgData, encoding: .utf8) else { return nil }
    return """
      <!doctype html>
      <html>
        <head>
          <style>
            html, body { margin: 0; padding: 0; background: transparent; }
            body { width: \(dimension)px; height: \(dimension)px; }
            svg { width: 100%; height: 100%; }
          </style>
        </head>
        <body>\(svgText)</body>
      </html>
      """
  }

  // MARK: WKNavigationDelegate

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in
      self.pendingContinuation?.resume()
      self.pendingContinuation = nil
    }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    Task { @MainActor in
      self.pendingContinuation?.resume(throwing: error)
      self.pendingContinuation = nil
    }
  }

  nonisolated func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    Task { @MainActor in
      self.pendingContinuation?.resume(throwing: error)
      self.pendingContinuation = nil
    }
  }
}
