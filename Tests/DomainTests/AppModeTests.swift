import Testing
@testable import Domain

@Suite struct AppModeTests {
    @Test func exactlyThreeModesExist() {
        #expect(AppMode.allCases.count == 3)
        #expect(AppMode.allCases.contains(.passive))
        #expect(AppMode.allCases.contains(.answers))
        #expect(AppMode.allCases.contains(.recording))
    }
}
