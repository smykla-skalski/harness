import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HarnessMonitorKit

struct ReviewImageDecoderTests {
  /// Build a synthetic PNG with the requested pixel dimensions so the
  /// tests don't rely on bundled fixture assets.
  private static func makePNG(width: Int, height: Int) -> Data {
    let bytesPerRow = width * 4
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
      )
    else {
      return Data()
    }
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.5, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let cgImage = context.makeImage() else { return Data() }

    let buffer = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        buffer,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      return Data()
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    if !CGImageDestinationFinalize(destination) {
      return Data()
    }
    return buffer as Data
  }

  @Test("decode produces a PreparedImage with the source pixel intrinsic size")
  func decodeProducesIntrinsicSize() async throws {
    let decoder = ReviewImageDecoder()
    let data = Self.makePNG(width: 320, height: 240)
    let prepared = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 512,
      data: data
    )
    #expect(prepared.intrinsicSize.width == 320)
    #expect(prepared.intrinsicSize.height == 240)
    #expect(prepared.byteSize > 0)
  }

  @Test("decode caches by (repositoryID, oid, displaySizeBucket)")
  func decodeCachesByKey() async throws {
    let decoder = ReviewImageDecoder()
    let data = Self.makePNG(width: 64, height: 64)
    let first = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 256,
      data: data
    )
    let cached = await decoder.cached(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 256
    )
    #expect(cached == first)
  }

  @Test("same oid with different display buckets caches separately")
  func differentBucketsCacheSeparately() async throws {
    let decoder = ReviewImageDecoder()
    let data = Self.makePNG(width: 256, height: 256)
    _ = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 200,
      data: data
    )
    _ = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 1000,
      data: data
    )
    let smallBucket = ReviewImageDecoder.bucket(forDisplayMaxDimension: 200)
    let largeBucket = ReviewImageDecoder.bucket(forDisplayMaxDimension: 1000)
    #expect(smallBucket != largeBucket)
    let small = await decoder.cached(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 200
    )
    let large = await decoder.cached(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 1000
    )
    #expect(small != nil)
    #expect(large != nil)
  }

  @Test("LRU evicts by byte count when total exceeds the cap")
  func lruEvictsByBytes() async throws {
    // Cap to a single 64x64 RGBA tile (16 384 bytes) plus a hair extra so
    // the third decode forces eviction of the oldest.
    let decoder = ReviewImageDecoder(maxBytes: 20_000)
    let data = Self.makePNG(width: 64, height: 64)
    _ = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 64,
      data: data
    )
    _ = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-2",
      displayMaxDimension: 64,
      data: data
    )
    let secondPresent = await decoder.cached(
      repositoryID: "repo-1",
      oid: "oid-2",
      displayMaxDimension: 64
    )
    let firstPresent = await decoder.cached(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 64
    )
    #expect(secondPresent != nil)
    #expect(firstPresent == nil)
  }

  @Test("clear drops all cached PreparedImage entries and zeroes currentBytes")
  func clearWipesEverything() async throws {
    let decoder = ReviewImageDecoder()
    _ = try await decoder.decode(
      repositoryID: "repo-1",
      oid: "oid-1",
      displayMaxDimension: 256,
      data: Self.makePNG(width: 64, height: 64)
    )
    await decoder.clear()
    #expect(await decoder.currentBytes() == 0)
    #expect(
      await decoder.cached(
        repositoryID: "repo-1",
        oid: "oid-1",
        displayMaxDimension: 256
      ) == nil
    )
  }

  @Test("bucket(forDisplayMaxDimension:) rounds up to nearest power of two")
  func bucketRounding() {
    #expect(ReviewImageDecoder.bucket(forDisplayMaxDimension: 200) == 256)
    #expect(ReviewImageDecoder.bucket(forDisplayMaxDimension: 256) == 256)
    #expect(ReviewImageDecoder.bucket(forDisplayMaxDimension: 257) == 512)
    #expect(ReviewImageDecoder.bucket(forDisplayMaxDimension: 1000) == 1024)
    #expect(ReviewImageDecoder.bucket(forDisplayMaxDimension: 0) == 1)
  }

  @Test("decode of corrupt data throws imageSourceCreationFailed")
  func decodeRejectsBadData() async {
    let decoder = ReviewImageDecoder()
    let badData = Data([0xff, 0xfe, 0xfd])
    do {
      _ = try await decoder.decode(
        repositoryID: "repo-1",
        oid: "oid-bad",
        displayMaxDimension: 64,
        data: badData
      )
      Issue.record("Expected decode to throw on bogus bytes")
    } catch let error as ReviewImageDecoder.DecodeError {
      #expect(error == .imageSourceCreationFailed || error == .thumbnailCreationFailed)
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }
}
