import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit

struct SharedSVGRendererTests {
  private static let trivialSVG = Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
      <rect width="100" height="100" fill="#3366cc" />
    </svg>
    """.utf8
  )

  @Test("AppKit-native SVG rasterizes via the native path (no WebKit fallback)")
  func nativePathBypassesWebKit() async throws {
    let renderer = SharedSVGRenderer()
    let result = try await renderer.rasterize(data: Self.trivialSVG, maxDimension: 64)
    #expect(result.usedWebKitFallback == false)
    #expect(result.cgImage.width > 0)
    #expect(result.cgImage.height > 0)
  }

  @Test("rasterize keeps the source's intrinsic size for native decodes")
  func intrinsicSizePreserved() async throws {
    let renderer = SharedSVGRenderer()
    let result = try await renderer.rasterize(data: Self.trivialSVG, maxDimension: 256)
    #expect(result.intrinsicSize.width == 100)
    #expect(result.intrinsicSize.height == 100)
  }

  @Test("concurrent rasterize calls on the shared renderer do not crash")
  func concurrentCallsSurvive() async throws {
    let renderer = SharedSVGRenderer()
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask {
          do {
            _ = try await renderer.rasterize(data: Self.trivialSVG, maxDimension: 32)
            return true
          } catch {
            return false
          }
        }
      }
      var oks = 0
      for await ok in group where ok { oks += 1 }
      #expect(oks == 8)
    }
  }

  @Test("rasterizeNative returns nil for non-image bytes so the caller can fall back")
  func nativePathRejectsNonImageBytes() {
    let result = SharedSVGRenderer.rasterizeNative(
      data: Data([0x00, 0x01, 0x02]),
      maxDimension: 64
    )
    #expect(result == nil)
  }
}
