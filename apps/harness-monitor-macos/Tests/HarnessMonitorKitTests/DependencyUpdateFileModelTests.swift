import Foundation
import XCTest

@testable import HarnessMonitorKit

/// Parity tests for the Swift mirrors of the daemon's files-section types.
/// Asserts on the truth-table inference helpers + JSON round-trip with the
/// daemon's snake_case-encoded shapes.
final class DependencyUpdateFileModelTests: XCTestCase {

  // MARK: - Language inference parity

  func testInferLanguageSwiftExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "apps/Foo.swift"), .swift)
  }

  func testInferLanguageRustExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "src/lib.rs"), .rust)
  }

  func testInferLanguageShellExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: "bin/build.sh"), .shell)
    XCTAssertEqual(harnessInferLanguage(forPath: "scripts/x.bash"), .shell)
    XCTAssertEqual(harnessInferLanguage(forPath: "zshrc.zsh"), .shell)
    XCTAssertEqual(harnessInferLanguage(forPath: "fishrc.fish"), .shell)
  }

  func testInferLanguageJsonExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: "config.json"), .json)
    XCTAssertEqual(harnessInferLanguage(forPath: "config.jsonc"), .json)
  }

  func testInferLanguageYamlExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: ".github/x.yml"), .yaml)
    XCTAssertEqual(harnessInferLanguage(forPath: ".github/y.yaml"), .yaml)
  }

  func testInferLanguageMarkdownExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: "docs/Guide.md"), .markdown)
    XCTAssertEqual(harnessInferLanguage(forPath: "docs/Guide.MARKDOWN"), .markdown)
    XCTAssertEqual(harnessInferLanguage(forPath: "README.md"), .markdown)
  }

  func testInferLanguageDiffExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: "change.patch"), .diff)
    XCTAssertEqual(harnessInferLanguage(forPath: "change.diff"), .diff)
  }

  func testInferLanguageFilenameSpecialCases() {
    XCTAssertEqual(harnessInferLanguage(forPath: "Dockerfile"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "path/to/Dockerfile"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "Makefile"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "package.json"), .json)
    XCTAssertEqual(harnessInferLanguage(forPath: "package-lock.json"), .json)
    XCTAssertEqual(harnessInferLanguage(forPath: "tsconfig.json"), .json)
  }

  func testInferLanguageUnknownExtensionFallsBackToGeneric() {
    XCTAssertEqual(harnessInferLanguage(forPath: "path/to/binary.exe"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "LICENSE"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "path/no-extension"), .generic)
  }

  // MARK: - Image MIME inference

  func testImageMimeRecognisesSupportedExtensions() {
    XCTAssertEqual(harnessImageMime(forPath: "docs/logo.png"), .png)
    XCTAssertEqual(harnessImageMime(forPath: "photo.jpg"), .jpeg)
    XCTAssertEqual(harnessImageMime(forPath: "photo.jpeg"), .jpeg)
    XCTAssertEqual(harnessImageMime(forPath: "anim.gif"), .gif)
    XCTAssertEqual(harnessImageMime(forPath: "vector.svg"), .svg)
  }

  func testImageMimeCaseInsensitive() {
    XCTAssertEqual(harnessImageMime(forPath: "LOGO.PNG"), .png)
  }

  func testImageMimeReturnsNilForNonImage() {
    XCTAssertNil(harnessImageMime(forPath: "src/lib.rs"))
    XCTAssertNil(harnessImageMime(forPath: "doc.pdf"))
    XCTAssertNil(harnessImageMime(forPath: "no-extension"))
  }

  func testIsImagePathConvenience() {
    XCTAssertTrue(harnessIsImagePath("docs/logo.png"))
    XCTAssertFalse(harnessIsImagePath("src/lib.rs"))
  }

  func testMimeTypeIanaStrings() {
    XCTAssertEqual(HarnessDependencyImageMime.png.ianaString, "image/png")
    XCTAssertEqual(HarnessDependencyImageMime.jpeg.ianaString, "image/jpeg")
    XCTAssertEqual(HarnessDependencyImageMime.gif.ianaString, "image/gif")
    XCTAssertEqual(HarnessDependencyImageMime.svg.ianaString, "image/svg+xml")
  }

  // MARK: - Generated-path detection

  func testGeneratedPathDetectionMatchesAnyPattern() throws {
    let lockfile = try NSRegularExpression(pattern: "package-lock\\.json$")
    let dist = try NSRegularExpression(pattern: "^dist/")
    let patterns = [lockfile, dist]
    XCTAssertTrue(
      harnessIsGeneratedPath("app/package-lock.json", patterns: patterns)
    )
    XCTAssertTrue(
      harnessIsGeneratedPath("dist/bundle.js", patterns: patterns)
    )
    XCTAssertFalse(
      harnessIsGeneratedPath("src/lib.rs", patterns: patterns)
    )
  }

  func testGeneratedPathEmptyPatternsAlwaysFalse() {
    XCTAssertFalse(
      harnessIsGeneratedPath("anything", patterns: [])
    )
  }

  // MARK: - JSON round-trip parity with daemon

  func testFilesListResponseRoundTrips() throws {
    let response = DependencyUpdatesFilesListResponse(
      pullRequestID: "PR_kwDOABC",
      headRefOid: "abc123",
      viewerCanMarkViewed: true,
      files: [
        DependencyUpdateFile(
          path: "src/lib.rs",
          changeType: .modified,
          additions: 12,
          deletions: 3,
          languageHint: .rust
        )
      ],
      fetchedAt: "2026-05-22T10:00:00Z",
      rateLimitSnapshot: DependencyUpdatesRateLimitSnapshot(
        remaining: 4998,
        limit: 5000,
        resetAt: "2026-05-22T11:00:00Z",
        cost: 1
      )
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      DependencyUpdatesFilesListResponse.self, from: data)
    XCTAssertEqual(parsed.pullRequestID, response.pullRequestID)
    XCTAssertEqual(parsed.headRefOid, response.headRefOid)
    XCTAssertEqual(parsed.files.count, 1)
    XCTAssertEqual(parsed.files[0].languageHint, .rust)
    XCTAssertEqual(parsed.rateLimitSnapshot?.remaining, 4998)
  }

  func testFilesListResponseDecodesSnakeCaseFromDaemon() throws {
    // Daemon emits snake_case keys; the Swift types use camelCase. JSON
    // round-trip should accept the daemon's wire format directly because
    // the CodingKeys mirror the Rust serde names.
    let json = """
      {
        "pullRequestId": "PR_1",
        "headRefOid": "abc",
        "viewerCanMarkViewed": true,
        "files": [
          {
            "path": "src/lib.rs",
            "previousPath": null,
            "changeType": "modified",
            "additions": 1,
            "deletions": 1,
            "viewerViewedState": "unviewed",
            "isBinary": false,
            "languageHint": "rust",
            "modeChange": null
          }
        ],
        "fetchedAt": "2026-05-22T10:00:00Z"
      }
      """
    let data = Data(json.utf8)
    let parsed = try JSONDecoder().decode(
      DependencyUpdatesFilesListResponse.self, from: data)
    XCTAssertEqual(parsed.files.count, 1)
    XCTAssertEqual(parsed.files[0].changeType, .modified)
    XCTAssertEqual(parsed.files[0].viewerViewedState, .unviewed)
    XCTAssertEqual(parsed.files[0].languageHint, .rust)
    XCTAssertNil(parsed.rateLimitSnapshot)
  }

  func testFilesPatchResponseRoundTrips() throws {
    let response = DependencyUpdatesFilesPatchResponse(
      pullRequestID: "PR_1",
      patches: [
        DependencyUpdateFilePatch(
          path: "src/lib.rs",
          patch: "@@ -1 +1 @@\n-a\n+b",
          status: .modified,
          additions: 1,
          deletions: 1,
          servedBy: .localClone,
          fetchedAt: "2026-05-22T10:00:00Z",
          headRefOid: "abc"
        )
      ],
      drifted: false,
      currentHeadRefOid: "abc",
      fetchedAt: "2026-05-22T10:00:00Z"
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      DependencyUpdatesFilesPatchResponse.self, from: data)
    XCTAssertEqual(parsed.patches[0].servedBy, .localClone)
    XCTAssertFalse(parsed.drifted)
  }

  func testFilesViewedRoundTrips() throws {
    let request = DependencyUpdatesFilesViewedRequest(
      pullRequestID: "PR_1",
      paths: [
        DependencyUpdateFilesViewedTarget(
          path: "src/lib.rs",
          expectedPriorState: .unviewed,
          markViewed: true
        )
      ]
    )
    let data = try JSONEncoder().encode(request)
    let parsed = try JSONDecoder().decode(
      DependencyUpdatesFilesViewedRequest.self, from: data)
    XCTAssertEqual(parsed.paths.count, 1)
    XCTAssertEqual(parsed.paths[0].expectedPriorState, .unviewed)
    XCTAssertTrue(parsed.paths[0].markViewed)
  }

  func testFilesBlobResponseRoundTrips() throws {
    let response = DependencyUpdatesFilesBlobResponse(
      path: "logo.png",
      oid: "abc",
      mime: .png,
      contentBase64: "iVBORw0KGgoAAAA=",
      byteSize: 12,
      fetchedAt: "2026-05-22T10:00:00Z"
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      DependencyUpdatesFilesBlobResponse.self, from: data)
    XCTAssertEqual(parsed.mime, .png)
    XCTAssertEqual(parsed.byteSize, 12)
    XCTAssertFalse(parsed.isTooLarge)
  }

  func testFilesLargeDiffStrategyMatchesDaemonEncoding() throws {
    let json = "\"auto_local_clone\""
    let parsed = try JSONDecoder().decode(
      FilesLargeDiffStrategy.self, from: Data(json.utf8))
    XCTAssertEqual(parsed, .autoLocalClone)
    let encoded = try JSONEncoder().encode(FilesLargeDiffStrategy.forceGitHubRest)
    XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"force_git_hub_rest\"")
  }

  func testServedByValueRoundTripsSnakeCase() throws {
    let encoded = try JSONEncoder().encode(DependencyUpdateFileServedBy.githubRestFallback)
    XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"github_rest_fallback\"")
  }
}
