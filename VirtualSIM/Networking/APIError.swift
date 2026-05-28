import Foundation

enum APIError: Error, LocalizedError {
    case badResponse
    case http(status: Int, body: String?)
    case decoding(Error)
    case notAuthenticated
    case appleSignInCanceled
    case appleSignInFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse:                return "Bad response"
        case .http(let s, let b):         return "HTTP \(s)\(b.map { ": \($0)" } ?? "")"
        case .decoding(let err):          return "Decoding error: \(err.localizedDescription)"
        case .notAuthenticated:           return "Not signed in"
        case .appleSignInCanceled:        return "Sign in canceled"
        case .appleSignInFailed(let msg): return "Sign in failed: \(msg)"
        }
    }
}
