import Foundation

public enum SwarmSeedState {
    public struct Output: Codable {
        public let dataHome: String
        public let seeded: Bool

        enum CodingKeys: String, CodingKey {
            case dataHome = "data_home"
            case seeded
        }
    }

    @discardableResult
    public static func seed(
        dataHome: URL,
        stalledAgentID: String? = nil,
        stallSeconds: Int? = nil
    ) throws -> Output {
        let harnessDirectory = dataHome.appendingPathComponent("harness", isDirectory: true)
        let syncDirectory = dataHome.appendingPathComponent("e2e-sync", isDirectory: true)
        let ledgerDirectory = dataHome.appendingPathComponent("e2e-ledger", isDirectory: true)

        try FileManager.default.createDirectory(at: harnessDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)

        if let stalledAgentID,
           stalledAgentID.isEmpty == false,
           let stallSeconds {
            let markerURL = ledgerDirectory.appendingPathComponent("stall-\(stalledAgentID).env")
            let body = "agent_id=\(stalledAgentID)\nstall_seconds=\(stallSeconds)\n"
            try Data(body.utf8).write(to: markerURL, options: .atomic)
        }

        return Output(dataHome: dataHome.path, seeded: true)
    }

    public static func encoded(_ output: Output) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(output)
    }
}
