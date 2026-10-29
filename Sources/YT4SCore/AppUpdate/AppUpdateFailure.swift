import Foundation

/// Why an app update did not install. The current version always stays (ADR 0002).
public enum AppUpdateFailure: Sendable, Equatable {
    /// GitHub (the appcast or the zip) could not be reached.
    case offline
    /// The zip's EdDSA signature did not match the public key in the app.
    case badSignature
    case other

    /// Classifies an error Sparkle reported (domain `SUSparkleErrorDomain`, codes from SUErrors.h).
    public init(sparkleError error: Error) {
        let error = error as NSError
        if Self.hasURLError(error) {
            self = .offline
        } else if error.domain == Self.sparkleDomain, Self.signatureCodes.contains(error.code) {
            self = .badSignature
        } else {
            self = .other
        }
    }

    private static let sparkleDomain = "SUSparkleErrorDomain"
    /// SUSignatureError, SUValidationError.
    private static let signatureCodes: Set<Int> = [3001, 3002]

    private static func hasURLError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return hasURLError(underlying)
    }

    /// The plain two-line footer explanation.
    public func message(currentVersion: String) -> String {
        switch self {
        case .offline:
            """
            YT4S couldn't reach GitHub, so it stayed on version \(currentVersion).
            Check your internet connection, then click Update app again.
            """
        case .badSignature:
            """
            The downloaded update failed its security check, so it was not installed.
            YT4S stayed on version \(currentVersion). Tell Nick.
            """
        case .other:
            """
            The update didn't install, so YT4S stayed on version \(currentVersion).
            Try Update app again later. If it keeps failing, tell Nick.
            """
        }
    }
}
