import Foundation

enum SwarmAckWait {
    enum Failure: Error, Equatable {
        case timedOut
    }

    enum Outcome: Equatable {
        case acknowledged
        case stopped
    }

    static func waitForAck(
        ackExists: () -> Bool,
        stopRequested: () -> Bool,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> Outcome {
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            if ackExists() {
                return .acknowledged
            }
            if stopRequested() {
                return .stopped
            }
            sleep(pollInterval)
        }
        throw Failure.timedOut
    }
}
