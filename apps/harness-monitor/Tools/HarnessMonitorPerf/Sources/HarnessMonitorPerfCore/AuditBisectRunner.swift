import Foundation

public enum AuditBisectRunner {
    public struct Inputs {
        public var checkoutRoot: URL
        public var worktreeRoot: URL
        public var goodRef: String
        public var badRef: String
        public var label: String
        public var passthroughArguments: [String]
        public var dryRun: Bool
        public var keepWorktree: Bool

        public init(
            checkoutRoot: URL, worktreeRoot: URL, goodRef: String, badRef: String,
            label: String, passthroughArguments: [String],
            dryRun: Bool = false, keepWorktree: Bool = false
        ) {
            self.checkoutRoot = checkoutRoot
            self.worktreeRoot = worktreeRoot
            self.goodRef = goodRef
            self.badRef = badRef
            self.label = label
            self.passthroughArguments = passthroughArguments
            self.dryRun = dryRun
            self.keepWorktree = keepWorktree
        }
    }

    public struct Plan: Codable, Equatable {
        public var label: String
        public var goodCommit: String
        public var badCommit: String
        public var worktreePath: String
        public var runnerScriptPath: String
        public var passthroughArguments: [String]
        public var commands: [[String]]

        enum CodingKeys: String, CodingKey {
            case label
            case goodCommit = "good_commit"
            case badCommit = "bad_commit"
            case worktreePath = "worktree_path"
            case runnerScriptPath = "runner_script_path"
            case passthroughArguments = "passthrough_arguments"
            case commands
        }
    }

    public struct Outcome {
        public var plan: Plan
        public var stdout: String
        public var stderr: String
        public var exitStatus: Int32
    }

    public struct Failure: Error, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public static func run(_ inputs: Inputs) throws -> Outcome {
        let goodCommit = try revParse(inputs.checkoutRoot, inputs.goodRef)
        let badCommit = try revParse(inputs.checkoutRoot, inputs.badRef)
        let plan = makePlan(inputs: inputs, goodCommit: goodCommit, badCommit: badCommit)
        if inputs.dryRun {
            return Outcome(plan: plan, stdout: "", stderr: "", exitStatus: 0)
        }

        try FileManager.default.createDirectory(
            at: inputs.worktreeRoot,
            withIntermediateDirectories: true
        )
        let add = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: [
                "-C", inputs.checkoutRoot.path, "worktree", "add",
                "--detach", plan.worktreePath, badCommit,
            ]
        )
        guard add.exitStatus == 0 else {
            throw Failure(message: add.stderrString)
        }

        let worktree = URL(fileURLWithPath: plan.worktreePath)
        defer {
            _ = try? ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["-C", worktree.path, "bisect", "reset"]
            )
            if !inputs.keepWorktree {
                _ = try? ProcessRunner.run(
                    "/usr/bin/git",
                    arguments: [
                        "-C", inputs.checkoutRoot.path, "worktree",
                        "remove", "--force", worktree.path,
                    ]
                )
            }
        }

        try writeRunnerScript(plan: plan)
        try checkedGit(in: worktree, ["bisect", "start", badCommit, goodCommit])
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["-C", worktree.path, "bisect", "run", plan.runnerScriptPath],
            timeoutSeconds: nil
        )
        return Outcome(
            plan: plan,
            stdout: result.stdoutString,
            stderr: result.stderrString,
            exitStatus: result.exitStatus
        )
    }

    public static func makePlan(
        inputs: Inputs,
        goodCommit: String,
        badCommit: String,
        timestamp: String? = nil
    ) -> Plan {
        let timestamp = timestamp ?? AuditRunner.utcCompactTimestamp()
        let shortBad = String(badCommit.prefix(8))
        let root = inputs.worktreeRoot.appendingPathComponent(
            "harness-monitor-bisect-\(shortBad)-\(timestamp)-\(slug(inputs.label))",
            isDirectory: true
        )
        let script = root.appendingPathComponent(".harness-monitor-perf-bisect-runner.sh")
        return Plan(
            label: inputs.label,
            goodCommit: goodCommit,
            badCommit: badCommit,
            worktreePath: root.path,
            runnerScriptPath: script.path,
            passthroughArguments: inputs.passthroughArguments,
            commands: [
                [
                    "/usr/bin/git", "-C", inputs.checkoutRoot.path,
                    "worktree", "add", "--detach", root.path, badCommit,
                ],
                ["/usr/bin/git", "-C", root.path, "bisect", "start", badCommit, goodCommit],
                ["/usr/bin/git", "-C", root.path, "bisect", "run", script.path],
            ]
        )
    }

    public static func runnerScript(label: String, passthroughArguments: [String]) -> String {
        let auditArgs = passthroughArguments.map(shellQuote).joined(separator: " ")
        let suffix = auditArgs.isEmpty ? "" : " \(auditArgs)"
        return """
        #!/usr/bin/env bash
        set -u

        cleanup() {
          git reset --hard --quiet >/dev/null 2>&1 || true
        }
        trap cleanup EXIT

        commit="$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)"
        output="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-bisect.XXXXXX")" || exit 125

        if ! mise trust >"$output" 2>&1; then
          cat "$output"
          exit 125
        fi
        if ! mise run monitor:generate >>"$output" 2>&1; then
          cat "$output"
          exit 125
        fi
        if ! mise run monitor:audit -- --label \(shellQuote(label))-"$commit" --skip-budget-enforcement\(suffix) >>"$output" 2>&1; then
          cat "$output"
          exit 125
        fi

        summary="$(awk -F'Summary: ' '/^Summary: / { value=$2 } END { print value }' "$output")"
        if [[ -z "$summary" ]]; then
          cat "$output"
          exit 125
        fi

        cat "$output"
        cli="apps/harness-monitor/Tools/HarnessMonitorPerf/.build/release/harness-monitor-perf"
        if [[ ! -x "$cli" ]]; then
          printf 'missing perf CLI: %s\\n' "$cli" >&2
          exit 125
        fi
        if "$cli" enforce-budgets "$summary"; then
          exit 0
        fi
        exit 1
        """
    }

    private static func writeRunnerScript(plan: Plan) throws {
        let scriptURL = URL(fileURLWithPath: plan.runnerScriptPath)
        let body = runnerScript(
            label: plan.label,
            passthroughArguments: plan.passthroughArguments
        )
        try Data(body.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func checkedGit(in worktree: URL, _ arguments: [String]) throws {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["-C", worktree.path] + arguments
        )
        guard result.exitStatus == 0 else {
            throw Failure(message: result.stderrString)
        }
    }

    private static func revParse(_ checkoutRoot: URL, _ ref: String) throws -> String {
        try ProcessRunner.runChecked(
            "/usr/bin/git",
            arguments: ["-C", checkoutRoot.path, "rev-parse", "--verify", "\(ref)^{commit}"]
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slug(_ value: String) -> String {
        let slug = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
        return slug.isEmpty ? "audit" : slug
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
