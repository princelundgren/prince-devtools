import Darwin
import Foundation
import System

/// The effective per-user process limit: the smaller of the soft `RLIMIT_NPROC` and
/// `kern.maxprocperuid`, where a zero or unlimited (`RLIM_INFINITY`, which is `Int64.max` and so
/// never below the per-user limit) soft limit defers to the latter. `maxProcPerUID` must be positive.
public func effectiveProcessLimit(softLimit: rlim_t, maxProcPerUID: Int) -> Int {
    guard softLimit != 0, softLimit < rlim_t(maxProcPerUID) else {
        return maxProcPerUID
    }
    return Int(softLimit)
}

/// The usage of each pid that `read` can read, in `pids` order; a pid whose read fails (it exited,
/// or belongs to another user) is skipped.
public func processUsages(pids: [pid_t], read: (pid_t) -> Result<ProcessUsage, Errno>) -> [ProcessUsage] {
    pids.compactMap { try? read($0).get() }
}

/// Reads the machine's health figures from the kernel. No function blocks or traps, and all but
/// ``processUsages()``, which walks every process, are a few syscalls. One that cannot read its
/// figure returns `nil` (or an empty list); ``thermalLevel()`` always returns a level.
public enum SystemReader {
    /// Kernel clock ticks per second, the unit of ``CPUTicks``.
    public static let ticksPerSecond = Int(sysconf(_SC_CLK_TCK))

    /// The memory pressure level, or `nil` when the kernel cannot be read or reports a value
    /// other than 1, 2 or 4. The sysctl is not in the SDK, so this is its only reader.
    public static func memoryLevel() -> MemoryLevel? {
        var value: Int32 = 0
        guard sysctl("kern.memorystatus_vm_pressure_level", into: &value) else { return nil }
        return MemoryLevel(sysctlValue: value)
    }

    /// Bytes of swap in use, or `nil` when `vm.swapusage` cannot be read.
    public static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        guard sysctl("vm.swapusage", into: &usage) else { return nil }
        return usage.xsu_used
    }

    /// The cumulative CPU tick counters over all cores, or `nil` when the host cannot be read.
    public static func cpuTicks() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    /// Bytes free to this user on the startup volume (`f_bavail` times `f_bsize`, not the "important
    /// usage" figure), or `nil` when `statfs` fails.
    public static func diskFreeBytes() -> UInt64? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        return UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
    }

    /// The number of processes this user runs, including any whose usage cannot be read, or `nil`
    /// when the process list cannot be read.
    public static func processCount() -> Int? {
        ownPIDs()?.count
    }

    /// The usage of every readable process of this user, empty when the process list cannot be read.
    /// Names are the last component of the executable path, not the 32-character `proc_name`.
    public static func processUsages() -> [ProcessUsage] {
        SystemHealth.processUsages(pids: ownPIDs() ?? [], read: readUsage)
    }

    /// How many processes this user may run (see ``effectiveProcessLimit(softLimit:maxProcPerUID:)``),
    /// or `nil` when the limits cannot be read or `kern.maxprocperuid` is not positive.
    public static func processLimit() -> Int? {
        var limit = rlimit()
        var maxProcPerUID: Int32 = 0
        guard getrlimit(RLIMIT_NPROC, &limit) == 0, sysctl("kern.maxprocperuid", into: &maxProcPerUID),
            maxProcPerUID > 0
        else {
            return nil
        }
        return effectiveProcessLimit(softLimit: limit.rlim_cur, maxProcPerUID: Int(maxProcPerUID))
    }

    /// The system's thermal state.
    public static func thermalLevel() -> ThermalLevel {
        ThermalLevel(ProcessInfo.processInfo.thermalState)
    }

    private static func sysctl<Value>(_ name: String, into value: inout Value) -> Bool {
        withUnsafeMutableBytes(of: &value) { buffer in
            var size = buffer.count
            return sysctlbyname(name, buffer.baseAddress, &size, nil, 0) == 0 && size == buffer.count
        }
    }

    private static func ownPIDs() -> [pid_t]? {
        let uid = getuid()
        let wanted = proc_listpids(UInt32(PROC_RUID_ONLY), uid, nil, 0)
        guard wanted > 0 else { return nil }

        var pids = [pid_t](repeating: 0, count: Int(wanted) / MemoryLayout<pid_t>.stride * 6 / 5 + 1)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_RUID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 != 0 }
    }

    private static func readUsage(of pid: pid_t) -> Result<ProcessUsage, Errno> {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return .failure(Errno(rawValue: errno)) }

        var path = [UInt8](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        guard pathLength > 0 else { return .failure(Errno(rawValue: errno)) }
        let executablePath = FilePath(String(decoding: path.prefix(Int(pathLength)), as: UTF8.self))
        guard let name = executablePath.lastComponent?.string else { return .failure(.invalidArgument) }

        return .success(
            ProcessUsage(
                pid: pid,
                name: name,
                footprintBytes: info.ri_phys_footprint,
                cpuTime: info.ri_user_time &+ info.ri_system_time))
    }
}
