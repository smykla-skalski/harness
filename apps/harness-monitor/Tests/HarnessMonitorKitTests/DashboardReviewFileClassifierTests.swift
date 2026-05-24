import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file classifier")
struct DashboardReviewFileClassifierTests {
  @Test("streams overlapping buckets in deterministic order")
  func streamsOverlappingBucketsInDeterministicOrder() {
    let file = ReviewFile(path: ".github/workflows/generated_test.generated.swift")
    var buckets: [DashboardReviewFileBucket] = []

    DashboardReviewFileClassifier.forEachBucket(for: file) { bucket in
      buckets.append(bucket)
    }

    #expect(buckets == [.generated, .workflows, .tests])
  }

  @Test("matches source only when no specific bucket applies")
  func matchesSourceOnlyWhenNoSpecificBucketApplies() {
    let source = ReviewFile(path: "Sources/App/Feature.swift")
    let config = ReviewFile(path: "Sources/App/Feature.generated.swift")
    let binary = ReviewFile(path: "Images/logo.png", isBinary: true)

    #expect(DashboardReviewFileClassifier.matches(source, bucket: .source))
    #expect(!DashboardReviewFileClassifier.matches(config, bucket: .source))
    #expect(DashboardReviewFileClassifier.matches(config, bucket: .generated))
    #expect(DashboardReviewFileClassifier.matches(binary, bucket: .binary))
    #expect(!DashboardReviewFileClassifier.matches(binary, bucket: .source))
  }

  @Test("classification avoids transient bucket arrays")
  func classificationAvoidsTransientBucketArrays() throws {
    let source = try dashboardReviewsRouteSource(named: "DashboardReviewFilesPresentation.swift")

    #expect(source.contains("static func forEachBucket("))
    #expect(source.contains("DashboardReviewFileClassifier.forEachBucket(for: file)"))
    #expect(!source.contains("static func buckets(for file: ReviewFile) -> ["))
    #expect(!source.contains("buckets(for: file).contains(bucket)"))
    #expect(!source.contains("for bucket in DashboardReviewFileClassifier.buckets(for: file)"))
  }
}
