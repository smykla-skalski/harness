import XCTest
@testable import HarnessMonitorPerfCore

final class ManifestWriterTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("perf-write-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func writeFile(_ contents: String, at name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    func testWriteManifestComposesInputsAndCaptures() throws {
        let inputs = try writeFile("""
        {
          "label": "perf",
          "run_id": "20260425T000000Z-perf",
          "created_at_utc": "2026-04-25T00:00:00Z",
          "git": {"commit": "deadbeef", "dirty": false, "workspace_fingerprint": "abc", "build_started_at_utc": "2026-04-25T00:00:00Z"},
          "system": {"xcode_version": "16", "xctrace_version": "1", "macos_version": "14", "macos_build": "23A", "arch": "arm64"},
          "targets": {
            "project": "/p", "shipping_scheme": "S", "host_scheme": "H",
            "shipping_app_path": "/s", "host_app_path": "/h", "host_bundle_id": "io.example",
            "staged_host_app_path": "/staged", "staged_host_binary_path": "/staged/Bin", "staged_host_bundle_id": "io.example.staged"
          },
          "build_provenance": {
            "audit_daemon_bundle": {"requested_skip": false, "mode": "rebuild", "cargo_target_dir": "/t"},
            "host": {"embedded_commit": "deadbeef", "embedded_dirty": "false", "embedded_workspace_fingerprint": "wf", "embedded_started_at_utc": "2026-04-25T00:00:00Z", "binary_sha256": "bs", "bundle_sha256": "us", "binary_mtime_utc": "m"},
            "shipping": {"built": false, "embedded_commit": "", "embedded_dirty": "", "embedded_workspace_fingerprint": "", "embedded_started_at_utc": "", "binary_sha256": "", "bundle_sha256": "", "binary_mtime_utc": ""}
          },
          "selected_scenarios": ["launch-dashboard"]
        }
        """, at: "inputs.json")

        let captures = try writeFile(
            "launch-dashboard\tSwiftUI\t5\ttraces/launch.trace\t0\tcompleted\tDashboardPreview\t/staged/Bin\t/run/dh\n",
            at: "captures.tsv"
        )

        let output = workDir.appendingPathComponent("manifest.json")
        let manifest = try ManifestWriter.write(
            inputsJSON: inputs, capturesTSV: captures,
            environmentPairs: ["HARNESS_MONITOR_UI_TESTS=1"],
            launchArguments: ["-ApplePersistenceIgnoreState", "YES"],
            output: output
        )

        XCTAssertEqual(manifest.label, "perf")
        XCTAssertEqual(manifest.captures.count, 1)
        XCTAssertEqual(manifest.captures[0].environment["HARNESS_DAEMON_DATA_HOME"], "/run/dh")
        XCTAssertEqual(manifest.captures[0].environment["HARNESS_MONITOR_PERF_SCENARIO"], "launch-dashboard")

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(written.contains("\"label\" : \"perf\""))
        XCTAssertTrue(written.contains("\"selected_scenarios\""))
    }

    func testParseTSVRejectsMalformedRows() throws {
        let malformed = try writeFile("scenario\ttemplate\t5\n", at: "bad.tsv")
        XCTAssertThrowsError(try ManifestWriter.parseCapturesTSV(malformed))
    }

    func testVerifyManifestPassesOnCleanBuild() throws {
        let manifest = """
        {
          "git": {"commit": "abc", "dirty": false, "workspace_fingerprint": "wf"},
          "targets": {"staged_host_bundle_id": "io.example.staged"},
          "build_provenance": {"host": {"embedded_commit": "abc", "embedded_dirty": "false", "binary_sha256": "deadbeef"}}
        }
        """
        let url = try writeFile(manifest, at: "manifest-clean.json")
        XCTAssertNoThrow(try ManifestVerifier.verify(manifest: url, expectedCommit: "abc"))
    }

    func testVerifyManifestSurfacesEveryError() throws {
        let manifest = """
        {
          "git": {"commit": "wrong", "dirty": true, "workspace_fingerprint": ""},
          "targets": {"staged_host_bundle_id": ""},
          "build_provenance": {"host": {"embedded_commit": "wrong", "embedded_dirty": "true", "binary_sha256": ""}}
        }
        """
        let url = try writeFile(manifest, at: "manifest-bad.json")
        XCTAssertThrowsError(try ManifestVerifier.verify(manifest: url, expectedCommit: "abc")) { error in
            guard let failure = error as? ManifestVerifier.Failure else {
                XCTFail("expected Failure")
                return
            }
            XCTAssertEqual(failure.messages.count, 7)
            XCTAssertTrue(failure.description.contains("git.commit=wrong"))
            XCTAssertTrue(failure.description.contains("workspace_fingerprint is missing"))
            XCTAssertTrue(failure.description.contains("staged_host_bundle_id is missing"))
        }
    }
}
