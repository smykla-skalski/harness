import HarnessMonitorKit
import SwiftUI

struct TaskBoardManagementNativeField: View {
  let label: String
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      TextField(label, text: $text)
        .harnessNativeTextField()
    }
  }
}

struct TaskBoardManagementReadOnlyField: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .scaledFont(.caption)
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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(label)
        .scaledFont(.caption.weight(.semibold))
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

  var body: some View {
    Text(label)
      .scaledFont(.caption2.weight(.bold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, verticalPadding)
      .background(tint.opacity(0.12), in: .capsule)
  }
}
