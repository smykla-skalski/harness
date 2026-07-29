// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskBoardDragLab",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TaskBoardDragLab", targets: ["TaskBoardDragLab"]),
    ],
    dependencies: [
        .package(path: "TransferPackage"),
        .package(
            url: "https://github.com/siteline/swiftui-introspect",
            exact: "26.0.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "TaskBoardDragLab",
            dependencies: [
                .product(
                    name: "TaskBoardDragLabTransfer",
                    package: "TransferPackage"
                ),
                .product(
                    name: "SwiftUIIntrospect",
                    package: "swiftui-introspect"
                ),
            ]
        ),
    ]
)
