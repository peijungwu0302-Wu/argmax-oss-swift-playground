import SwiftUI

@main
struct LectureApp: App {
    @StateObject private var controller = LectureController()
    @StateObject private var navigation = AppNavigationState()
    @StateObject private var pipSettings = PiPPresentationSettings.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .environmentObject(navigation)
                .environmentObject(pipSettings)
                .environment(\.locale, l10n.effectiveLocale)
                .id(l10n.appLanguage.rawValue)
                .onOpenURL { url in
                    let ids = Set(controller.history.map(\.id) + [controller.session?.id].compactMap { $0 })
                    _ = navigation.handle(url, knownLectureIDs: ids, activeLectureID: controller.session?.id)
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background { controller.backgrounded() }
                    if phase == .active { controller.foregrounded() }
                }
        }
    }
}
