import Foundation

struct AppEnvironment {
    static let isolatedRootVariable = "MEETINGASSISTANT_ISOLATED_ROOT"

    let defaults: UserDefaults
    let defaultsSuiteName: String?
    let dataDirectory: URL
    let desktopExportDirectory: URL
    let keychainNamespace: String
    let isIsolated: Bool
    let isTestHost: Bool

    static func detectsTestHost(_ processInfo: ProcessInfo = .processInfo) -> Bool {
        processInfo.environment["XCTestConfigurationFilePath"] != nil || processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    static func isolated(root rootURL: URL, suffix: String, isTestHost: Bool = detectsTestHost()) -> AppEnvironment {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let suiteName = "com.local.MeetingAssistant.\(suffix)"
        return AppEnvironment(
            defaults: UserDefaults(suiteName: suiteName) ?? .standard,
            defaultsSuiteName: suiteName,
            dataDirectory: rootURL.appendingPathComponent("MeetingAssistant", isDirectory: true),
            desktopExportDirectory: rootURL.appendingPathComponent("Desktop", isDirectory: true),
            keychainNamespace: "com.local.MeetingAssistant.\(suffix)",
            isIsolated: true,
            isTestHost: isTestHost
        )
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> AppEnvironment {
        if let root = processInfo.environment[isolatedRootVariable], !root.isEmpty {
            return isolated(root: URL(fileURLWithPath: root, isDirectory: true), suffix: "isolated", isTestHost: detectsTestHost(processInfo))
        }
        if detectsTestHost(processInfo) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistantTestHost", isDirectory: true)
            return isolated(root: root, suffix: "testhost")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return AppEnvironment(
            defaults: .standard,
            defaultsSuiteName: nil,
            dataDirectory: appSupport.appendingPathComponent("MeetingAssistant", isDirectory: true),
            desktopExportDirectory: desktop,
            keychainNamespace: "com.local.MeetingAssistant",
            isIsolated: false,
            isTestHost: false
        )
    }
}
