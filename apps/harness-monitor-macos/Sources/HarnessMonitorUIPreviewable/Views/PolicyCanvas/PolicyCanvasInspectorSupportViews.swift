import HarnessMonitorKit
import SwiftUI

struct PolicyCanvasInspectorSection<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.54))
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: 8) {
        content
      }
      .padding(10)
      .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(.white.opacity(0.08), lineWidth: 1)
      }
    }
  }
}

struct PolicyCanvasInspectorField<Content: View>: View {
  let label: String
  let content: Content

  init(label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.48))
      content
    }
  }
}

struct PolicyCanvasInspectorRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.48))
        .frame(width: 68, alignment: .leading)

      Text(value)
        .scaledFont(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.86))
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension TaskBoardPolicyAction {
  var policyCanvasTitle: String {
    rawValue.replacingOccurrences(of: "_", with: " ")
  }
}

extension TaskBoardPolicyEvidenceField {
  var policyCanvasTitle: String {
    rawValue.replacingOccurrences(of: "_", with: " ")
  }
}
