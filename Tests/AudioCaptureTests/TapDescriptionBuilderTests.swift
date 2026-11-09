import CoreAudio
import Testing
@testable import AudioCapture

@Suite struct TapDescriptionBuilderTests {
    private let processes: [(objectID: AudioObjectID, bundleID: String?)] = [
        (10, "com.google.Chrome"),
        (11, "com.google.Chrome.helper"),
        (12, "com.google.Chrome.helper.Renderer"),
        (13, "com.google.Chromeish"),
        (14, "us.zoom.xos"),
        (15, nil),
        (16, "com.local.UserAgent057"),
    ]

    @Test func chromeHelpersMatchedByPrefix() {
        #expect(TapDescriptionBuilder.processObjectIDs(forBundlePrefix: "com.google.Chrome", processes: processes) == [10, 11, 12])
    }

    @Test func missingApplicationMatchesNothing() {
        #expect(TapDescriptionBuilder.processObjectIDs(forBundlePrefix: "com.microsoft.teams2", processes: processes).isEmpty)
    }

    @Test func ownProcessExcluded() {
        #expect(TapDescriptionBuilder.excludedObjectIDs(exclusions: [], ownObjectID: 16, processes: processes) == [16])
        #expect(TapDescriptionBuilder.excludedObjectIDs(exclusions: ["us.zoom.xos", "com.local.UserAgent057"], ownObjectID: 16, processes: processes) == [14, 16])
    }

    @Test func ownProcessObjectIDResolvesForTestProcess() {
        #expect(TapDescriptionBuilder.ownProcessObjectID() != nil)
    }
}
