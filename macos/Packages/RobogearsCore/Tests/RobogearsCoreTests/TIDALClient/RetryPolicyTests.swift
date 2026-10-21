import Foundation
import Testing
@testable import RobogearsCore

/// The shared retry rule from decision G1-4.
@Suite("Retry policy")
struct RetryPolicyTests {
    let policy = RetryPolicy.standard

    @Test func serverErrorsBackOffOneTwoFourEightSecondsThenGiveUp() {
        let waits = (0..<5).map { policy.decision(after: .status(503, retryAfter: nil), retriesSoFar: $0) }
        #expect(waits == [
            .retry(after: .seconds(1)), .retry(after: .seconds(2)),
            .retry(after: .seconds(4)), .retry(after: .seconds(8)), .giveUp,
        ])
    }

    @Test func tooManyRequestsWaitsAsLongAsRetryAfterSays() {
        #expect(policy.decision(after: .status(429, retryAfter: .seconds(7)), retriesSoFar: 0) == .retry(after: .seconds(7)))
        #expect(policy.decision(after: .status(429, retryAfter: .seconds(60)), retriesSoFar: 3) == .retry(after: .seconds(60)))
    }

    @Test func retryAfterLongerThanSixtySecondsGivesUpAtOnceAsBusy() {
        #expect(policy.decision(after: .status(429, retryAfter: .seconds(61)), retriesSoFar: 0) == .giveUp)
    }

    @Test func tooManyRequestsWithoutRetryAfterUsesTheBackoffSteps() {
        #expect(policy.decision(after: .status(429, retryAfter: nil), retriesSoFar: 2) == .retry(after: .seconds(4)))
    }

    @Test func notFoundForbiddenAndOtherAnswersAreNeverRetried() {
        for status in [400, 401, 403, 404, 409, 302] {
            #expect(policy.decision(after: .status(status, retryAfter: nil), retriesSoFar: 0) == .giveUp)
        }
    }

    @Test func timeoutsAndDroppedConnectionsAreRetried() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed] {
            #expect(policy.decision(after: .transport(code), retriesSoFar: 0) == .retry(after: .seconds(1)))
        }
    }

    @Test func certificateFailuresAreNotRetried() {
        #expect(policy.decision(after: .transport(.serverCertificateUntrusted), retriesSoFar: 0) == .giveUp)
        #expect(policy.decision(after: .transport(.secureConnectionFailed), retriesSoFar: 0) == .giveUp)
    }

    @Test func neverPolicyTriesOnce() {
        #expect(RetryPolicy.never.decision(after: .status(503, retryAfter: nil), retriesSoFar: 0) == .giveUp)
    }

    @Test func retryAfterReadsWholeSeconds() {
        #expect(RetryPolicy.parseRetryAfter("30", now: TIDALClientFixtures.start) == .seconds(30))
        #expect(RetryPolicy.parseRetryAfter(" 2 ", now: TIDALClientFixtures.start) == .seconds(2))
        #expect(RetryPolicy.parseRetryAfter("-4", now: TIDALClientFixtures.start) == .zero)
    }

    @Test func retryAfterReadsAnHTTPDateRelativeToNow() {
        // 1_800_000_000 is Fri, 15 Jan 2027 08:00:00 GMT.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RetryPolicy.parseRetryAfter("Fri, 15 Jan 2027 08:00:45 GMT", now: now) == .seconds(45))
        #expect(RetryPolicy.parseRetryAfter("Fri, 15 Jan 2027 07:59:00 GMT", now: now) == .zero)
    }

    @Test func unreadableRetryAfterIsIgnored() {
        #expect(RetryPolicy.parseRetryAfter("soon", now: TIDALClientFixtures.start) == nil)
    }
}
