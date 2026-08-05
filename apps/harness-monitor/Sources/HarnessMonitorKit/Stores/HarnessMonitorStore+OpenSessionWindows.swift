import Foundation

extension HarnessMonitorStore {
  public func registerOpenSessionWindow(
    windowID: ObjectIdentifier,
    sessionID: String
  ) {
    openSessionWindowsByID[windowID] = sessionID
  }

  public func unregisterOpenSessionWindow(windowID: ObjectIdentifier) {
    openSessionWindowsByID.removeValue(forKey: windowID)
  }

  public var openSessionWindowIDsSnapshot: Set<String> {
    Set(openSessionWindowsByID.values)
  }

  public func sessionID(forOpenSessionWindowID windowID: ObjectIdentifier) -> String? {
    openSessionWindowsByID[windowID]
  }
}
