import HarnessMonitorKit
import SwiftUI

/// Sits beside the lane colors, but the two are not the same kind of setting.
/// A lane color is this machine's preference and lives in `UserDefaults`; a
/// project color is part of the project, so it goes to the daemon and every
/// machine reading that daemon sees it.
struct SettingsTaskBoardProjectAppearanceSection: View {
  let store: HarnessMonitorStore
  @State private var presentedProjectID: String?

  private var projects: [TaskBoardProjectSummary] {
    store.globalTaskBoardProjects ?? []
  }

  var body: some View {
    Section {
      if projects.isEmpty {
        Text("No projects yet. One is registered as soon as a repository is added or work arrives.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        ForEach(projects) { project in
          projectRow(project)
        }
      }
    } header: {
      Text("Project Colors")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Cards carry this mark next to the project name. Colors are stored with the project.")
        .harnessNativeFormSectionFooter()
    }
    .task {
      guard store.globalTaskBoardProjects == nil else { return }
      await store.refreshTaskBoardProjects()
    }
  }

  private func projectRow(_ project: TaskBoardProjectSummary) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      // Same pairing as the card footer: the mark sits on the name's baseline
      // rather than beside it on a guide of its own.
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardProjectMark(
          style: TaskBoardProjectMarkStyle(color: project.color, shape: project.shape),
          alignsWith: .body
        )

        Text(project.label)
          .scaledFont(.body.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: HarnessMonitorTheme.spacingMD)

      // Names the color as well as showing it, so the control is not the one
      // place on screen where colour alone carries the meaning.
      Button("\(project.color.title)…") {
        presentedProjectID = project.projectId
      }
      .help("Choose a color for \(project.label)")
      .accessibilityLabel("Choose a color for \(project.label), currently \(project.color.title)")
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .accessibilityIdentifier("harness.settings.task-board.project-color.\(project.projectId)")
    .popover(isPresented: presentedBinding(for: project), arrowEdge: .trailing) {
      SettingsTaskBoardProjectColorPopover(store: store, project: project)
    }
  }

  private func presentedBinding(for project: TaskBoardProjectSummary) -> Binding<Bool> {
    Binding(
      get: { presentedProjectID == project.projectId },
      set: { isPresented in
        if !isPresented, presentedProjectID == project.projectId {
          presentedProjectID = nil
        }
      }
    )
  }
}

private struct SettingsTaskBoardProjectColorPopover: View {
  let store: HarnessMonitorStore
  let project: TaskBoardProjectSummary

  private static let columns = Array(
    repeating: GridItem(.flexible(minimum: 44), spacing: HarnessMonitorTheme.spacingXS),
    count: 6
  )

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text(project.label)
          .scaledFont(.headline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        Button {
          submit(TaskBoardProjectUpdateRequest(projectId: project.projectId, resetColor: true))
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help("Pick a color automatically, avoiding the ones other projects hold")
      }

      LazyVGrid(
        columns: Self.columns,
        alignment: .leading,
        spacing: HarnessMonitorTheme.spacingXS
      ) {
        ForEach(TaskBoardProjectColor.allCases) { color in
          swatch(color)
        }
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(width: 320, alignment: .topLeading)
  }

  private func swatch(_ color: TaskBoardProjectColor) -> some View {
    Button {
      submit(TaskBoardProjectUpdateRequest(projectId: project.projectId, color: color))
    } label: {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(color.color)
        .frame(maxWidth: .infinity, minHeight: 34)
        .overlay {
          if color == project.color {
            Image(systemName: "checkmark")
              .scaledFont(.body.weight(.bold))
              .foregroundStyle(.white)
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
              color == project.color
                ? HarnessMonitorTheme.ink.opacity(0.55) : HarnessMonitorTheme.ink.opacity(0.18),
              lineWidth: color == project.color ? 2 : 1
            )
        }
    }
    .harnessPlainButtonStyle()
    .help(color.title)
    // The checkmark is the visible "selected", but it rides on the swatch
    // rather than beside a name, so the trait has to be set for VoiceOver.
    .accessibilityLabel(color.title)
    .accessibilityAddTraits(color == project.color ? [.isSelected] : [])
  }

  private func submit(_ request: TaskBoardProjectUpdateRequest) {
    let store = store
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Updating project color") {
        await store.updateTaskBoardProject(request: request)
      }
    )
  }
}
