// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransferPackage",
    platforms: [.macOS("26.0")],
    products: [
        .library(
            name: "TaskBoardDragLabTransfer",
            type: .dynamic,
            targets: ["TaskBoardDragLabTransfer"]
        ),
    ],
    targets: [
        .target(name: "TaskBoardDragLabTransfer"),
    ]
)
