import Foundation
import Testing
@testable import YT4SCore

/// Sparkle reports failures as NSErrors in `SUSparkleErrorDomain` (codes from Sparkle's SUErrors.h),
/// often wrapping the URL loading error underneath.
@Suite struct AppUpdateFailureTests {
    @Test func noNetworkWhileFetchingTheAppcastIsOffline() {
        let error = sparkle(1002, underlying: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(AppUpdateFailure(sparkleError: error) == .offline)
    }

    @Test func aDroppedDownloadIsOffline() {
        let error = sparkle(2001, underlying: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        #expect(AppUpdateFailure(sparkleError: error) == .offline)
    }

    @Test func aBareURLErrorIsOffline() {
        #expect(AppUpdateFailure(sparkleError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) == .offline)
    }

    @Test(arguments: [3001, 3002])
    func aSignatureOrValidationErrorIsABadSignature(code: Int) {
        #expect(AppUpdateFailure(sparkleError: sparkle(code)) == .badSignature)
    }

    @Test(arguments: [1000, 3000, 4000, 4005])
    func anythingElseIsAPlainFailure(code: Int) {
        #expect(AppUpdateFailure(sparkleError: sparkle(code)) == .other)
    }

    @Test func aDownloadErrorWithoutANetworkCauseIsAPlainFailure() {
        #expect(AppUpdateFailure(sparkleError: sparkle(2001)) == .other)
    }

    private func sparkle(_ code: Int, underlying: NSError? = nil) -> NSError {
        NSError(
            domain: "SUSparkleErrorDomain",
            code: code,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
        )
    }
}
