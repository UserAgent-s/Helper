import AVFoundation
import Testing
@testable import AudioCapture
@testable import Domain

@Suite struct SystemPermissionsCheckerTests {

    @Test func screenCaptureAccessMapping() {
        #expect(SystemPermissionsChecker.mapScreenCaptureAccess(true) == .authorized)

        #expect(SystemPermissionsChecker.mapScreenCaptureAccess(false) == .denied)
    }

    @Test func microphoneAuthorizationMapping() {
        #expect(SystemPermissionsChecker.mapAVAuthorizationStatus(.authorized) == .authorized)
        #expect(SystemPermissionsChecker.mapAVAuthorizationStatus(.notDetermined) == .notDetermined)
        #expect(SystemPermissionsChecker.mapAVAuthorizationStatus(.denied) == .denied)
        #expect(SystemPermissionsChecker.mapAVAuthorizationStatus(.restricted) == .denied)
    }
}
