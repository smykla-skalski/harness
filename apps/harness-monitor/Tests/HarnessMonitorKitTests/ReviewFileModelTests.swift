import Foundation
import XCTest

@testable import HarnessMonitorKit

/// Parity tests for the Swift mirrors of the daemon's files-section types.
/// Asserts on the truth-table inference helpers + JSON round-trip with the
/// daemon's snake_case-encoded shapes.
final class ReviewFileModelTests: XCTestCase {

  // MARK: - Language inference parity

  func testInferLanguageSwiftExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "apps/Foo.swift"), .swift)
  }

  func testInferLanguageRustExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "src/lib.rs"), .rust)
  }

  func testInferLanguageGoExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "cmd/main.go"), .go)
  }

  func testInferLanguageJavaScriptExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.js"), .javascript)
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.jsx"), .javascript)
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.mjs"), .javascript)
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.cjs"), .javascript)
  }

  func testInferLanguageTypeScriptExtensions() {
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.ts"), .typescript)
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.tsx"), .typescript)
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.mts"), .typescript)
    XCTAssertEqual(harnessInferLanguage(forPath: "web/app.cts"), .typescript)
  }

  func testInferLanguageVueExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "web/App.vue"), .vue)
  }

  func testInferLanguageFeatureExtension() {
    XCTAssertEqual(harnessInferLanguage(forPath: "features/search.feature"), .feature)
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
    XCTAssertEqual(harnessInferLanguage(forPath: "Dockerfile"), .dockerfile)
    XCTAssertEqual(harnessInferLanguage(forPath: "path/to/Dockerfile"), .dockerfile)
    XCTAssertEqual(harnessInferLanguage(forPath: "Makefile"), .makefile)
    XCTAssertEqual(harnessInferLanguage(forPath: "package.json"), .json)
    XCTAssertEqual(harnessInferLanguage(forPath: "package-lock.json"), .json)
    XCTAssertEqual(harnessInferLanguage(forPath: "tsconfig.json"), .json)
  }

  func testInferLanguageAdditionalFiletypeFamilies() {
    let cases: [(String, HarnessReviewFileLanguage)] = [
      (".gitignore", .gitignore),
      (".editorconfig", .config),
      (".github/CODEOWNERS", .codeowners),
      ("vendor/go.mod", .goModule),
      ("vendor/go.sum", .goModule),
      ("kuma.Dockerfile", .dockerfile),
      ("Dockerfile.ubi-kuma-cp", .dockerfile),
      ("chart/templates/_helpers.tpl", .template),
      ("infra/main.tf", .terraform),
      ("infra/terraform.tfvars", .terraform),
      ("infra/.tflint.hcl", .terraform),
      ("config/mise.toml", .toml),
      ("public/index.html", .html),
      ("public/sitemap.xml", .xml),
      ("styles/app.scss", .stylesheet),
      ("Dockerfile.dockerignore", .gitignore),
      ("Gemfile", .ruby),
      ("Gemfile.lock", .ruby),
      ("Rakefile", .ruby),
      ("script.py", .python),
      ("policy.rego", .rego),
      ("schema.proto", .proto),
      ("init.lua", .lua),
      ("query.sql", .sql),
      ("Procfile", .config),
      ("app/.nvmrc", .config),
      ("service/kuma-cp.service", .config),
    ]
    for (path, expected) in cases {
      XCTAssertEqual(harnessInferLanguage(forPath: path), expected, "path: \(path)")
    }
  }

  func testInferLanguageUnknownExtensionFallsBackToGeneric() {
    XCTAssertEqual(harnessInferLanguage(forPath: "path/to/binary.exe"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "LICENSE"), .generic)
    XCTAssertEqual(harnessInferLanguage(forPath: "Cargo.lock"), .generic)
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

  func testPathMetadataHelpersAvoidSplitArrays() throws {
    let source = try String(
      contentsOf: Self.sourceRoot.appendingPathComponent(
        "Sources/HarnessMonitorKit/Models/ReviewFile+Helpers.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("lastIndex(of: \"/\")"))
    XCTAssertTrue(source.contains("lastIndex(of: \".\")"))
    XCTAssertFalse(source.contains("lower.split(separator: \"/\")"))
    XCTAssertFalse(source.contains("lower.split(separator: \".\")"))
  }

  func testMimeTypeIanaStrings() {
    XCTAssertEqual(HarnessReviewImageMime.png.ianaString, "image/png")
    XCTAssertEqual(HarnessReviewImageMime.jpeg.ianaString, "image/jpeg")
    XCTAssertEqual(HarnessReviewImageMime.gif.ianaString, "image/gif")
    XCTAssertEqual(HarnessReviewImageMime.svg.ianaString, "image/svg+xml")
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

  static let sourceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
