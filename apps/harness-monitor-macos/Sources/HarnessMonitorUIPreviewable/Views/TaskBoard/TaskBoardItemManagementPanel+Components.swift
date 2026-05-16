import HarnessMonitorKit
import SwiftUI

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
      TextField(label, text: $text)
        .harnessNativeTextField()
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
      .harnessNativeFormControl()
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
