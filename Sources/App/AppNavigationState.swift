import Observation

@MainActor
@Observable
final class AppNavigationState {
    var isShowingHistory = false
    var isShowingSettings = false
    var isShowingOnboarding = false
    var isShowingKnowledgeBase = false
}
