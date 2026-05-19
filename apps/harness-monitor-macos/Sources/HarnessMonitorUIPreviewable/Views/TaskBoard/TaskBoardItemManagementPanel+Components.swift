import AppKit
import HarnessMonitorKit
import SwiftUI

private struct TaskBoardManagementFieldChrome: ViewModifier {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var cornerRadius: CGFloat { 8 }

  private var fillColor: Color {
    let base = Color(nsColor: .textBackgroundColor)
    return reduceTransparency ? base : base.opacity(0.42)
  }

  private var strokeColor: Color {
    let opacity = colorSchemeContrast == .increased ? 0.9 : 0.72
    return Color(nsColor: .separatorColor).opacity(opacity)
  }

  private var lineWidth: CGFloat {
    colorSchemeContrast == .increased ? 2 : 1
  }

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(fillColor)
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: lineWidth)
      }
    }
}

extension View {
  func taskBoardManagementFieldChrome() -> some View {
    modifier(TaskBoardManagementFieldChrome())
  }
}

struct TaskBoardManagementNativeField: View {
  let label: String
  @Binding var text: String
  @Environment(\.fontScale)
  private var fontScale

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorInlineTextField(
        title: label,
        text: $text,
        prompt: label,
        accessibilityIdentifier: nil,
        fieldAlignment: .leading,
        textAlignment: .leading,
        showsClearButton: false
      )
    }
  }
}

struct TaskBoardManagementReadOnlyField: View {
  let label: String
  let value: String
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }
  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .font(captionFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
  }
}

struct TaskBoardManagementPickerField<
  Value: CaseIterable & Hashable & Identifiable & TitledTaskBoardValue
>: View where Value.AllCases: RandomAccessCollection {
  let label: String
  @Binding var selection: Value
  let values: Value.AllCases
  @Environment(\.fontScale)
  private var fontScale

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker(label, selection: $selection) {
        ForEach(values) { value in
          Text(value.title).tag(value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .harnessNativeFormControl()
    }
  }
}

struct TaskBoardManagementMultilineField: View {
  let label: String
  @Binding var text: String
  let minHeight: CGFloat
  let accessibilityIdentifier: String?
  @Environment(\.fontScale)
  private var fontScale

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorInlineMultilineTextField(
        title: label,
        text: $text,
        prompt: label,
        accessibilityIdentifier: accessibilityIdentifier,
        minHeight: minHeight,
        maxHeight: minHeight
      )
    }
  }
}

struct TaskBoardManagementPill: View {
  let label: String
  let tint: Color
  let verticalPadding: CGFloat
  @Environment(\.fontScale)
  private var fontScale

  private var pillFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption2.weight(.bold), by: fontScale)
  }

  var body: some View {
    Text(label)
      .font(pillFont)
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, verticalPadding)
      .background(tint.opacity(0.12), in: .capsule)
  }
}
