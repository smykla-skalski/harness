import SwiftUI

public struct WorkspaceWindowOpeningView: View {
  public init() {}

  public var body: some View {
    HStack(spacing: 0) {
      openingSidebar
        .frame(width: 260)
      Divider()
      openingDetail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Opening workspace")
    .accessibilityValue("Preparing agents, sessions, and tools")
  }

  private var openingSidebar: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      Text("Workspace")
        .scaledFont(.body)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        skeletonRow(width: 132)
        skeletonRow(width: 176)
        skeletonRow(width: 148)
      }

      Spacer()
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.44))
  }

  private var openingDetail: some View {
    ZStack {
      openingGuides
      openingStatus
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var openingGuides: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      HStack(spacing: HarnessMonitorTheme.spacingMD) {
        skeletonBlock(width: 180, height: 12)
        skeletonBlock(width: 120, height: 12)
      }
      skeletonBlock(width: 360, height: 18)
      Spacer()
      HStack(spacing: HarnessMonitorTheme.spacingMD) {
        skeletonBlock(width: 220, height: 12)
        skeletonBlock(width: 160, height: 12)
      }
    }
    .padding(HarnessMonitorTheme.spacingXXL)
    .opacity(0.42)
    .accessibilityHidden(true)
  }

  private var openingStatus: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      ZStack {
        Circle()
          .fill(HarnessMonitorTheme.accent.opacity(0.12))
          .frame(width: 58, height: 58)
        HarnessMonitorSpinner(size: 38, tint: HarnessMonitorTheme.accent)
        HarnessMonitorUIAssets.image(named: "ToolbarWorkspaceBot")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .foregroundStyle(HarnessMonitorTheme.accent)
          .frame(width: 22, height: 22)
          .accessibilityHidden(true)
      }

      VStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text("Opening workspace")
          .scaledFont(.headline)
          .foregroundStyle(HarnessMonitorTheme.ink)
        Text("Preparing agents, sessions, and tools")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXXL)
    .padding(.vertical, HarnessMonitorTheme.spacingXL)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.82))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.accent.opacity(0.18), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    .accessibilityElement(children: .combine)
  }

  private func skeletonRow(width: CGFloat) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Circle()
        .fill(HarnessMonitorTheme.ink.opacity(0.12))
        .frame(width: 12, height: 12)
      skeletonBlock(width: width, height: 10)
    }
    .accessibilityHidden(true)
  }

  private func skeletonBlock(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
      .fill(HarnessMonitorTheme.ink.opacity(0.10))
      .frame(width: width, height: height)
      .accessibilityHidden(true)
  }
}

#Preview("Workspace Opening - Light") {
  WorkspaceWindowOpeningView()
    .frame(width: 1_020, height: 680)
    .preferredColorScheme(.light)
}

#Preview("Workspace Opening - Dark") {
  WorkspaceWindowOpeningView()
    .frame(width: 1_020, height: 680)
    .preferredColorScheme(.dark)
}
