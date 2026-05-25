import AppKit
import Foundation
import ImageIO
import SwiftData
import XCTest

@testable import HarnessMonitorKit

final class ReviewAvatarCacheTests: XCTestCase {
  override func tearDown() {
    ReviewAvatarURLProtocol.reset()
    super.tearDown()
  }

  func testDownsampleReturnsBitmapAtMostTargetPixelSize() throws {
    let original = try Self.makeSolidColorPNG(size: NSSize(width: 256, height: 256))
    let image = try XCTUnwrap(
      ReviewAvatarCache.downsample(data: original, targetPixel: 64)
    )
    XCTAssertLessThanOrEqual(image.size.width, 64)
    XCTAssertLessThanOrEqual(image.size.height, 64)
  }

  func testDownsampleClampsToFloorWhenTargetSmall() throws {
    let original = try Self.makeSolidColorPNG(size: NSSize(width: 256, height: 256))
    let image = try XCTUnwrap(
      ReviewAvatarCache.downsample(data: original, targetPixel: 8)
    )
    XCTAssertGreaterThanOrEqual(image.size.width, 32)
  }

  func testDownsampleReturnsNilForInvalidData() {
    let result = ReviewAvatarCache.downsample(
      data: Data([0x00, 0x01, 0x02]),
      targetPixel: 64
    )
    XCTAssertNil(result)
  }

  func testAvatarPersistsFetchedBytesInSwiftData() async throws {
    let avatarURL = try XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/in/2740?v=4"))
    let original = try Self.makeSolidColorPNG(size: NSSize(width: 256, height: 256))
    ReviewAvatarURLProtocol.reset(data: original)
    let cache = ReviewAvatarCache(session: Self.makeSession())
    let modelContainer = try HarnessMonitorModelContainer.preview()

    let first = await cache.avatar(
      for: avatarURL,
      targetPixel: 36,
      modelContainer: modelContainer
    )
    await cache.clear()
    let second = await cache.avatar(
      for: avatarURL,
      targetPixel: 36,
      modelContainer: modelContainer
    )

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    XCTAssertEqual(ReviewAvatarURLProtocol.requestCount, 1)

    let context = ModelContext(modelContainer)
    let rows = try context.fetch(FetchDescriptor<CachedReviewAvatar>())
    XCTAssertEqual(rows.map(\.avatarURL), [avatarURL.absoluteString])
    XCTAssertEqual(rows.first?.mimeType, "image/png")
  }

  func testConcurrentDifferentSizesShareSingleFetchButKeepPerSizeImages() async throws {
    let avatarURL = try XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/u/1?v=4"))
    let original = try Self.makeSolidColorPNG(size: NSSize(width: 256, height: 256))
    ReviewAvatarURLProtocol.reset(data: original)
    let cache = ReviewAvatarCache(session: Self.makeSession())

    async let compact = cache.avatar(for: avatarURL, targetPixel: 16)
    async let spacious = cache.avatar(for: avatarURL, targetPixel: 120)
    let compactResult = await compact
    let spaciousResult = await spacious
    let compactImage = try XCTUnwrap(compactResult)
    let spaciousImage = try XCTUnwrap(spaciousResult)

    XCTAssertLessThanOrEqual(compactImage.size.width, 32)
    XCTAssertGreaterThan(spaciousImage.size.width, compactImage.size.width)
    XCTAssertLessThanOrEqual(spaciousImage.size.width, 120)
    XCTAssertEqual(ReviewAvatarURLProtocol.requestCount, 1)
  }

  func testFailureBackoffSkipsImmediateRetryForSameAvatarURL() async throws {
    let avatarURL = try XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/u/2?v=4"))
    ReviewAvatarURLProtocol.reset(statusCode: 503)
    let cache = ReviewAvatarCache(session: Self.makeSession())

    let first = await cache.avatar(for: avatarURL, targetPixel: 36)
    let second = await cache.avatar(for: avatarURL, targetPixel: 36)

    XCTAssertNil(first)
    XCTAssertNil(second)
    XCTAssertEqual(ReviewAvatarURLProtocol.requestCount, 1)
  }

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReviewAvatarURLProtocol.self]
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }

  private static func makeSolidColorPNG(size: NSSize) throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width),
      pixelsHigh: Int(size.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 32
    )
    let unwrapped = try XCTUnwrap(bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: unwrapped)
    NSColor.systemBlue.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(unwrapped.representation(using: .png, properties: [:]))
  }
}

private class ReviewAvatarURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var currentData: Data?
  nonisolated(unsafe) private static var currentStatusCode = 200
  nonisolated(unsafe) private static var currentContentType = "image/png"
  nonisolated(unsafe) private static var currentError: Error?
  nonisolated(unsafe) private static var requests = 0

  static var requestCount: Int {
    lock.withLock { requests }
  }

  static func reset(
    data: Data? = nil,
    statusCode: Int = 200,
    contentType: String = "image/png",
    error: Error? = nil
  ) {
    lock.withLock {
      currentData = data
      currentStatusCode = statusCode
      currentContentType = contentType
      currentError = error
      requests = 0
    }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.contains("github") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let state = Self.lock.withLock { () -> (Data?, Int, String, Error?) in
      Self.requests += 1
      return (
        Self.currentData,
        Self.currentStatusCode,
        Self.currentContentType,
        Self.currentError
      )
    }
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    if let error = state.3 {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let response = HTTPURLResponse(
      url: url,
      statusCode: state.1,
      httpVersion: nil,
      headerFields: ["Content-Type": state.2]
    )
    guard let response else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let data = state.0 {
      client?.urlProtocol(self, didLoad: data)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
