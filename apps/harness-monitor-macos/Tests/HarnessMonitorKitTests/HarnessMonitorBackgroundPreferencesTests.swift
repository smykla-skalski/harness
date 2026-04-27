import CoreGraphics
import Foundation
import Testing
import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class BackgroundAssetBundleTests: XCTestCase {
  func testBundledBackgroundImagesArePackagedWithPreviewableAssets() {
    for image in HarnessMonitorBackgroundImage.allCases {
      XCTAssertNotNil(
        HarnessMonitorUIAssets.bundle.image(forResource: image.assetName),
        "Missing bundled background asset: \(image.assetName)"
      )
    }
  }

  func testThumbnailGenerationCapsInheritedUIPriority() {
    XCTAssertEqual(
      BackgroundThumbnailCache.imageGenerationPriority(for: .userInitiated),
      .medium
    )
  }
}

@Suite("Background thumbnail cache")
struct BackgroundThumbnailCacheTests {
  @Test("Thumbnail memory cache evicts older entries beyond the configured limit")
  func thumbnailMemoryCacheEvictsOlderEntriesBeyondConfiguredLimit() async {
    let cache = BackgroundThumbnailCache(
      cacheDirectory: makeTemporaryThumbnailCacheDirectory(),
      maxPixelSize: 64,
      thumbnailMemoryLimit: 2,
      fullImageMemoryLimit: 1
    )
    let selections = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(3))

    _ = await cache.thumbnail(for: selections[0])
    _ = await cache.thumbnail(for: selections[1])
    _ = await cache.thumbnail(for: selections[2])

    let firstKey = cache.cacheKey(for: selections[0])
    let secondKey = cache.cacheKey(for: selections[1])
    let thirdKey = cache.cacheKey(for: selections[2])

    #expect(Set(await cache.thumbnailMemoryCache.keys) == Set([secondKey, thirdKey]))
    #expect(await cache.thumbnailMemoryCache[firstKey] == nil)
  }

  @Test("Full image memory cache stays bounded independently of thumbnails")
  func fullImageMemoryCacheStaysBoundedIndependentlyOfThumbnails() async {
    let cache = BackgroundThumbnailCache(
      cacheDirectory: makeTemporaryThumbnailCacheDirectory(),
      maxPixelSize: 64,
      thumbnailMemoryLimit: 3,
      fullImageMemoryLimit: 1
    )
    let selections = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(3))

    _ = await cache.thumbnail(for: selections[0])
    _ = await cache.thumbnail(for: selections[1])
    _ = await cache.fullImage(for: selections[0])
    _ = await cache.fullImage(for: selections[1])

    let firstKey = cache.cacheKey(for: selections[0])
    let secondKey = cache.cacheKey(for: selections[1])
    let firstFullKey = "full:\(firstKey)"
    let secondFullKey = "full:\(secondKey)"

    #expect(Set(await cache.thumbnailMemoryCache.keys) == Set([firstKey, secondKey]))
    #expect(Set(await cache.fullImageMemoryCache.keys) == Set([secondFullKey]))
    #expect(await cache.fullImageMemoryCache[firstFullKey] == nil)
  }

  @Test("Memory cache evicts images by byte budget before count budget")
  func memoryCacheEvictsImagesByByteBudgetBeforeCountBudget() async {
    let cache = BackgroundThumbnailCache(
      cacheDirectory: makeTemporaryThumbnailCacheDirectory(),
      maxPixelSize: 64,
      thumbnailMemoryLimit: 10,
      fullImageMemoryLimit: 10,
      thumbnailMemoryByteLimit: 512,
      fullImageMemoryByteLimit: 512
    )
    let firstImage = makeTestImage(width: 12, height: 12)
    let secondImage = makeTestImage(width: 12, height: 12)

    await cache.cacheMemoryImage(firstImage, for: "first", kind: .thumbnail)
    await cache.cacheMemoryImage(secondImage, for: "second", kind: .thumbnail)

    #expect(Set(await cache.thumbnailMemoryCache.keys) == Set(["second"]))
    #expect(await cache.thumbnailMemoryCacheByteCost <= 512)
  }

  @Test(
    "Disk cache writes thumbnails into a noindex directory and removes legacy indexed thumbnails"
  )
  func diskCacheUsesNoIndexDirectoryAndRemovesLegacyIndexedThumbnails() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheDirectory = root.appendingPathComponent("cache.noindex/thumbnails", isDirectory: true)
    let legacyDirectory = root.appendingPathComponent("cache/thumbnails", isDirectory: true)
    try? FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    try? Data("legacy".utf8).write(
      to: legacyDirectory.appendingPathComponent("legacy.txt"),
      options: .atomic
    )

    let cache = BackgroundThumbnailCache(
      cacheDirectory: cacheDirectory,
      maxPixelSize: 64,
      thumbnailMemoryLimit: 2,
      fullImageMemoryLimit: 1
    )
    let selection = HarnessMonitorBackgroundSelection.bundledLibrary[0]

    _ = await cache.thumbnail(for: selection)

    let key = cache.cacheKey(for: selection)
    let thumbnailURL = cacheDirectory.appendingPathComponent("\(key).jpg")

    #expect(thumbnailURL.path.contains("/cache.noindex/thumbnails/"))
    #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    #expect(FileManager.default.fileExists(atPath: legacyDirectory.path) == false)
  }
}

final class BackgroundGalleryPrefetchPlanTests: XCTestCase {
  func testInitialPlanKeepsSelectedBackgroundWarmWithoutPrefetchingWholeLibrary() {
    let options = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(10))
    let selectedBackground = options[9]
    let recentItems = [options[8]]

    let plan = PreferencesBackgroundGalleryPrefetchPlan.selections(
      options: options,
      recentItems: recentItems,
      selectedBackground: selectedBackground,
      visibleIDs: []
    )

    XCTAssertEqual(plan.map(\.storageValue), Array(options.prefix(10)).map(\.storageValue))
  }

  func testVisibleTileChurnDoesNotChangeGalleryPrefetchPlan() {
    let options = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(20))
    let selectedBackground = options[19]
    let recentItems = [options[0]]

    let plan = PreferencesBackgroundGalleryPrefetchPlan.selections(
      options: options,
      recentItems: recentItems,
      selectedBackground: selectedBackground,
      visibleIDs: [options[15].id, options[16].id]
    )

    let expectedStorageValues =
      Array(options.prefix(PreferencesBackgroundGalleryPrefetchPlan.initialLimit))
      .map(\.storageValue) + [selectedBackground.storageValue]
    XCTAssertEqual(plan.map(\.storageValue), expectedStorageValues)
  }
}

private func makeTemporaryThumbnailCacheDirectory() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func makeTestImage(width: Int, height: Int) -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    fatalError("failed to create test CGContext")
  }
  context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = context.makeImage() else {
    fatalError("failed to create test CGImage")
  }
  return image
}
