import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateBridgeBannerSection: View {
  let store: HarnessMonitorStore
  let selection: AgentLaunchSelection

  private var bannerKind: SessionCreateBridgeBannerKind? {
    if selection.isCodexNative {
      return store.codexUnavailable ? .codex : nil
    }
    if selection.isAcp {
      return store.acpUnavailable ? .acp : nil
    }
    return store.agentTuiUnavailable ? .agentTui : nil
  }

  var body: some View {
    if let bannerKind {
      Section {
        SessionCreateBridgeBanner(
          store: store,
          copy: bannerKind.copy(store: store)
        )
      }
    }
  }
}
