import Domain
import Foundation
import Testing
@testable import AudioCapture

@Suite struct UserDefaultsPreferredAudioSourceStoreTests {

    private func freshStore() -> UserDefaultsPreferredAudioSourceStore {
        let suiteName = "test-\(UUID().uuidString)"
        return UserDefaultsPreferredAudioSourceStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test func defaultsToWholeSystemWhenNeverSet() async {
        let store = freshStore()
        #expect(await store.systemAudioScope() == .wholeSystem(excludingBundleIDs: []))
        #expect(await store.preferredApplicationBundleID() == nil)
    }

    @Test func explicitBundleIDBecomesApplicationScopeWithFallback() async {
        let store = freshStore()
        await store.setPreferredApplicationBundleID("com.apple.Safari")
        #expect(await store.preferredApplicationBundleID() == "com.apple.Safari")
        #expect(await store.systemAudioScope() == .application(bundleID: "com.apple.Safari", fallbackToWholeSystem: true))
    }

    @Test func explicitlyClearingReturnsWholeSystem() async {
        let store = freshStore()
        await store.setPreferredApplicationBundleID("com.apple.Safari")
        await store.setPreferredApplicationBundleID(nil)
        #expect(await store.preferredApplicationBundleID() == nil)
    }

    @Test func scopeRoundTripsThroughJSON() async {
        let store = freshStore()
        await store.setSystemAudioScope(.wholeSystem(excludingBundleIDs: ["com.spotify.client"]))
        #expect(await store.systemAudioScope() == .wholeSystem(excludingBundleIDs: ["com.spotify.client"]))
    }
}
