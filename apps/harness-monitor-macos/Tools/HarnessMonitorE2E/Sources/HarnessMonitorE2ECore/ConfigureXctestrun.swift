import Foundation

public enum XctestrunConfigurator {
    public enum Failure: Error, CustomStringConvertible {
        case sourceUnreadable(URL, underlying: Error)
        case malformedRoot
        case missingTarget(String)
        case writeFailed(URL, underlying: Error)

        public var description: String {
            switch self {
            case .sourceUnreadable(let url, let err):
                return "Cannot read xctestrun at \(url.path): \(err)"
            case .malformedRoot:
                return "xctestrun root is not a dictionary"
            case .missingTarget(let key):
                return "xctestrun missing target dictionary for key '\(key)'"
            case .writeFailed(let url, let err):
                return "Cannot write xctestrun to \(url.path): \(err)"
            }
        }
    }

    public static let agentsTargetKey = "HarnessMonitorAgentsE2ETests"
    public static let environmentKeys = ["EnvironmentVariables", "TestingEnvironmentVariables"]

    /// Copy `source` to `destination`, mutate the agents-e2e target's environment dictionaries, write back as XML plist.
    public static func configure(
        source: URL,
        destination: URL,
        targetKey: String = agentsTargetKey,
        updates: [String: String]
    ) throws {
        let payload: [String: Any]
        do {
            let data = try Data(contentsOf: source)
            guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw Failure.malformedRoot
            }
            payload = parsed
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.sourceUnreadable(source, underlying: error)
        }

        var mutated = payload
        guard var target = mutated[targetKey] as? [String: Any] else {
            throw Failure.missingTarget(targetKey)
        }

        for key in environmentKeys {
            var environment = target[key] as? [String: Any] ?? [:]
            for (varKey, varValue) in updates {
                environment[varKey] = varValue
            }
            target[key] = environment
        }
        mutated[targetKey] = target

        do {
            let serialized = try PropertyListSerialization.data(
                fromPropertyList: mutated, format: .xml, options: 0
            )
            try serialized.write(to: destination, options: .atomic)
        } catch {
            throw Failure.writeFailed(destination, underlying: error)
        }
    }

}
