import HarnessMonitorKit
import SwiftUI

/// Shown when the Monitor connects to a different daemon and secrets can carry
/// over from the previous one. Conflicts (the new daemon already holds a
/// differing value) get a keep-or-carry-over choice; the rest get a carry-over
/// switch that is on by default. Nothing is written until the user applies.
struct SecretMigrationConsentSheet: View {
  let store: HarnessMonitorStore
  let items: [TaskBoardSecretMigrationItem]

  @State private var carry: TaskBoardSecretMigrationSelections
  private let conflictCount: Int

  init(store: HarnessMonitorStore, items: [TaskBoardSecretMigrationItem]) {
    self.store = store
    self.items = items
    var initial: TaskBoardSecretMigrationSelections = [:]
    for item in items {
      initial[item.kind] = item.disposition == .carryOver
    }
    _carry = State(initialValue: initial)
    conflictCount = items.filter { $0.disposition == .conflict }.count
  }

  private var hasConflict: Bool { conflictCount > 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 8) {
          ForEach(items) { item in
            row(for: item)
          }
        }
      }
      .frame(maxHeight: 460)
      // Hug the rows when they are short so no empty space sits below the last
      // one; only grow to the cap and scroll once the list is long.
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      footer
    }
    .padding(20)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Carry secrets over?")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(
        "Carry these over from your previous daemon; turn off any to skip, "
          + "and flagged ones already have a value here"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  private func row(for item: TaskBoardSecretMigrationItem) -> some View {
    HStack(spacing: 12) {
      // The flag column exists only when some row is a conflict, so those rows
      // can align with the plain ones. With no conflicts the column is dropped
      // entirely and titles start at the leading edge.
      if hasConflict {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .frame(width: 18)
          .opacity(item.disposition == .conflict ? 1 : 0)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.body)
        Text(item.scopeLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      control(for: item)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func control(for item: TaskBoardSecretMigrationItem) -> some View {
    let binding = Binding(
      get: { carry[item.kind] ?? (item.disposition == .carryOver) },
      set: { carry[item.kind] = $0 }
    )
    switch item.disposition {
    case .conflict:
      Picker("", selection: binding) {
        Text("Keep").tag(false)
        Text("Carry over").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // Identical labels give every conflict row the same intrinsic width, so
      // the controls line up while never clipping at larger text sizes.
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityLabel(Text("\(item.title), \(item.scopeLabel)"))
    case .carryOver:
      Toggle("", isOn: binding)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(Text("Carry over \(item.title), \(item.scopeLabel)"))
    }
  }

  private var footer: some View {
    HStack {
      Text(summaryText)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel") { store.resolveSecretMigrationConsent(nil) }
        .keyboardShortcut(.cancelAction)
      Button("Apply") { store.resolveSecretMigrationConsent(selections) }
        .keyboardShortcut(.defaultAction)
    }
  }

  private var summaryText: String {
    if conflictCount > 0 {
      return conflictCount == 1 ? "1 conflict" : "\(conflictCount) conflicts"
    }
    return items.count == 1 ? "1 secret" : "\(items.count) secrets"
  }

  private var selections: TaskBoardSecretMigrationSelections {
    var map: TaskBoardSecretMigrationSelections = [:]
    for item in items {
      map[item.kind] = carry[item.kind] ?? (item.disposition == .carryOver)
    }
    return map
  }
}
