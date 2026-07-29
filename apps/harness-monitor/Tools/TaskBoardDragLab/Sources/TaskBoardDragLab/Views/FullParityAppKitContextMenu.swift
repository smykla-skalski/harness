import AppKit
import SwiftUI

struct FullParityAppKitContextMenu: NSViewRepresentable {
    let isFirst: Bool
    let isLast: Bool
    let moveToTop: () -> Void
    let moveToBottom: () -> Void
    let primeSelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: InstallerView, context: Context) {
        context.coordinator.update(
            isFirst: isFirst,
            isLast: isLast,
            moveToTop: moveToTop,
            moveToBottom: moveToBottom,
            primeSelection: primeSelection
        )
        context.coordinator.install(from: view)
    }

    static func dismantleNSView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class InstallerView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.install(from: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(from: self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var installedView: NSView?
        private let menu = NSMenu()
        private lazy var topItem = makeItem(
            title: "Move to Top",
            symbol: "arrow.up.to.line",
            action: #selector(moveTop)
        )
        private lazy var bottomItem = makeItem(
            title: "Move to Bottom",
            symbol: "arrow.down.to.line",
            action: #selector(moveBottom)
        )
        private lazy var rightClickRecognizer: NSClickGestureRecognizer = {
            let recognizer = NSClickGestureRecognizer(
                target: self,
                action: #selector(showMenu)
            )
            recognizer.buttonMask = 0x2
            return recognizer
        }()
        private var moveToTop: () -> Void = {}
        private var moveToBottom: () -> Void = {}
        private var primeSelection: () -> Void = {}

        override init() {
            super.init()
            menu.autoenablesItems = false
            menu.addItem(topItem)
            menu.addItem(bottomItem)
        }

        func update(
            isFirst: Bool,
            isLast: Bool,
            moveToTop: @escaping () -> Void,
            moveToBottom: @escaping () -> Void,
            primeSelection: @escaping () -> Void
        ) {
            self.moveToTop = moveToTop
            self.moveToBottom = moveToBottom
            self.primeSelection = primeSelection
            topItem.isEnabled = !isFirst
            bottomItem.isEnabled = !isLast
        }

        func install(from installer: NSView) {
            guard let cell = installer.ancestor(of: NSTableCellView.self) else {
                return
            }
            if installedView !== cell {
                detach()
                cell.addGestureRecognizer(rightClickRecognizer)
                installedView = cell
            }
        }

        func detach() {
            if rightClickRecognizer.view === installedView {
                installedView?.removeGestureRecognizer(rightClickRecognizer)
            }
            installedView = nil
        }

        @objc
        private func showMenu() {
            guard let event = NSApp.currentEvent, let installedView else {
                return
            }
            primeSelection()
            NSMenu.popUpContextMenu(menu, with: event, for: installedView)
        }

        @objc
        private func moveTop() {
            moveToTop()
        }

        @objc
        private func moveBottom() {
            moveToBottom()
        }

        private func makeItem(
            title: String,
            symbol: String,
            action: Selector
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
    }
}

private extension NSView {
    func ancestor<View: NSView>(of type: View.Type) -> View? {
        var candidate: NSView? = self
        while let view = candidate {
            if let match = view as? View {
                return match
            }
            candidate = view.superview
        }
        return nil
    }
}
