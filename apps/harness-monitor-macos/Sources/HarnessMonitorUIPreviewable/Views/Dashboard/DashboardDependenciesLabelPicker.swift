import HarnessMonitorKit
import SwiftUI

/// Parse a GitHub label hex string (`"rrggbb"`, with or without leading `#`)
/// into a SwiftUI `Color`. Returns `nil` for unparseable input so callers can
/// fall back to a neutral swatch.
func dashboardDependenciesLabelSwatchColor(_ hex: String?) -> Color? {
  guard let hex else { return nil }
  let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
  guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
  let red = Double((value >> 16) & 0xFF) / 255.0
  let green = Double((value >> 8) & 0xFF) / 255.0
  let blue = Double(value & 0xFF) / 255.0
  return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
}

@MainActor
func dashboardDependenciesAvailableLabels(
  repositoryLabels: [String: [DependencyUpdateRepositoryLabel]],
  items: [DependencyUpdateItem]
) -> [DependencyUpdateRepositoryLabel] {
  guard !items.isEmpty else { return [] }
  let repositories = Set(items.map { $0.repository })
  var nameIntersection: Set<String>?
  var labelByName: [String: DependencyUpdateRepositoryLabel] = [:]
  for repository in repositories {
    let labels = repositoryLabels[repository] ?? []
    let names = Set(labels.map { $0.name })
    if let current = nameIntersection {
      nameIntersection = current.intersection(names)
    } else {
      nameIntersection = names
    }
    for label in labels where labelByName[label.name] == nil {
      labelByName[label.name] = label
    }
  }
  guard let candidateNames = nameIntersection, !candidateNames.isEmpty else { return [] }
  var appliedEverywhere: Set<String> = []
  var firstApplied = true
  for item in items {
    let applied = Set(item.labels)
    appliedEverywhere = firstApplied ? applied : appliedEverywhere.intersection(applied)
    firstApplied = false
  }

  return
    candidateNames
    .subtracting(appliedEverywhere)
    .compactMap { labelByName[$0] }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Split `available` into a (frequent, rest) pair given `frequentNames` order.
/// Frequent labels keep `frequentNames` ordering; the rest stays in `available`
/// ordering (already alphabetical from `dashboardDependenciesAvailableLabels`).
@MainActor
func dashboardDependenciesPartitionFrequent(
  available: [DependencyUpdateRepositoryLabel],
  frequentNames: [String]
) -> (frequent: [DependencyUpdateRepositoryLabel], rest: [DependencyUpdateRepositoryLabel]) {
  guard !frequentNames.isEmpty else { return ([], available) }
  let labelByName = Dictionary(uniqueKeysWithValues: available.map { ($0.name, $0) })
  var frequent: [DependencyUpdateRepositoryLabel] = []
  var seen: Set<String> = []
  for name in frequentNames {
    guard let label = labelByName[name], seen.insert(name).inserted else { continue }
    frequent.append(label)
  }
  let rest = available.filter { !seen.contains($0.name) }
  return (frequent, rest)
}

@MainActor
struct DashboardDependenciesLabelPickerMenu: View {
  let title: String
  let labels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let onSelect: (String) -> Void
  let onCustom: () -> Void

  var body: some View {
    Menu(title) {
      DashboardDependenciesLabelMenuContent(
        labels: labels,
        frequentNames: frequentNames,
        showsDescriptions: showsDescriptions,
        onSelect: onSelect,
        onCustom: onCustom
      )
    }
  }
}

@MainActor
struct DashboardDependenciesLabelPickerActionMenu: View {
  let labels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let onSelect: (String) -> Void
  let onCustom: () -> Void

  var body: some View {
    Menu {
      DashboardDependenciesLabelMenuContent(
        labels: labels,
        frequentNames: frequentNames,
        showsDescriptions: showsDescriptions,
        onSelect: onSelect,
        onCustom: onCustom
      )
    } label: {
      Label("Add Label", systemImage: "tag")
        .lineLimit(1)
    }
    .menuStyle(.button)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
  }
}

@MainActor
private struct DashboardDependenciesLabelMenuContent: View {
  let labels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let onSelect: (String) -> Void
  let onCustom: () -> Void

  var body: some View {
    if labels.isEmpty {
      Button("No labels available") {}
        .disabled(true)
    } else {
      let split = dashboardDependenciesPartitionFrequent(
        available: labels,
        frequentNames: frequentNames
      )
      if !split.frequent.isEmpty {
        Section("Frequently Used") {
          ForEach(split.frequent) { label in
            labelButton(for: label)
          }
        }
        Section("All Labels") {
          ForEach(split.rest) { label in
            labelButton(for: label)
          }
        }
      } else {
        ForEach(split.rest) { label in
          labelButton(for: label)
        }
      }
    }
    Divider()
    Button("Custom Label…") {
      onCustom()
    }
  }

  private func labelButton(for label: DependencyUpdateRepositoryLabel) -> some View {
    Button {
      onSelect(label.name)
    } label: {
      DashboardDependenciesLabelMenuRow(
        label: label,
        showsDescription: showsDescriptions
      )
    }
  }
}

@MainActor
private struct DashboardDependenciesLabelMenuRow: View {
  let label: DependencyUpdateRepositoryLabel
  let showsDescription: Bool

  var body: some View {
    Label {
      if showsDescription, let description = label.description, !description.isEmpty {
        Text("\(label.name) — \(description)")
      } else {
        Text(label.name)
      }
    } icon: {
      Image(systemName: "circle.fill")
        .foregroundStyle(swatch)
    }
  }

  private var swatch: Color {
    dashboardDependenciesLabelSwatchColor(label.color)
      ?? HarnessMonitorTheme.secondaryInk.opacity(0.5)
  }
}
