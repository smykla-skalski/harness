import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

struct DashboardPolicyCanvasFooterBar: View {
  @ScaledMetric(relativeTo: .callout)
  private var footerBarHeight = 44.0

  let workspace: PolicyCanvasWorkspace?
  let fallbackDocument: PolicyPipelineDocument?
  let selectedCanvasId: String?
  let policyCanvasViewModel: PolicyCanvasViewModel
  let isCanvasMutationDisabled: Bool
  let editingCanvasId: String?
  @Binding var isAutomationPolicySheetPresented: Bool
  let createCanvas: @MainActor () -> Void
  let selectCanvas: @MainActor (PolicyCanvasSummary) -> Void
  let duplicateCanvasFromTab: @MainActor (PolicyCanvasSummary) -> Void
  let renameCanvasFromTab: @MainActor (PolicyCanvasSummary) -> Void
  let submitRenameCanvasFromTab: @MainActor (PolicyCanvasSummary, String) -> Void
  let cancelRenameCanvasFromTab: @MainActor () -> Void
  let deleteCanvasFromTab: @MainActor (PolicyCanvasSummary) -> Void
  let onExport: (@MainActor () -> Void)?
  let onImport: (@MainActor () -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 0) {
        tabStrip
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        DashboardPolicyCanvasFooterSaveStatus(
          activity: policyCanvasViewModel.saveActivity
        )

        DashboardPolicyCanvasFooterToolsMenuButton(
          viewModel: policyCanvasViewModel,
          isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented,
          onExport: onExport,
          onImport: onImport
        )
      }
      .padding(.leading, HarnessMonitorTheme.spacingMD)
      .frame(height: footerBarHeight)
    }
    .background(.background)
    .accessibilityElement(children: .contain)
    .onChange(of: isCanvasMutationDisabled) { _, disabled in
      if disabled, editingCanvasId != nil {
        cancelRenameCanvasFromTab()
      }
    }
  }

  @ViewBuilder private var tabStrip: some View {
    if let workspace {
      if workspace.canvases.isEmpty {
        footerStatusStrip("No canvases", systemImage: "square.dashed")
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(
              Array(workspace.canvases.enumerated()),
              id: \.element.canvasId
            ) { index, canvas in
              DashboardPolicyCanvasFooterTab(
                canvas: canvas,
                isSelected: canvas.canvasId == (selectedCanvasId ?? workspace.activeCanvasId),
                isActive: canvas.canvasId == workspace.activeCanvasId,
                isEditing: canvas.canvasId == editingCanvasId,
                canRename: !isCanvasMutationDisabled,
                showsLeadingSeparator: index > 0,
                select: { selectCanvas(canvas) },
                beginRename: { renameCanvasFromTab(canvas) },
                submitRename: { submitRenameCanvasFromTab(canvas, $0) },
                cancelRename: cancelRenameCanvasFromTab
              )
              .contextMenu {
                Button("Duplicate") {
                  duplicateCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)

                Button("Rename") {
                  renameCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)

                Divider()

                Button("Delete", role: .destructive) {
                  deleteCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)
              }
            }

            createCanvasTab
          }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardPolicyCanvasFooterTabs)
      }
    } else if let fallbackActiveCanvasSummary {
      fallbackTabStrip(fallbackActiveCanvasSummary)
    } else {
      footerStatusStrip("Policy Canvas", systemImage: "rectangle.on.rectangle")
    }
  }

  private var fallbackActiveCanvasSummary: PolicyCanvasSummary? {
    guard let fallbackDocument else {
      return nil
    }
    return PolicyCanvasSummary(
      canvasId: "active-policy-canvas-loading",
      title: fallbackPolicyCanvasTitle(),
      revision: fallbackDocument.revision,
      mode: fallbackDocument.mode,
      document: fallbackDocument,
      nodeCount: fallbackDocument.nodes.count,
      edgeCount: fallbackDocument.edges.count,
      groupCount: fallbackDocument.groups.count,
      updatedAt: ""
    )
  }

  private func fallbackTabStrip(_ canvas: PolicyCanvasSummary) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 0) {
        DashboardPolicyCanvasFooterTab(
          canvas: canvas,
          isSelected: true,
          isActive: true,
          isEditing: false,
          canRename: false,
          showsLeadingSeparator: false,
          select: {},
          beginRename: {},
          submitRename: { _ in },
          cancelRename: {}
        )

        createCanvasTab
      }
    }
    .frame(maxHeight: .infinity, alignment: .leading)
    .scrollIndicators(.hidden)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardPolicyCanvasFooterTabs)
  }

  private var createCanvasTab: some View {
    DashboardPolicyCanvasFooterCreateTab(
      isDisabled: isCanvasMutationDisabled,
      createCanvas: createCanvas
    )
  }

  private func footerStatusStrip(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 0) {
      footerStatusLabel(title, systemImage: systemImage)
      createCanvasTab
    }
  }

  private func footerStatusLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private func fallbackPolicyCanvasTitle() -> String {
    "Policy Canvas"
  }
}
