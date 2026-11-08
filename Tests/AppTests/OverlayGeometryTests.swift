import Testing
import CoreGraphics
@testable import MeetingAssistant

@Suite struct OverlayGeometryTests {

    @Test func pinnedOriginCentersHorizontallyAtTopOfScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 400, height: 100)

        let origin = OverlayGeometry.pinnedOrigin(for: size, screenFrame: screenFrame)

        #expect(origin.x == 520)
        #expect(origin.y == 800)
    }

    @Test func pinnedOriginAccountsForNonZeroScreenOrigin() {
        let screenFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 300, height: 60)

        let origin = OverlayGeometry.pinnedOrigin(for: size, screenFrame: screenFrame)

        let expectedX: CGFloat = 2250
        let expectedY: CGFloat = 1020
        #expect(origin.x == expectedX)
        #expect(origin.y == expectedY)
    }
}

@Suite struct OverlayStyleTests {

    @Test func rawValuesRoundTripForPersistence() {
        for style in OverlayStyle.allCases {
            #expect(OverlayStyle(rawValue: style.rawValue) == style)
        }
        for family in OverlayFontFamily.allCases {
            #expect(OverlayFontFamily(rawValue: family.rawValue) == family)
        }
    }

    @Test func fontFamiliesProduceDistinctFonts() {
        let sans = OverlayFontFamily.sans.font(size: 15)
        let mono = OverlayFontFamily.mono.font(size: 15)

        #expect(sans.fontName != mono.fontName)
        #expect(mono.isFixedPitch)
    }
}
