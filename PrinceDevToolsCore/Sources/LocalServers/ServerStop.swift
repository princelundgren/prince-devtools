import Darwin

/// How a server is asked to stop.
public enum StopSignal: Sendable {
    /// `SIGTERM`: the server may clean up first.
    case terminate
    /// `SIGKILL`: it stops at once.
    case kill

    var number: Int32 {
        switch self {
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
    }
}

public enum StopResult: Sendable, Equatable {
    case sent
    /// The pid has exited, or now belongs to another process.
    case processChanged
    /// The kernel refused, with this `errno`.
    case failed(Int32)
}

public enum ServerStop {
    /// Sends `signal` to `server`'s process if its pid still belongs to the process the scan read,
    /// judged by its start time, since the list can be a scan old and pids are reused. A pid of 0
    /// or below, which `kill(2)` sends to a process group, is never signalled. `send` returns 0 or
    /// an `errno`.
    public static func stop(
        _ server: Server, with signal: StopSignal, source: ServerSource,
        send: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) == 0 ? 0 : errno }
    ) -> StopResult {
        guard server.pid > 0, source.process(server.pid)?.startTime == server.startTime else {
            return .processChanged
        }
        let error = send(server.pid, signal.number)
        if error == 0 { return .sent }
        return error == ESRCH ? .processChanged : .failed(error)
    }
}
