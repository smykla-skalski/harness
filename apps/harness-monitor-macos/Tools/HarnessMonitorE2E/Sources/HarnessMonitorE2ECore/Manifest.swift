import Foundation

/// State written by `prepare` and consumed by `teardown`.
public struct E2EPreparedManifest: Codable {
    public var daemonPID: Int32
    public var bridgePID: Int32
    public var stateRoot: String
    public var dataRoot: String
    public var dataHome: String
    public var daemonLog: String
    public var bridgeLog: String
    public var terminalSessionID: String
    public var codexSessionID: String
    public var codexWorkspace: String
    public var codexPort: UInt16

    public init(
        daemonPID: Int32,
        bridgePID: Int32,
        stateRoot: String,
        dataRoot: String,
        dataHome: String,
        daemonLog: String,
        bridgeLog: String,
        terminalSessionID: String,
        codexSessionID: String,
        codexWorkspace: String,
        codexPort: UInt16
    ) {
        self.daemonPID = daemonPID
        self.bridgePID = bridgePID
        self.stateRoot = stateRoot
        self.dataRoot = dataRoot
        self.dataHome = dataHome
        self.daemonLog = daemonLog
        self.bridgeLog = bridgeLog
        self.terminalSessionID = terminalSessionID
        self.codexSessionID = codexSessionID
        self.codexWorkspace = codexWorkspace
        self.codexPort = codexPort
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> E2EPreparedManifest {
        try JSONDecoder().decode(E2EPreparedManifest.self, from: data)
    }
}
