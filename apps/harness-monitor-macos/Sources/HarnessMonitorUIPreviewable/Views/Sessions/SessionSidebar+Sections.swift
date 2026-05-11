import HarnessMonitorKit
import SwiftUI

private enum SessionSidebarHeaderButtonCenterAlignment: AlignmentID {
  static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
    dimensions[VerticalAlignment.center]
  }
}

extension VerticalAlignment {
  static let sessionSidebarHeaderButtonCenter = VerticalAlignment(
    SessionSidebarHeaderButtonCenterAlignment.self
  )
}

enum SessionSidebarCreateButtonOverlayCoordinateSpace {
  static let name = "harness.session-sidebar-create-button-overlays"
}

struct SessionSidebarCreateButtonFramePreferenceKey: PreferenceKey {
  static let defaultValue: [SessionCreateKind: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [SessionCreateKind: Anchor<CGRect>],
    nextValue: () -> [SessionCreateKind: Anchor<CGRect>]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

private struct SessionSidebarCreateButtonFrameModifier: ViewModifier {
  let kind: SessionCreateKind

  func body(content: Content) -> some View {
    content.anchorPreference(
      key: SessionSidebarCreateButtonFramePreferenceKey.self,
      value: .bounds
    ) { anchor in
      [kind: anchor]
    }
  }
}

struct SessionSidebarCreateButtonShortcutOverlays: View {
  @ScaledMetric(relativeTo: .caption)
  private var shortcutKeySpacing = HarnessMonitorTheme.spacingXS - 1
  @ScaledMetric(relativeTo: .caption) private var shortcutVerticalOffset = 8
  @ScaledMetric(relativeTo: .caption) private var shortcutHorizontalAdjustment = 1

  let anchors: [SessionCreateKind: Anchor<CGRect>]
  let currentModifiers: EventModifiers

  private var orderedKinds: [SessionCreateKind] {
    [.agent, .task, .decision]
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        ForEach(orderedKinds, id: \.self) { kind in
          if let anchor = anchors[kind] {
            let frame = proxy[anchor]
            let shortcut = kind.createShortcut
            KeyboardShortcutLabel(
              shortcut: shortcut,
              activeModifiers: currentModifiers,
              revealPolicy: .revealOnRelevantModifierHold,
              keySpacing: shortcutKeySpacing
            )
            .fixedSize(horizontal: true, vertical: true)
            .position(
              x: frame.midX - shortcutHorizontalAdjustment,
              y: frame.minY
            )
            .offset(y: -shortcutVerticalOffset)
          }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .allowsHitTesting(false)
    .zIndex(1)
    .accessibilityHidden(true)
  }
}

extension SessionSidebar {
  private var runtimePresentation: HarnessMonitorStore.AgentRuntimePresentationContext? {
    guard let snapshot else {
      return nil
    }
    switch snapshot.source {
    case .live:
      return HarnessMonitorStore.AgentRuntimePresentationContext(
        availability: .live,
        acpSnapshots: snapshot.acpAgents,
        acpInspectSample: snapshot.acpInspectSample
      )
    case .cache:
      return HarnessMonitorStore.AgentRuntimePresentationContext(availability: .persisted)
    case .catalog:
      return nil
    }
  }

  @ViewBuilder var agentsSection: some View {
    Section {
      let orderedAgents = state.sidebarOrdering.orderedAgents(snapshot?.detail?.agents ?? [])
      let orderedAgentIDs = orderedAgents.map(\.agentId)
      ForEach(orderedAgents) { agent in
        agentRow(agent, orderedAgentIDs: orderedAgentIDs)
      }
      ForEach(sessionCodexRuns) { run in
        let selection = SessionSelection.codexRun(sessionID: state.sessionID, runID: run.runId)
        SessionSidebarRow(
          title: SessionCodexRunRowFormatter.title(for: run),
          systemImage: "wand.and.stars",
          severityShape: SessionCodexRunRowFormatter.severityShape(for: run.status),
          severityTint: SessionCodexRunRowFormatter.severityTint(for: run.status)
        )
        .tag(selection)
        .contextMenu {
          if displayedSelectionSet.count > 1, displayedSelectionSet.contains(selection) {
            Button(SessionSidebarContextMenuScope.mixedSelectionUnavailableLabel) {}
              .disabled(true)
          } else {
            Button("Copy Run ID") {
              HarnessMonitorClipboard.copy(run.runId)
            }
          }
        }
      }
      if (snapshot?.detail?.agents ?? []).isEmpty && sessionCodexRuns.isEmpty {
        Text("No agents")
          .foregroundStyle(.secondary)
      }
    } header: {
      agentsSectionHeader
    }
  }

  @ViewBuilder var tasksSection: some View {
    Section {
      let tasks = snapshot?.detail?.tasks ?? []
      let orderedTaskIDs = tasks.map(\.taskId)
      ForEach(tasks) { task in
        taskRow(task, orderedTaskIDs: orderedTaskIDs)
      }
      if (snapshot?.detail?.tasks ?? []).isEmpty {
        Text("No tasks")
          .foregroundStyle(.secondary)
      }
    } header: {
      taskSectionHeader
    }
  }

  @ViewBuilder
  private func agentRow(
    _ agent: AgentRegistration,
    orderedAgentIDs: [String]
  ) -> some View {
    let lifecycle = store.agentLifecyclePresentation(
      for: agent,
      sessionID: state.sessionID,
      sessionRegistrations: snapshot?.detail?.agents ?? [],
      tuiStatus: store.contentUI.sessionDetail.tuiStatusByAgent[agent.agentId],
      runtimePresentation: runtimePresentation
    )
    let selection = SessionSelection.agent(sessionID: state.sessionID, agentID: agent.agentId)
    SessionSidebarRow(
      title: agent.name,
      systemImage: "person.crop.circle",
      severityShape: severityShape(for: lifecycle.visualStatus),
      severityTint: severityTint(for: lifecycle.visualStatus)
    )
    .tag(selection)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarAgentRow(agent.agentId))
    .simultaneousGesture(
      SpatialTapGesture().onEnded { _ in
        collapseToRowFromPlainTap(selection)
      },
      including: hasActiveMultiSelection ? .gesture : []
    )
    .contextMenu {
      agentRowContextMenu(agent, selection: selection, orderedAgentIDs: orderedAgentIDs)
    }
  }

  @ViewBuilder
  private func agentRowContextMenu(
    _ agent: AgentRegistration,
    selection: SessionSelection,
    orderedAgentIDs: [String]
  ) -> some View {
    let resolution = SessionSidebarContextMenuScope.resolve(
      kind: .agent,
      rowID: agent.agentId,
      selectionState: .init(
        rowSelection: selection,
        listSelection: displayedSelectionSet
      ),
      selectedIDs: state.sidebarSelection.selectedAgentIDs,
      orderedVisibleIDs: orderedAgentIDs
    )
    switch resolution {
    case .actionable(let scope):
      if !scope.isMulti {
        Menu("Move to...") {
          Button("Top") {
            state.sidebarOrdering.moveAgent(
              agent.agentId,
              before: state.sidebarOrdering.agentIDs.first,
              undoManager: undoManager
            )
          }
          Button("Bottom") {
            state.sidebarOrdering.moveAgent(
              agent.agentId,
              before: nil,
              undoManager: undoManager
            )
          }
        }
        Button("Move to Top") {
          state.sidebarOrdering.moveAgent(
            agent.agentId,
            before: state.sidebarOrdering.agentIDs.first,
            undoManager: undoManager
          )
        }
        Button("Move to Bottom") {
          state.sidebarOrdering.moveAgent(
            agent.agentId,
            before: nil,
            undoManager: undoManager
          )
        }
        Divider()
      }
      Button(scope.copyIDsLabel) {
        HarnessMonitorClipboard.copy(scope.clipboardText)
      }
      Divider()
      Button(scope.destructiveLabel, role: .destructive) {
        requestRemoveAgents(scope.ids)
      }
    case .unavailable(let message):
      Button(message) {}
        .disabled(true)
    }
  }

  @ViewBuilder
  private func taskRow(
    _ task: WorkItem,
    orderedTaskIDs: [String]
  ) -> some View {
    let selection = SessionSelection.task(sessionID: state.sessionID, taskID: task.taskId)
    SessionSidebarRow(
      title: task.title,
      systemImage: "checklist",
      severityShape: severityShape(for: task.severity),
      severityTint: severityTint(for: task.severity)
    )
    .tag(selection)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarTaskRow(task.taskId))
    .simultaneousGesture(
      SpatialTapGesture().onEnded { _ in
        collapseToRowFromPlainTap(selection)
      },
      including: hasActiveMultiSelection ? .gesture : []
    )
    .contextMenu {
      taskRowContextMenu(task, selection: selection, orderedTaskIDs: orderedTaskIDs)
    }
  }

  @ViewBuilder
  private func taskRowContextMenu(
    _ task: WorkItem,
    selection: SessionSelection,
    orderedTaskIDs: [String]
  ) -> some View {
    let resolution = SessionSidebarContextMenuScope.resolve(
      kind: .task,
      rowID: task.taskId,
      selectionState: .init(
        rowSelection: selection,
        listSelection: displayedSelectionSet
      ),
      selectedIDs: state.sidebarSelection.selectedTaskIDs,
      orderedVisibleIDs: orderedTaskIDs
    )
    switch resolution {
    case .actionable(let scope):
      if !scope.isMulti {
        Menu("Move to...") {
          ForEach(decisions.prefix(10)) { decision in
            Button(decision.summary) {
              linkTask(task.taskId, to: decision.id)
            }
          }
          if decisions.isEmpty {
            Text("No visible decisions")
          }
          if decisions.count > 10 {
            Text("Filter decisions to show more")
          }
        }
      }
      Button(scope.copyIDsLabel) {
        HarnessMonitorClipboard.copy(scope.clipboardText)
      }
      Divider()
      Button(scope.destructiveLabel, role: .destructive) {
        requestDeleteTasks(scope.ids)
      }
    case .unavailable(let message):
      Button(message) {}
        .disabled(true)
    }
  }

  private var agentsSectionHeader: some View {
    HStack(alignment: .sessionSidebarHeaderButtonCenter, spacing: 6) {
      Text("Agents")
      if state.sectionState.hasDraft(.agent) {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unsaved draft")
      }
      Spacer()
      SessionSidebarHeaderCreateButton(
        state: state,
        kind: .agent,
        accessibilityLabel: "New Agent"
      )
    }
  }

  private var taskSectionHeader: some View {
    HStack(alignment: .sessionSidebarHeaderButtonCenter, spacing: 6) {
      Text("Tasks")
      if state.sectionState.hasDraft(.task) {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unsaved draft")
      }
      Spacer()
      SessionSidebarHeaderCreateButton(
        state: state,
        kind: .task,
        accessibilityLabel: "New Task"
      )
    }
  }
}

struct SessionSidebarHeaderCreateButton: View {
  let state: SessionWindowStateCache
  let kind: SessionCreateKind
  let accessibilityLabel: String

  private var displayedShortcut: KeyboardShortcutDescriptor {
    kind.createShortcut
  }

  var body: some View {
    Button("+") {
      state.selectCreate(kind)
    }
    .alignmentGuide(.sessionSidebarHeaderButtonCenter) { dimensions in
      dimensions[VerticalAlignment.center]
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help("\(accessibilityLabel) (\(displayedShortcut.hint))")
    .accessibilityLabel(accessibilityLabel)
    .modifier(SessionSidebarCreateButtonFrameModifier(kind: kind))
    .padding(.trailing, HarnessMonitorTheme.spacingSM)
  }
}
