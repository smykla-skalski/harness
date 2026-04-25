import Foundation

/// Deterministic transcript snippets the swarm e2e injects into runtime sessions to trigger observer heuristics.
public enum HeuristicFixtures {
    public static let defaultTimestamp = "2026-03-28T12:00:00Z"

    public enum Failure: Error, CustomStringConvertible {
        case unknownCode(String)
        public var description: String {
            switch self {
            case .unknownCode(let code): return "unknown heuristic code: \(code)"
            }
        }
    }

    public static func append(code: String, to logPath: URL) throws {
        let entries = try fixture(for: code)
        try FileManager.default.createDirectory(
            at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logPath.path) {
            FileManager.default.createFile(atPath: logPath.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logPath)
        try handle.seekToEnd()
        let encoder = sortedKeyEncoder()
        for entry in entries {
            let data = try encoder.encode(AnyCodable(entry))
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        }
        try handle.close()
    }

    static func fixture(for code: String) throws -> [[String: Any]] {
        guard let entries = catalog[code] else { throw Failure.unknownCode(code) }
        return entries
    }

    nonisolated(unsafe) static let catalog: [String: [[String: Any]]] = [
        "python_traceback_output": [
            toolUse(id: "heuristic-python-traceback", name: "Bash", input: ["command": "python foo.py"]),
            toolResult(
                id: "heuristic-python-traceback",
                text: "Traceback (most recent call last):\n  File \"foo.py\", line 1, in <module>\n  ValueError: bad",
                isError: true, toolName: "Bash"
            ),
        ],
        "unauthorized_git_commit_during_run": [
            toolUse(
                id: "heuristic-git-commit",
                name: "Bash",
                input: ["command": "git commit -m 'mid-run'"]
            ),
        ],
        "python_used_in_bash_tool_use": [
            toolUse(
                id: "heuristic-python-bash",
                name: "Bash",
                input: ["command": "python -c 'import os; print(1)'"]
            ),
        ],
        "absolute_manifest_path_used": [
            toolUse(
                id: "heuristic-absolute-manifest",
                name: "Bash",
                input: ["command": "harness apply /Users/bart/proj/manifest.json"]
            ),
        ],
        "jq_error_in_command_output": [
            toolUse(id: "heuristic-jq-error", name: "Bash", input: ["command": "jq '.foo' data.json"]),
            toolResult(
                id: "heuristic-jq-error",
                text: "jq: error (at <stdin>:1): Cannot index array",
                isError: true, toolName: "Bash"
            ),
        ],
        "unverified_recursive_remove": [
            toolUse(
                id: "heuristic-unverified-rm",
                name: "Bash",
                input: ["command": "rm -rf /tmp/some-dir"]
            ),
        ],
        "hook_denied_tool_call": [
            assistantText("The system denied this tool call because it was blocked by hook policy"),
        ],
        "agent_repeated_error": [
            assistantText("E: same"),
            assistantText("E: same"),
        ],
        "agent_stalled_progress": [
            assistantText("no observable progress for more than 301 seconds"),
        ],
        "cross_agent_file_conflict": [
            toolUse(
                id: "heuristic-cross-agent-file",
                name: "Write",
                input: ["file_path": "src/foo.rs", "content": "fn main() {}\n"]
            ),
            toolResult(
                id: "heuristic-cross-agent-file",
                text: "The file src/foo.rs has been updated successfully",
                isError: false, toolName: "Write"
            ),
        ],
    ]

    private static func message(role: String, content: [[String: Any]]) -> [String: Any] {
        ["timestamp": defaultTimestamp, "message": ["role": role, "content": content]]
    }

    private static func toolUse(id: String, name: String, input: [String: String]) -> [String: Any] {
        message(role: "assistant", content: [[
            "type": "tool_use", "id": id, "name": name, "input": input,
        ]])
    }

    private static func toolResult(id: String, text: String, isError: Bool, toolName: String) -> [String: Any] {
        let block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": id,
            "content": [["type": "text", "text": text]],
            "is_error": isError,
            "tool_name": toolName,
        ]
        return message(role: "user", content: [block])
    }

    private static func assistantText(_ text: String) -> [String: Any] {
        message(role: "assistant", content: [["type": "text", "text": text]])
    }

    private static func sortedKeyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Bridges arbitrary heterogeneous JSON dictionaries (built with [String: Any]) into a Codable value so JSONEncoder can emit them with deterministic key ordering.
struct AnyCodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        try encodeAny(value, to: encoder)
    }

    private func encodeAny(_ value: Any, to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        if let dict = value as? [String: Any] {
            var container = encoder.container(keyedBy: DynamicKey.self)
            for key in dict.keys.sorted() {
                try encode(dict[key]!, forKey: key, into: &container)
            }
        } else if let array = value as? [Any] {
            var container = encoder.unkeyedContainer()
            for element in array {
                try container.encode(AnyCodable(element))
            }
        } else if let string = value as? String {
            try single.encode(string)
        } else if let bool = value as? Bool {
            try single.encode(bool)
        } else if let int = value as? Int {
            try single.encode(int)
        } else if let double = value as? Double {
            try single.encode(double)
        } else {
            try single.encodeNil()
        }
    }

    private func encode(_ value: Any, forKey key: String, into container: inout KeyedEncodingContainer<DynamicKey>) throws {
        let codingKey = DynamicKey(stringValue: key)
        if let nested = value as? [String: Any] {
            try container.encode(AnyCodable(nested), forKey: codingKey)
        } else if let array = value as? [Any] {
            try container.encode(AnyCodable(array), forKey: codingKey)
        } else if let string = value as? String {
            try container.encode(string, forKey: codingKey)
        } else if let bool = value as? Bool {
            try container.encode(bool, forKey: codingKey)
        } else if let int = value as? Int {
            try container.encode(int, forKey: codingKey)
        } else if let double = value as? Double {
            try container.encode(double, forKey: codingKey)
        } else {
            try container.encodeNil(forKey: codingKey)
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}
