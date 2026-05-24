import Foundation

extension StoreDecisionActionHandler {
  public func cancelSignal(signalID: String, agentID: String) async {
    await store.cancelSignal(signalID: signalID, agentID: agentID)
  }

  public func resendSignal(_ record: SessionSignalRecord) async {
    await store.resendSignal(record)
  }
}
