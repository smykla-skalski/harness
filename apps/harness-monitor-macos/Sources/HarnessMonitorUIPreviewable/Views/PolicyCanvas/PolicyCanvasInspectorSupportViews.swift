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
        .foregroundStyle(.white.opacity(0.82))
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
      // P29 contrast: white at 0.78 reads ~5.6:1 on the inspector `#14171F`
      // background and clears WCAG AA for small body text; 0.70 (~4.4:1)
      // was below the per-Wave-3G contrast bar.
      Text(label)
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.78))
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
        // P29 contrast bump (0.70 -> 0.78) matches the field-label rule above.
        .foregroundStyle(.white.opacity(0.78))
        .frame(width: 68, alignment: .leading)

      Text(value)
        .scaledFont(.caption.weight(.medium))
        // Primary value text on the inspector card stays at 0.92 to keep
        // emphasis between label and value while clearing the AA bar.
        .foregroundStyle(.white.opacity(0.92))
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
