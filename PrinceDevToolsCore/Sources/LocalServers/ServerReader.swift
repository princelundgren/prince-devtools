import Darwin
import Foundation
import SystemHealth

/// Reads listening sockets and process facts from the kernel through libproc. No function blocks or
/// traps; one that cannot read its figure returns `nil` or an empty list.
public enum ServerReader {
    /// Every TCP socket in the LISTEN state held by this user's processes; a process whose
    /// descriptors can't be read (it exited, or isn't readable) is skipped.
    public static func listeningSockets() -> [ListeningSocket] {
        (SystemReader.ownPIDs() ?? []).flatMap(listeningSockets(of:))
    }

    /// The parent, start time and working folder of `pid`, or `nil` once it has exited, when the read
    /// is short, or when it isn't this user's process. A failed folder read gives `.unreadable`.
    public static func process(of pid: pid_t) -> ProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ruid == getuid() else {
            return nil
        }
        let start = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return ProcessRecord(
            pid: pid, parentPID: pid_t(info.pbi_ppid), startTime: Date(timeIntervalSince1970: start),
            folder: folder(of: pid))
    }

    /// What `lstat` finds at `path`: its identity, `.missing` for `ENOENT`, `.unknown` for any other error.
    public static func checkFolder(_ path: String) -> FolderCheck {
        var status = stat()
        guard lstat(path, &status) == 0 else { return errno == ENOENT ? .missing : .unknown }
        return .exists(FileIdentity(inode: status.st_ino, device: UInt32(bitPattern: status.st_dev)))
    }

    /// The first port the kernel hands out for a bind to port 0 (`net.inet.ip.portrange.first`),
    /// 49152 when it can't be read or is outside 1...65535.
    public static func portFloor() -> UInt16 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("net.inet.ip.portrange.first", &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size,
            (1...65535).contains(value)
        else {
            return 49152
        }
        return UInt16(value)
    }

    private static func listeningSockets(of pid: pid_t) -> [ListeningSocket] {
        let wanted = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard wanted > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(wanted) / stride + 8)
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return descriptors.prefix(Int(bytes) / stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .compactMap { listeningSocket(pid: pid, fd: $0.proc_fd) }
    }

    private static func listeningSocket(pid: pid_t, fd: Int32) -> ListeningSocket? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
            info.psi.soi_kind == Int32(SOCKINFO_TCP), info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
        else {
            return nil
        }
        let inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
        guard let address = localAddress(of: inet, family: info.psi.soi_family) else { return nil }
        return ListeningSocket(
            pid: pid, socketHandle: info.psi.soi_so, port: UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)),
            address: address)
    }

    /// Chosen by socket family, not `insi_vflag`: a dual-stack listener on `::` has both flag bits set.
    private static func localAddress(of inet: in_sockinfo, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var local = inet.insi_laddr
        let text: UnsafePointer<CChar>?
        switch family {
        case AF_INET6:
            text = inet_ntop(AF_INET6, &local.ina_6, &buffer, socklen_t(buffer.count))
        case AF_INET:
            text = inet_ntop(AF_INET, &local.ina_46.i46a_addr4, &buffer, socklen_t(buffer.count))
        default:
            return nil
        }
        return text.map { String(cString: $0) }
    }

    private static func folder(of pid: pid_t) -> FolderReading {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return .unreadable }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let stat = info.pvi_cdir.vip_vi.vi_stat
        return .path(path, identity: FileIdentity(inode: stat.vst_ino, device: stat.vst_dev))
    }
}

extension ServerSource {
    /// The live kernel's servers, for the running app.
    public static let live = ServerSource(
        listeningSockets: ServerReader.listeningSockets,
        process: ServerReader.process(of:),
        processName: SystemReader.processName(of:),
        checkFolder: ServerReader.checkFolder,
        portFloor: ServerReader.portFloor,
        homeFolder: NSHomeDirectory(),
        now: Date.init)
}
