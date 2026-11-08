import Foundation
import Testing
@testable import AudioCapture

@Suite struct UserDefaultsPreferredAudioSourceStoreTests {

    private func freshStore() -> UserDefaultsPreferredAudioSourceStore {
        let suiteName = "test-\(UUID().uuidString)"
        return UserDefaultsPreferredAudioSourceStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @Test func defaultsToChromeWhenNeverSet() async {
        let store = freshStore()
        #expect(await store.preferredApplicationBundleID() == "com.google.Chrome")
    }

    @Test func explicitBundleIDOverridesDefault() async {
        let store = freshStore()
        await store.setPreferredApplicationBundleID("com.apple.Safari")
        #expect(await store.preferredApplicationBundleID() == "com.apple.Safari")
    }

    @Test func explicitlyClearingReturnsNilRatherThanFallingBackToDefault() async {
        let store = freshStore()
        await store.setPreferredApplicationBundleID("com.apple.Safari")
        await store.setPreferredApplicationBundleID(nil)
        #expect(await store.preferredApplicationBundleID() == nil)
    }
}
