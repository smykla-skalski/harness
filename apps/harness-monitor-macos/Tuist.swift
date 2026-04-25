import ProjectDescription

let tuist = Tuist(
    project: .tuist(
        compatibleXcodeVersions: .upToNextMajor("26.0"),
        swiftVersion: "6.2",
        generationOptions: .options(
            resolveDependenciesWithSystemScm: false,
            disablePackageVersionLocking: false,
            staticSideEffectsWarningTargets: .all
        )
    )
)
