import HarnessMonitorKit
import SwiftUI

struct InspectorFact: Identifiable {
  let title: String
  let value: String
  var id: String { title }
}

struct InspectorFactGrid: View {
  let facts: [InspectorFact]

  var body: some View {
    HarnessMonitorAdaptiveGridLayout(
      minimumColumnWidth: 132,
      maximumColumns: 2,
      spacing: HarnessMonitorTheme.itemSpacing
    ) {
      ForEach(facts) { fact in
        VStack(alignment: .leading, spacing: 4) {
          Text(fact.title.uppercased())
            .scaledFont(.caption2.weight(.bold))
            .tracking(HarnessMonitorTheme.uppercaseTracking)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .harnessCellPadding()
      }
    }
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content
    }
  }
}

struct InspectorBadgeColumn: View {
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .scaledFont(.caption.weight(.semibold))
          .harnessPillPadding()
          .harnessContentPill()
      }
    }
  }
}

extension JSONValue {
  private static let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  func prettyPrintedJSONString() -> String {
    guard let data = try? Self.prettyEncoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return string
  }
}
