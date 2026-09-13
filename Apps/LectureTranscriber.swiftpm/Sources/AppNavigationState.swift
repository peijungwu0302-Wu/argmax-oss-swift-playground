import Foundation

@MainActor
final class AppNavigationState: ObservableObject {
    enum Route: Equatable {
        case home
        case activeLecture(UUID)
        case fullTranscript(UUID)
    }

    @Published var route: Route = .home

    func showFullTranscript(for lectureID: UUID) {
        route = .fullTranscript(lectureID)
    }

    func restoreCurrentLectureTranscript(activeLectureID: UUID?) {
        guard let activeLectureID else {
            route = .home
            return
        }
        route = .fullTranscript(activeLectureID)
    }

    @discardableResult
    func handle(_ url: URL, knownLectureIDs: Set<UUID>, activeLectureID: UUID? = nil) -> Bool {
        guard url.scheme == "lecturetranscriber" else { return false }
        if url.host == "live" {
            restoreCurrentLectureTranscript(activeLectureID: activeLectureID)
            return activeLectureID != nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host == "lecture", parts.count == 2, parts[1] == "transcript",
              let id = UUID(uuidString: parts[0]), knownLectureIDs.contains(id) else {
            route = .home
            return false
        }
        route = .fullTranscript(id)
        return true
    }
}
