import Foundation

/// Why a read of a Docker Engine API socket gave no body: nothing runs there, or something does
/// and couldn't be read.
public enum SocketReadError: Error, Equatable, Sendable {
    /// Nothing listens: the file is missing, isn't a socket, or refuses the connection.
    case notRunning
    /// A request target that isn't visible ASCII, any other connection error, a status other than
    /// 200, a body the app can't read, a response over the request's limit, or no response within
    /// the timeout. The text says which.
    case failed(String)
}
