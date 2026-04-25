import Foundation

/// Wraps an `xctrace export --xpath ...` payload and exposes the row+id-ref vocabulary the
/// python extractor relies on.
///
/// Each xctrace payload is shaped like:
///
///   <trace-query-result>
///     <node>
///       <schema>
///         <col><mnemonic>duration</mnemonic></col>
///         <col><mnemonic>label</mnemonic></col>
///         ...
///       </schema>
///       <row><duration id="3" fmt="...">123</duration><label ref="3"/></row>
///       ...
///     </node>
///   </trace-query-result>
///
/// Elements either carry their own value (text or `fmt` attribute) or a `ref` to another
/// element identified by `id`. Resolving values therefore walks the id index until landing on
/// an element with payload.
public struct XctraceQueryDocument {
    public let root: XMLElement
    public let node: XMLElement
    public let schemaColumns: [String]
    public let idIndex: [String: XMLElement]

    public init(data: Data) throws {
        let xml = try XMLDocument(data: data, options: [.nodePreserveAttributeOrder])
        guard let root = xml.rootElement() else {
            throw ParseError.missingRootElement
        }
        guard let node = (try? root.nodes(forXPath: ".//node"))?.compactMap({ $0 as? XMLElement }).first else {
            throw ParseError.missingNodeElement
        }
        self.root = root
        self.node = node
        self.idIndex = Self.buildIdIndex(node)
        self.schemaColumns = Self.readSchemaColumns(node)
    }

    public init(path: URL) throws {
        try self.init(data: try Data(contentsOf: path))
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missingRootElement
        case missingNodeElement
        public var description: String {
            switch self {
            case .missingRootElement: return "xctrace XML missing root element"
            case .missingNodeElement: return "xctrace XML missing <node>"
            }
        }
    }

    public var rows: [XMLElement] {
        node.elements(forName: "row")
    }

    /// Mirrors `row_to_record` in the python extractor. Each row child is resolved to text and
    /// keyed by its column mnemonic (or its tag name when the schema is sparse).
    public func record(for row: XMLElement) -> [String: String] {
        var record: [String: String] = [:]
        let children = row.children?.compactMap { $0 as? XMLElement } ?? []
        for (index, child) in children.enumerated() {
            let key: String
            if index < schemaColumns.count, !schemaColumns[index].isEmpty {
                key = schemaColumns[index]
            } else {
                key = child.name ?? ""
            }
            record[key] = resolvedText(of: child)
        }
        return record
    }

    /// Resolve `<element ref="N"/>` chains to their backing element, then return that element's
    /// text content, `fmt` attribute, or the resolved single-child text.
    public func resolvedText(of element: XMLElement) -> String {
        guard let resolved = dereference(element) else { return "" }
        if let text = resolved.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let fmt = resolved.attribute(forName: "fmt")?.stringValue, !fmt.isEmpty {
            return fmt
        }
        if resolved.name == "backtrace" {
            return resolved.attribute(forName: "fmt")?.stringValue ?? ""
        }
        let children = resolved.children?.compactMap { $0 as? XMLElement } ?? []
        if children.count == 1 {
            return resolvedText(of: children[0])
        }
        return ""
    }

    /// Follow `ref="X"` until an element with no `ref` is reached, or `nil` if the chain
    /// dangles.
    public func dereference(_ element: XMLElement) -> XMLElement? {
        guard let ref = element.attribute(forName: "ref")?.stringValue else {
            return element
        }
        guard let target = idIndex[ref] else { return nil }
        if target.attribute(forName: "ref") != nil {
            return dereference(target)
        }
        return target
    }

    private static func buildIdIndex(_ node: XMLElement) -> [String: XMLElement] {
        var index: [String: XMLElement] = [:]
        var stack: [XMLElement] = [node]
        while let current = stack.popLast() {
            if let id = current.attribute(forName: "id")?.stringValue { index[id] = current }
            for child in current.children ?? [] {
                if let element = child as? XMLElement { stack.append(element) }
            }
        }
        return index
    }

    private static func readSchemaColumns(_ node: XMLElement) -> [String] {
        guard let schema = node.elements(forName: "schema").first else { return [] }
        return schema.elements(forName: "col").map { col in
            col.elements(forName: "mnemonic").first?.stringValue ?? ""
        }
    }
}

/// Schema/track discovery against a xctrace TOC payload.
public struct XctraceTOC {
    public let document: XMLDocument

    public init(data: Data) throws {
        document = try XMLDocument(data: data, options: [.nodePreserveAttributeOrder])
    }

    public init(path: URL) throws {
        try self.init(data: try Data(contentsOf: path))
    }

    public func availableSchemas() -> Set<String> {
        let elements = (try? document.nodes(forXPath: ".//table[@schema]"))?.compactMap { $0 as? XMLElement } ?? []
        let names = elements.compactMap {
            $0.attribute(forName: "schema")?.stringValue?.trimmingCharacters(in: .whitespaces)
        }
        return Set(names.filter { !$0.isEmpty })
    }

    public func availableAllocationDetails() -> Set<String> {
        let elements = (try? document.nodes(forXPath: ".//track[@name='Allocations']/details/detail"))?
            .compactMap { $0 as? XMLElement } ?? []
        let names = elements.compactMap {
            $0.attribute(forName: "name")?.stringValue?.trimmingCharacters(in: .whitespaces)
        }
        return Set(names.filter { !$0.isEmpty })
    }

    /// Returns the first `<process pid != "0">` path - the actual launched-process binary
    /// xctrace recorded. Mirrors `trace_launched_process_path` in
    /// run-instruments-audit.sh:411.
    public func launchedProcessPath() -> String {
        let processes = (try? document.nodes(forXPath: ".//processes/process"))?
            .compactMap { $0 as? XMLElement } ?? []
        for process in processes {
            let pid = process.attribute(forName: "pid")?.stringValue ?? ""
            if pid != "0" {
                return process.attribute(forName: "path")?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }
        return ""
    }

    /// Returns the first `<end-reason>` text node, used to disambiguate xctrace exit codes
    /// vs the natural "Time limit reached" stop. Mirrors run-instruments-audit.sh:1125.
    public func endReason() -> String {
        let nodes = (try? document.nodes(forXPath: ".//end-reason"))?
            .compactMap { $0 as? XMLElement } ?? []
        return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
