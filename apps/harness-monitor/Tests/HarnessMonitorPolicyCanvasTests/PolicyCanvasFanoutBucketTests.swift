import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas fanout bucket quantization")
struct PolicyCanvasFanoutBucketTests {
  @Test("sub-grid jitter stays in the same bucket")
  func subGridJitterSameBucket() {
    let bucketA = policyCanvasFanoutBucketCoordinate(100.4)
    let bucketB = policyCanvasFanoutBucketCoordinate(100.6)
    let bucketC = policyCanvasFanoutBucketCoordinate(109.9)
    #expect(bucketA == bucketB, "Sub-pixel motion must not flip the bucket")
    #expect(bucketA == bucketC, "Motion within half-quantum stays in same bucket")
  }

  @Test("motion across a quantum threshold flips bucket")
  func motionAcrossQuantumFlipsBucket() {
    let bucketA = policyCanvasFanoutBucketCoordinate(100)
    let bucketB = policyCanvasFanoutBucketCoordinate(120)
    #expect(bucketA == 100)
    #expect(bucketB == 120)
    #expect(bucketA != bucketB)
  }

  @Test("custom quantum respected")
  func customQuantumRespected() {
    let bucketA = policyCanvasFanoutBucketCoordinate(100.6, quantum: 5)
    let bucketB = policyCanvasFanoutBucketCoordinate(102.4, quantum: 5)
    #expect(bucketA == 100)
    #expect(bucketB == 100, "102.4 rounds to nearest 5 -> 100")
  }

  @Test("negative anchors quantize correctly")
  func negativeAnchorsQuantizeCorrectly() {
    let bucket = policyCanvasFanoutBucketCoordinate(-100.4)
    #expect(bucket == -100)
  }
}
