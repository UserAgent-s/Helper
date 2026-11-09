import Darwin
import Domain

struct ShareableApplicationInfo: Sendable, Equatable {
    let bundleID: String
    let processID: pid_t
}

enum SystemAudioFilterPlan: Equatable, Sendable {
    case display(excludingBundleIDs: [String])
    case applications(bundleIDs: [String])
}

struct ResolvedSystemAudioPlan: Equatable, Sendable {
    let plan: SystemAudioFilterPlan
    let effectiveScope: SystemAudioScope
    let notice: CaptureNotice?
}

enum SystemAudioFilterPlanner {
    static func plan(scope: SystemAudioScope, running: [ShareableApplicationInfo], ownBundleID: String) throws -> ResolvedSystemAudioPlan {
        switch scope {
        case .wholeSystem(let exclusions):
            return ResolvedSystemAudioPlan(
                plan: .display(excludingBundleIDs: excluding(exclusions, ownBundleID: ownBundleID)),
                effectiveScope: scope,
                notice: nil
            )
        case .application(let bundleID, let fallbackToWholeSystem):
            let helperPrefix = bundleID + "."
            let matching = running
                .map(\.bundleID)
                .filter { $0 == bundleID || $0.hasPrefix(helperPrefix) }
            if matching.contains(bundleID) {
                return ResolvedSystemAudioPlan(
                    plan: .applications(bundleIDs: unique([bundleID] + matching.sorted())),
                    effectiveScope: scope,
                    notice: nil
                )
            }
            guard fallbackToWholeSystem else {
                throw AudioCaptureError.targetApplicationNotFound(bundleID)
            }
            return ResolvedSystemAudioPlan(
                plan: .display(excludingBundleIDs: excluding([], ownBundleID: ownBundleID)),
                effectiveScope: .wholeSystem(excludingBundleIDs: []),
                notice: .fellBackToWholeSystem(missingBundleID: bundleID)
            )
        }
    }

    private static func excluding(_ exclusions: [String], ownBundleID: String) -> [String] {
        unique((exclusions + [ownBundleID]).filter { !$0.isEmpty })
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
