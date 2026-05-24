import Foundation

/// SAX-style parser for an xctrace `--xpath` query export.
///
/// The legacy `XMLDocument(data:)` path built the entire DOM (~5-10x input size)
/// before any extraction could run, so a 2.4 GB exported XML peaked at 12-24 GB
/// of resident memory and OOMd the audit framework. This parser walks the
/// payload with `XMLParser` instead, materializing only the bits the extractor
/// actually reads:
///   - `schemaColumns`: column mnemonics under `<schema><col><mnemonic>`.
///   - `rows`: each `<row>` materialized into a small detached `XMLElement`
///     subtree (no parent linkage to the original document).
///   - `idIndex`: every element that carries an `id` attribute, stored by id so
///     `<element ref="N"/>` chains can resolve to their backing element.
///
/// Top-level non-row elements (e.g. `<backtrace id="…">`) are also captured
/// because rows reference them by `ref`. They live only inside `idIndex`; the
/// remainder of the tree is discarded as parsing progresses.
final class XctraceQueryParser: NSObject, XMLParserDelegate {
    private(set) var schemaColumns: [String] = []
    private(set) var rows: [XMLElement] = []
    private(set) var idIndex: [String: XMLElement] = [:]

    private var sawNodeElement = false
    private var insideNode = false
    private var insideSchema = false
    private var insideMnemonic = false
    private var schemaCurrentMnemonic = ""

    private var buildStack: [XMLElement] = []
    private var buildText: [String] = []
    private var topLevelRetention: [XMLElement] = []

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            if let error = parser.parserError {
                throw XctraceQueryDocument.ParseError.parserFailed(error.localizedDescription)
            }
            throw XctraceQueryDocument.ParseError.parserCancelled
        }
        if !sawNodeElement {
            throw XctraceQueryDocument.ParseError.missingNodeElement
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if !insideNode {
            if elementName == "node" {
                insideNode = true
                sawNodeElement = true
            }
            return
        }
        if !buildStack.isEmpty {
            let element = makeElement(name: elementName, attributes: attributeDict)
            buildStack.last?.addChild(element)
            buildStack.append(element)
            buildText.append("")
            return
        }
        if insideSchema {
            if elementName == "mnemonic" {
                insideMnemonic = true
                schemaCurrentMnemonic = ""
            }
            return
        }
        if elementName == "schema" {
            insideSchema = true
            return
        }
        let element = makeElement(name: elementName, attributes: attributeDict)
        buildStack = [element]
        buildText = [""]
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !insideNode {
            return
        }
        if !buildStack.isEmpty {
            finishCurrentBuildElement()
            return
        }
        if insideSchema {
            switch elementName {
            case "mnemonic":
                insideMnemonic = false
            case "col":
                schemaColumns.append(schemaCurrentMnemonic)
                schemaCurrentMnemonic = ""
            case "schema":
                insideSchema = false
            default:
                break
            }
            return
        }
        if elementName == "node" {
            insideNode = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !buildText.isEmpty {
            buildText[buildText.count - 1].append(string)
            return
        }
        if insideMnemonic {
            schemaCurrentMnemonic.append(string)
        }
    }

    private func finishCurrentBuildElement() {
        let element = buildStack.removeLast()
        let text = buildText.removeLast()
        if element.childCount == 0 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                element.stringValue = trimmed
            }
        }
        guard buildStack.isEmpty else { return }
        if element.name == "row" {
            rows.append(element)
        } else {
            topLevelRetention.append(element)
        }
    }

    private func makeElement(name: String, attributes: [String: String]) -> XMLElement {
        let element = XMLElement(name: name)
        if !attributes.isEmpty {
            element.setAttributesWith(attributes)
            if let id = attributes["id"] {
                idIndex[id] = element
            }
        }
        return element
    }
}
