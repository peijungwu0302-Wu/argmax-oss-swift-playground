import SwiftUI

@main
struct LectureApp: App {
    @StateObject private var controller = LectureController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onChange(of: scenePhase) { phase in
                    if phase == .background { controller.backgrounded() }
                    if phase == .active { controller.foregrounded() }
                }
        }
    }
}
