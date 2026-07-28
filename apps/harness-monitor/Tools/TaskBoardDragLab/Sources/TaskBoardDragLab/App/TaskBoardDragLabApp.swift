import SwiftUI

@main
struct TaskBoardDragLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
    }
}
