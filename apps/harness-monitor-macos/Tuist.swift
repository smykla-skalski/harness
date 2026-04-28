import ProjectDescription

let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .upToNextMajor("26.0"),
        swiftVersion: "6.2",
        generationOptions: .options(
            disablePackageVersionLocking: false,
            staticSideEffectsWarningTargets: .all,
            disableSandbox: true,
            includeGenerateScheme: false
        )
    )
)
