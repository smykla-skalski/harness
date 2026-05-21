import HarnessMonitorKit
import SwiftUI

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
  return candidateNames
    .subtracting(appliedEverywhere)
    .compactMap { labelByName[$0] }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

@MainActor
struct DashboardDependenciesLabelPickerMenu: View {
  let title: String
  let labels: [DependencyUpdateRepositoryLabel]
  let onSelect: (String) -> Void
  let onCustom: () -> Void

  var body: some View {
    Menu(title) {
      menuContent
    }
  }

  @ViewBuilder
  private var menuContent: some View {
    if labels.isEmpty {
      Button("No labels available") {}
        .disabled(true)
    } else {
      ForEach(labels) { label in
        Button {
          onSelect(label.name)
        } label: {
          DashboardDependenciesLabelMenuRow(label: label)
        }
      }
    }
    Divider()
    Button("Custom Label…") {
      onCustom()
    }
  }
}

@MainActor
struct DashboardDependenciesLabelPickerActionMenu: View {
  let labels: [DependencyUpdateRepositoryLabel]
  let onSelect: (String) -> Void
  let onCustom: () -> Void

  var body: some View {
    Menu {
      if labels.isEmpty {
        Button("No labels available") {}
          .disabled(true)
      } else {
        ForEach(labels) { label in
          Button {
            onSelect(label.name)
          } label: {
            DashboardDependenciesLabelMenuRow(label: label)
          }
        }
      }
      Divider()
      Button("Custom Label…") {
        onCustom()
      }
    } label: {
      Label("Add Label", systemImage: "tag")
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
  }
}

@MainActor
private struct DashboardDependenciesLabelMenuRow: View {
  let label: DependencyUpdateRepositoryLabel

  var body: some View {
    if let description = label.description, !description.isEmpty {
      Text("\(label.name) — \(description)")
    } else {
      Text(label.name)
    }
  }
}
