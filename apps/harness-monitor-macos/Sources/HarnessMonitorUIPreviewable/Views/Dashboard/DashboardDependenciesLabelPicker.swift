import AppKit
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

/// Build a non-template `NSImage` disc swatch that survives NSMenu's
/// template-image treatment. SwiftUI `Menu` content is hosted by NSMenuItem,
/// which silently converts SF Symbols to monochrome templates and discards
/// `.foregroundStyle()`. Baking the color into an NSImage with
/// `isTemplate = false` is the only path that keeps the per-label color.
///
/// The canvas matches the standard NSMenuItem icon box (14×14) so the
/// disc lands on the text's optical centre instead of riding above the
/// cap height.
@MainActor
func dashboardDependenciesLabelSwatchImage(
  hex: String?,
  diameter: CGFloat = 10,
  canvas: CGFloat = 14
) -> Image {
  let nsColor: NSColor
  if let color = dashboardDependenciesLabelSwatchColor(hex) {
    nsColor = NSColor(color)
  } else {
    nsColor = NSColor(HarnessMonitorTheme.secondaryInk.opacity(0.5))
  }
  let size = NSSize(width: canvas, height: canvas)
  let inset = (canvas - diameter) / 2
  let image = NSImage(size: size, flipped: false) { rect in
    let discRect = rect.insetBy(dx: inset, dy: inset)
    nsColor.setFill()
    NSBezierPath(ovalIn: discRect).fill()
    return true
  }
  image.isTemplate = false
  return Image(nsImage: image)
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

/// Bucket `labels` into groups by the prefix before the first `/`. Labels
/// with no slash form the leading group; the remaining buckets follow in
/// alphabetical prefix order. Order inside each bucket is preserved from
/// `labels`, so callers should sort the input ahead of grouping.
@MainActor
func dashboardDependenciesGroupByPrefix(
  _ labels: [DependencyUpdateRepositoryLabel]
) -> [[DependencyUpdateRepositoryLabel]] {
  var unprefixed: [DependencyUpdateRepositoryLabel] = []
  var byPrefix: [String: [DependencyUpdateRepositoryLabel]] = [:]
  for label in labels {
    if let slash = label.name.firstIndex(of: "/"),
      slash != label.name.startIndex
    {
      let prefix = String(label.name[..<slash])
      byPrefix[prefix, default: []].append(label)
    } else {
      unprefixed.append(label)
    }
  }
  var groups: [[DependencyUpdateRepositoryLabel]] = []
  if !unprefixed.isEmpty {
    groups.append(unprefixed)
  }
  let sortedPrefixes = byPrefix.keys.sorted {
    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
  }
  for prefix in sortedPrefixes {
    if let group = byPrefix[prefix], !group.isEmpty {
      groups.append(group)
    }
  }
  return groups
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
      }
      let groups = dashboardDependenciesGroupByPrefix(split.rest)
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        if index > 0 || !split.frequent.isEmpty {
          Divider()
        }
        ForEach(group) { label in
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
      dashboardDependenciesLabelSwatchImage(hex: label.color)
    }
  }
}
