import IOKit
import IOKit.pwr_mgt

/// What the app does with one message from the root power domain.
public enum SystemPowerResponse: Equatable {
    /// Forward sleep, then acknowledge with `IOAllowPowerChange`.
    case sleepThenAcknowledge
    /// Acknowledge only; the app never vetoes an idle sleep.
    case acknowledge
    /// Forward wake; the message takes no acknowledgement.
    case wake
    /// Nothing, and no acknowledgement.
    case ignore

    // `iokit_common_msg(n)` is `0xE000_0000 | n`; Swift doesn't import these macros (IOMessage.h).
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300

    /// The response to one root-domain message; an unknown message is `.ignore`.
    public init(message: natural_t) {
        switch message {
        case Self.systemWillSleep: self = .sleepThenAcknowledge
        case Self.canSystemSleep: self = .acknowledge
        case Self.systemHasPoweredOn: self = .wake
        default: self = .ignore
        }
    }

    /// Whether the message must be acknowledged with `IOAllowPowerChange`.
    public var acknowledges: Bool {
        switch self {
        case .sleepThenAcknowledge, .acknowledge: true
        case .wake, .ignore: false
        }
    }
}

/// Reports sleep and wake from IOKit's root power domain, which delivers messages only over the
/// sleep and wake lifecycle. Main actor only; the closures run on the main queue.
@MainActor
public final class SystemPowerObserver {
    private let willSleep: () -> Void
    private let didWake: () -> Void
    private var rootPort: io_connect_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL

    /// An observer that calls `willSleep` before acknowledging sleep and `didWake` once the system
    /// has powered on, on the main queue; registers nothing until `start()`.
    public init(willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
    }

    /// Registers with the root power domain. Does nothing if already started; if IOKit refuses,
    /// the observer stays unregistered. Call `stop()` before releasing it.
    public func start() {
        guard rootPort == IO_OBJECT_NULL else { return }
        var port: IONotificationPortRef?
        var notifier: io_object_t = IO_OBJECT_NULL
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let rootPort = IORegisterForSystemPower(refcon, &port, systemPowerCallback, &notifier)
        guard rootPort != IO_OBJECT_NULL, let port else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        self.rootPort = rootPort
        self.notificationPort = port
        self.notifier = notifier
    }

    /// Deregisters and releases the IOKit objects, in the order the headers require. Idempotent.
    public func stop() {
        guard rootPort != IO_OBJECT_NULL else { return }
        IODeregisterForSystemPower(&notifier)
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        IOServiceClose(rootPort)
        notifier = IO_OBJECT_NULL
        notificationPort = nil
        rootPort = IO_OBJECT_NULL
    }

    fileprivate func handle(message: natural_t, notificationID: Int) {
        let response = SystemPowerResponse(message: message)
        switch response {
        case .sleepThenAcknowledge: willSleep()
        case .wake: didWake()
        case .acknowledge, .ignore: break
        }
        if response.acknowledges {
            IOAllowPowerChange(rootPort, notificationID)
        }
    }
}

private func systemPowerCallback(
    refcon: UnsafeMutableRawPointer?, service: io_service_t, message: natural_t,
    argument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<SystemPowerObserver>.fromOpaque(refcon).takeUnretainedValue()
    let notificationID = Int(bitPattern: argument)
    MainActor.assumeIsolated { observer.handle(message: message, notificationID: notificationID) }
}
