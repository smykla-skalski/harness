#!/usr/bin/env swift

import Foundation

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let packageRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func run(
    _ executable: String,
    arguments: [String],
    capturesOutput: Bool = false
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = packageRoot

    let pipe = Pipe()
    if capturesOutput {
        process.standardOutput = pipe
    }

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "TaskBoardDragLab.Runner",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) failed"]
        )
    }

    guard capturesOutput else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

do {
    _ = try run("/usr/bin/swift", arguments: ["build"])
    let binPath = try run(
        "/usr/bin/swift",
        arguments: ["build", "--show-bin-path"],
        capturesOutput: true
    )

    let appURL = packageRoot.appendingPathComponent(".build/TaskBoardDragLab.app")
    let contentsURL = appURL.appendingPathComponent("Contents")
    let executableDirectoryURL = contentsURL.appendingPathComponent("MacOS")
    let frameworksDirectoryURL = contentsURL.appendingPathComponent("Frameworks")
    let bundledExecutableURL = executableDirectoryURL.appendingPathComponent("TaskBoardDragLab")

    if fileManager.fileExists(atPath: appURL.path) {
        try fileManager.removeItem(at: appURL)
    }
    try fileManager.createDirectory(
        at: executableDirectoryURL,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: frameworksDirectoryURL,
        withIntermediateDirectories: true
    )
    try fileManager.copyItem(
        at: URL(fileURLWithPath: binPath).appendingPathComponent("TaskBoardDragLab"),
        to: bundledExecutableURL
    )
    let transferLibraryURL = URL(fileURLWithPath: binPath)
        .appendingPathComponent("libTaskBoardDragLabTransfer.dylib")
    if fileManager.fileExists(atPath: transferLibraryURL.path) {
        try fileManager.copyItem(
            at: transferLibraryURL,
            to: frameworksDirectoryURL.appendingPathComponent(
                "libTaskBoardDragLabTransfer.dylib"
            )
        )
        _ = try run(
            "/usr/bin/install_name_tool",
            arguments: [
                "-add_rpath",
                "@executable_path/../Frameworks",
                bundledExecutableURL.path,
            ]
        )
    }

    let info: [String: Any] = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Task Board Drag Lab",
        "CFBundleExecutable": "TaskBoardDragLab",
        "CFBundleIdentifier": "io.harnessmonitor.task-board-drag-lab",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Task Board Drag Lab",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSBackgroundOnly": false,
        "LSMinimumSystemVersion": "26.0",
        "LSUIElement": false,
        "NSHighResolutionCapable": true,
        "UTExportedTypeDeclarations": [
            [
                "UTTypeConformsTo": ["public.json"],
                "UTTypeDescription": "Task Board Drag Lab Card",
                "UTTypeIdentifier": "io.harnessmonitor.task-board-drag-lab.card",
                "UTTypeTagSpecification": [String: String](),
            ],
            [
                "UTTypeConformsTo": ["public.json"],
                "UTTypeDescription": "Harness Monitor Task Board Card",
                "UTTypeIdentifier": "io.harnessmonitor.task-board-card",
                "UTTypeTagSpecification": [String: String](),
            ],
        ],
    ]
    let plist = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try plist.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
    _ = try run(
        "/usr/bin/codesign",
        arguments: ["--force", "--deep", "--sign", "-", appURL.path]
    )

    print("Launching \(appURL.path)")
    _ = try run("/usr/bin/open", arguments: ["-n", "-W", appURL.path])
} catch {
    FileHandle.standardError.write(Data("Task Board Drag Lab failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
