import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness code highlight latency proofs")
struct HarnessCodeHighlightLatencyProofTests {
  @Test(
    "shared code highlight and render stay within budget",
    arguments: HarnessCodeHighlightBenchmarkCorpus.latencyCases
  )
  func sharedCodeHighlightAndRenderStayWithinBudget(sample: HarnessCodeHighlightLatencyCase) {
    let result = HarnessCodeHighlightPerformanceProbe.measure(
      surface: sample.surface,
      source: sample.source,
      language: sample.language
    )

    #expect(result.byteCount == sample.source.utf8.count)
    #expect(result.spanCount > 0)
    #expect(result.highlightMilliseconds < sample.highlightBudgetMilliseconds)
    #expect(result.renderMilliseconds < sample.renderBudgetMilliseconds)
  }

  @Test("benchmark corpus covers current scanner families")
  func benchmarkCorpusCoversCurrentScannerFamilies() {
    let languages = Set(HarnessCodeHighlightBenchmarkCorpus.latencyCases.map(\.language))
    #expect(languages.contains(.swift))
    #expect(languages.contains(.typescript))
    #expect(languages.contains(.json))
    #expect(languages.contains(.yaml))
    #expect(languages.contains(.feature))
    #expect(languages.contains(.codeowners))
    #expect(languages.contains(.template))
    #expect(languages.contains(.vue))
  }
}

struct HarnessCodeHighlightLatencyCase: CustomStringConvertible, Sendable {
  let surface: String
  let language: HarnessCodeLanguage
  let source: String
  let highlightBudgetMilliseconds: Double
  let renderBudgetMilliseconds: Double

  var description: String { surface }
}

enum HarnessCodeHighlightBenchmarkCorpus {
  static let latencyCases: [HarnessCodeHighlightLatencyCase] = [
    .init(
      surface: "markdown.swift.large",
      language: .swift,
      source: swiftSource(typeCount: 140),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "markdown.typescript.large",
      language: .typescript,
      source: typescriptSource(typeCount: 160),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "json.payload.large",
      language: .json,
      source: jsonSource(entryCount: 180),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "config.yaml.large",
      language: .yaml,
      source: yamlSource(entryCount: 280),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "feature.outline.large",
      language: .feature,
      source: featureSource(scenarioCount: 70),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "codeowners.large",
      language: .codeowners,
      source: codeownersSource(entryCount: 260),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "template.large",
      language: .template,
      source: templateSource(blockCount: 220),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
    .init(
      surface: "vue.component.large",
      language: .vue,
      source: vueSource(componentCount: 90),
      highlightBudgetMilliseconds: 80,
      renderBudgetMilliseconds: 80
    ),
  ]

  private static func swiftSource(typeCount: Int) -> String {
    var lines = [
      "import Foundation",
      "",
      "enum RuntimeError: Error {",
      "  case invalidState",
      "}",
      "",
    ]
    for index in 0..<typeCount {
      lines.append("struct Item\(index) {")
      lines.append("  let id: Int")
      lines.append("  let name: String")
      lines.append("  let enabled: Bool")
      lines.append("}")
      lines.append("")
      lines.append("func buildItem\(index)(seed: Int) throws -> Item\(index) {")
      lines.append("  let name = \"item-\\(seed)-\(index)\"")
      lines.append("  guard seed >= 0 else {")
      lines.append("    throw RuntimeError.invalidState")
      lines.append("  }")
      lines.append("  return Item\(index)(id: seed, name: name, enabled: seed.isMultiple(of: 2))")
      lines.append("}")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private static func typescriptSource(typeCount: Int) -> String {
    var lines = [
      "type RecordState = 'ready' | 'running' | 'failed'",
      "",
    ]
    for index in 0..<typeCount {
      lines.append("interface Item\(index) {")
      lines.append("  id: number")
      lines.append("  name: string")
      lines.append("  state: RecordState")
      lines.append("}")
      lines.append("")
      lines.append("export async function buildItem\(index)(seed: number): Promise<Item\(index)> {")
      lines.append("  const name = `item-${seed}-\(index)`")
      lines.append("  return { id: seed, name, state: seed % 2 === 0 ? 'ready' : 'running' }")
      lines.append("}")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private static func jsonSource(entryCount: Int) -> String {
    let entries = (0..<entryCount).map { index in
      """
        {
          "id" : \(index),
          "name" : "record-\(index)",
          "enabled" : \(index.isMultiple(of: 2) ? "true" : "false"),
          "path" : "/tmp/item/\(index)"
        }
      """
    }
    return """
      {
        "items" : [
      \(entries.joined(separator: ",\n"))
        ]
      }
      """
  }

  private static func yamlSource(entryCount: Int) -> String {
    var lines = ["records:"]
    for index in 0..<entryCount {
      lines.append("  record_\(index):")
      lines.append("    enabled: \(index.isMultiple(of: 2) ? "true" : "false")")
      lines.append("    retries: \(index % 5)")
      lines.append("    owner: user-\(index)")
    }
    lines.append("# end of corpus")
    return lines.joined(separator: "\n")
  }

  private static func featureSource(scenarioCount: Int) -> String {
    var lines = [
      "@smoke @latency",
      "Feature: Shared code highlight benchmarks",
      "",
    ]
    for index in 0..<scenarioCount {
      lines.append("  Scenario Outline: render highlighted rows \(index)")
      lines.append("    Given a repository has <count> modified files")
      lines.append("    And a user opens the Reviews files route")
      lines.append("    Then the rendered surface stays responsive")
      lines.append("    Examples:")
      lines.append("      | count |")
      lines.append("      | \(index + 1) |")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private static func codeownersSource(entryCount: Int) -> String {
    var lines = ["# syntax highlight benchmark corpus"]
    for index in 0..<entryCount {
      lines.append("apps/feature\(index)/** @ios-team @reviewer-\(index)")
    }
    return lines.joined(separator: "\n")
  }

  private static func templateSource(blockCount: Int) -> String {
    var lines: [String] = []
    for index in 0..<blockCount {
      lines.append("{{- if .Values.service\(index).enabled -}}")
      lines.append("apiVersion: v1")
      lines.append("kind: ConfigMap")
      lines.append("metadata:")
      lines.append("  name: {{ .Values.service\(index).name }}")
      lines.append("{{- end -}}")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private static func vueSource(componentCount: Int) -> String {
    var sections: [String] = []
    for index in 0..<componentCount {
      sections.append(
        """
        <template>
          <CardRow :title="title\(index)" :count="count\(index)">
            {{ count\(index) }}
          </CardRow>
        </template>
        <script setup lang="ts">
        const title\(index) = `row-\(index)`
        const count\(index) = \(index)
        </script>
        <style scoped>
        .row-\(index) { color: #\(String(format: "%06X", index % 0xFFFFFF)); }
        </style>
        """
      )
    }
    return sections.joined(separator: "\n")
  }
}
