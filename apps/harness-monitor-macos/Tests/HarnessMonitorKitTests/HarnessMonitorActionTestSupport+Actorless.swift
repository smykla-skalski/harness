import Foundation

@testable import HarnessMonitorKit

func actorlessActionClient() -> RecordingHarnessClient {
  HarnessMonitorStoreSelectionTestSupport.configuredClient(
    summaries: [PreviewFixtures.emptyCockpitSummary],
    detailsByID: [
      PreviewFixtures.emptyCockpitSummary.sessionId: PreviewFixtures.emptyCockpitDetail
    ],
    detail: PreviewFixtures.emptyCockpitDetail
  )
}

@MainActor
func actorlessActionStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
  let store = await makeBootstrappedStore(client: client)
  await store.selectSession(PreviewFixtures.emptyCockpitSummary.sessionId)
  clearRecordedCallsIfNeeded(for: client)
  return store
}
