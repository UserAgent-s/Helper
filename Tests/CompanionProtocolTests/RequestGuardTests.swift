import Foundation
import Testing
@testable import CompanionProtocol

@Suite struct RequestGuardTests {
    private let guardian = RequestGuard(port: 47057)
    private let served = ["192.168.1.10", "fe80::1c2b:3aff:fe4d:5e6f%en0", "127.0.0.1", "::1"]

    private func evaluate(_ remote: String, host: String?, origin: String?) -> RequestRejection? {
        guardian.evaluate(remoteAddress: remote, host: host, origin: origin, serverAddresses: served)
    }

    @Test func lanBrowserWithMatchingOriginIsAccepted() {
        #expect(evaluate("192.168.1.20", host: "192.168.1.10:47057", origin: "http://192.168.1.10:47057") == nil)
    }

    @Test func nativeClientWithoutOriginIsAccepted() {
        #expect(evaluate("10.0.0.7", host: "192.168.1.10:47057", origin: nil) == nil)
    }

    @Test func foreignOriginIsRejected() {
        #expect(evaluate("192.168.1.20", host: "192.168.1.10:47057", origin: "http://evil.example") == .originMismatch)
        #expect(evaluate("192.168.1.20", host: "192.168.1.10:47057", origin: "null") == .originMismatch)
        #expect(evaluate("192.168.1.20", host: "192.168.1.10:47057", origin: "https://192.168.1.10:47057") == .originMismatch)
    }

    @Test func dnsRebindingHostIsRejected() {
        #expect(evaluate("192.168.1.20", host: "rebind.evil.example:47057", origin: "http://rebind.evil.example:47057") == .hostMismatch)
        #expect(evaluate("192.168.1.20", host: "localhost:47057", origin: "http://localhost:47057") == .hostMismatch)
    }

    @Test func hostMismatchIsRejected() {
        #expect(evaluate("192.168.1.20", host: "192.168.1.11:47057", origin: nil) == .hostMismatch)
        #expect(evaluate("192.168.1.20", host: "192.168.1.10:8080", origin: nil) == .hostMismatch)
        #expect(evaluate("192.168.1.20", host: "192.168.1.10", origin: nil) == .hostMismatch)
        #expect(evaluate("192.168.1.20", host: nil, origin: nil) == .hostMismatch)
        #expect(evaluate("127.0.0.1", host: "127.0.0.1:47057", origin: nil) == nil)
        #expect(evaluate("192.168.1.20", host: "127.0.0.1:47057", origin: nil) == nil)
    }

    @Test func loopbackLocalhostIsAccepted() {
        #expect(evaluate("127.0.0.1", host: "localhost:47057", origin: "http://localhost:47057") == nil)
        #expect(evaluate("::1", host: "[::1]:47057", origin: "http://[::1]:47057") == nil)
    }

    @Test func ipv6LinkLocalIsAccepted() {
        #expect(evaluate("fe80::aa:bbff:fecc:dd%en0", host: "[fe80::1c2b:3aff:fe4d:5e6f]:47057", origin: "http://[fe80::1c2b:3aff:fe4d:5e6f]:47057") == nil)
    }

    @Test func publicSourceIsRejected() {
        #expect(evaluate("8.8.8.8", host: "192.168.1.10:47057", origin: nil) == .sourceNotLocal)
        #expect(evaluate("2001:4860:4860::8888", host: "192.168.1.10:47057", origin: nil) == .sourceNotLocal)
        #expect(evaluate("172.32.0.1", host: "192.168.1.10:47057", origin: nil) == .sourceNotLocal)
        #expect(evaluate("fd00::1", host: "192.168.1.10:47057", origin: nil) == .sourceNotLocal)
        #expect(evaluate("garbage", host: "192.168.1.10:47057", origin: nil) == .sourceNotLocal)
    }

    @Test func ipv4MappedIPv6IsUnwrapped() {
        #expect(evaluate("::ffff:192.168.1.20", host: "192.168.1.10:47057", origin: nil) == nil)
        #expect(evaluate("::ffff:8.8.8.8", host: "192.168.1.10:47057", origin: nil) == .sourceNotLocal)
    }

    @Test func addressClassification() {
        #expect(IPAddressLiteral("10.1.2.3")?.isPrivateRFC1918 == true)
        #expect(IPAddressLiteral("172.16.0.1")?.isPrivateRFC1918 == true)
        #expect(IPAddressLiteral("172.31.255.255")?.isPrivateRFC1918 == true)
        #expect(IPAddressLiteral("192.168.0.1")?.isPrivateRFC1918 == true)
        #expect(IPAddressLiteral("169.254.10.1")?.isLinkLocal == true)
        #expect(IPAddressLiteral("febf::1")?.isLinkLocal == true)
        #expect(IPAddressLiteral("fec0::1")?.isLinkLocal == false)
        #expect(IPAddressLiteral("127.8.8.8")?.isLoopback == true)
    }

    @Test func throttleStartsAfterFiveFailuresAndGrows() {
        var throttle = FailureThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<4 {
            throttle.recordFailure(for: "192.168.1.20", now: start.addingTimeInterval(Double(index)))
            #expect(throttle.retryDelay(for: "192.168.1.20", now: start.addingTimeInterval(Double(index))) == 0)
        }
        throttle.recordFailure(for: "192.168.1.20", now: start.addingTimeInterval(4))
        #expect(throttle.retryDelay(for: "192.168.1.20", now: start.addingTimeInterval(4)) == 1)
        throttle.recordFailure(for: "192.168.1.20", now: start.addingTimeInterval(5))
        #expect(throttle.retryDelay(for: "192.168.1.20", now: start.addingTimeInterval(5)) == 2)
        #expect(throttle.retryDelay(for: "192.168.1.21", now: start.addingTimeInterval(5)) == 0)
        for index in 0..<20 {
            throttle.recordFailure(for: "192.168.1.20", now: start.addingTimeInterval(6 + Double(index)))
        }
        #expect(throttle.retryDelay(for: "192.168.1.20", now: start.addingTimeInterval(25)) == FailureThrottle.maxDelay)
    }

    @Test func throttleResetsOnSuccessAndAfterQuietPeriod() {
        var throttle = FailureThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<6 { throttle.recordFailure(for: "a", now: start) }
        #expect(throttle.retryDelay(for: "a", now: start) > 0)
        throttle.recordSuccess(for: "a")
        #expect(throttle.retryDelay(for: "a", now: start) == 0)
        for _ in 0..<6 { throttle.recordFailure(for: "b", now: start) }
        #expect(throttle.retryDelay(for: "b", now: start.addingTimeInterval(FailureThrottle.forgetAfter)) == 0)
        throttle.recordFailure(for: "b", now: start.addingTimeInterval(FailureThrottle.forgetAfter))
        #expect(throttle.failureCount(for: "b") == 1)
    }
}
