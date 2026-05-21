import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness markdown source contracts")
struct HarnessMarkdownSourceContractTests {
  @Test("Markdown renderer does not depend on the removed package or feature flag")
  func markdownRendererDoesNotDependOnRemovedPackageOrFeatureFlag() throws {
    let forbidden = ["Text" + "ual", "HARNESS_FEATURE_" + "TEXTUAL", "import Text" + "ual"]
    let files = [
      "apps/harness-monitor-macos/Tuist/Package.swift",
      "apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/FeatureFlags.swift",
      """
      apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Shared/\
      HarnessMonitorMarkdownText.swift
      """,
      """
      apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/\
      TaskBoardItemManagementSupport.swift
      """,
    ]

    for file in files {
      let source = try readRepositoryFile(file)
      for token in forbidden {
        #expect(!source.contains(token), "\(file) still contains \(token)")
      }
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: repositoryPath("apps/harness-monitor-macos/features/" + "text" + "ual.yml")))
  }

  @Test("Markdown parser support stays scanner-based")
  func markdownParserSupportStaysScannerBased() throws {
    let forbidden = ["Re" + "gex", "NSRegular" + "Expression", ".regular" + "Expression"]
    let supportRoot = repositoryPath(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/Markdown"
    )
    let files = try FileManager.default.contentsOfDirectory(atPath: supportRoot)
      .filter { $0.hasSuffix(".swift") }

    for file in files {
      let source = try String(contentsOfFile: supportRoot + "/" + file, encoding: .utf8)
      for token in forbidden {
        #expect(!source.contains(token), "\(file) contains scanner-forbidden token \(token)")
      }
    }
  }

  @Test("Markdown render pipeline explicitly cancels detached work")
  func markdownRenderPipelineCancelsDetachedWork() throws {
    let renderer = try readRepositoryFile(
      """
      apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Shared/\
      HarnessMonitorMarkdownText.swift
      """
    )
    let parser = try readRepositoryFile(
      """
      apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/Markdown/\
      HarnessMarkdownParser.swift
      """
    )

    #expect(renderer.contains("withTaskCancellationHandler"))
    #expect(renderer.contains("worker.cancel()"))
    #expect(parser.contains("shouldCancel"))
  }

  @Test("Markdown image flow participates in baseline alignment")
  func markdownImageFlowParticipatesInBaselineAlignment() throws {
    let source = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMarkdownInlineFlowView.swift"
    )

    #expect(source.contains(".alignmentGuide(.firstTextBaseline)"))
    #expect(source.contains("dimensions[VerticalAlignment.center]"))
  }

  private func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOfFile: repositoryPath(relativePath), encoding: .utf8)
  }

  private func repositoryPath(_ relativePath: String) -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(relativePath)
      .path
  }
}
