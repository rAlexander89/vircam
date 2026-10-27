import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--process-image") {
            exit(ImageTool.run(CommandLine.arguments))
        }
        ViracmApp.main()
    }
}

struct ViracmApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        Window("Viracm", id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .windowResizability(.contentSize)
    }
}
