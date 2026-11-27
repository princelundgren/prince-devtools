import CryptoKit
import Foundation

/// What `DockerSockets` reads from the disk, so tests can supply their own. Every closure is
/// quick and synchronous, and may be called off the main actor.
public struct SocketFiles: Sendable {
    public var homeFolder: String
    /// `NSTemporaryDirectory()` live, where Podman keeps its sockets.
    public var temporaryFolder: String
    /// `nil` when the file is unreadable.
    public var contents: @Sendable (String) -> Data?
    public var directoryEntries: @Sendable (String) -> [String]
    /// The path with symlinks resolved, `nil` when nothing is there.
    public var resolvedPath: @Sendable (String) -> String?
    /// The account the app runs as: `getuid()` live.
    public var userID: uid_t
    /// The owner of the file at a resolved path, `nil` when it can't be read.
    public var ownerID: @Sendable (String) -> uid_t?

    public init(
        homeFolder: String,
        temporaryFolder: String,
        contents: @escaping @Sendable (String) -> Data?,
        directoryEntries: @escaping @Sendable (String) -> [String],
        resolvedPath: @escaping @Sendable (String) -> String?,
        userID: uid_t,
        ownerID: @escaping @Sendable (String) -> uid_t?
    ) {
        self.homeFolder = homeFolder
        self.temporaryFolder = temporaryFolder
        self.contents = contents
        self.directoryEntries = directoryEntries
        self.resolvedPath = resolvedPath
        self.userID = userID
        self.ownerID = ownerID
    }

    public static var live: SocketFiles {
        SocketFiles(
            homeFolder: NSHomeDirectory(),
            temporaryFolder: NSTemporaryDirectory(),
            contents: { FileManager.default.contents(atPath: $0) },
            directoryEntries: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            resolvedPath: { path in
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
            },
            userID: getuid(),
            ownerID: { path in
                (try? FileManager.default.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber)?
                    .uint32Value
            })
    }
}

public enum DockerSockets {
    private static let podmanSuffix = "-api.sock"

    /// The sockets to try, in the spec's order, each existing path once: the first path to resolve
    /// to a socket keeps its name. A socket is kept only if the user owns both it and its folder:
    /// in another account's folder, that account can swap the file, or hard-link the user's own
    /// socket there and swap it later, and so answer the app's requests. Names taken from the disk
    /// pass through ``DisplayText``.
    public static func candidates(in files: SocketFiles) -> [RuntimeSocket] {
        let home = files.homeFolder
        var named: [(path: String, runtime: String)] = [
            ("\(home)/.orbstack/run/docker.sock", "OrbStack"),
            ("\(home)/.docker/run/docker.sock", "Docker Desktop"),
            ("\(home)/.rd/docker.sock", "Rancher Desktop")
        ]
        let profiles = files.directoryEntries("\(home)/.colima").map { profile in
            (path: "\(home)/.colima/\(profile)/docker.sock",
             runtime: profile == "default" ? "Colima" : "Colima (\(DisplayText.sanitized(profile)))")
        }
        named += profiles.sorted { $0.runtime < $1.runtime }
        let podmanFolder = (files.temporaryFolder as NSString).appendingPathComponent("podman")
        let machines = files.directoryEntries(podmanFolder).filter { $0.hasSuffix(podmanSuffix) }.map { entry in
            let machine = String(entry.dropLast(podmanSuffix.count))
            return (path: "\(podmanFolder)/\(entry)",
                    runtime: machine == "podman-machine-default" ? "Podman" : "Podman (\(DisplayText.sanitized(machine)))")
        }
        named += machines.sorted { $0.runtime < $1.runtime }
        if let context = activeContextSocket(in: files) { named.append(context) }
        named.append(("/var/run/docker.sock", "Docker"))

        var seen = Set<String>()
        return named.compactMap { candidate in
            guard let resolved = files.resolvedPath(candidate.path), isUsers(resolved, in: files),
                seen.insert(resolved).inserted
            else { return nil }
            return RuntimeSocket(path: resolved, runtime: candidate.runtime)
        }
    }

    private static func isUsers(_ socket: String, in files: SocketFiles) -> Bool {
        let folder = (socket as NSString).deletingLastPathComponent
        return files.ownerID(socket) == files.userID && files.ownerID(folder) == files.userID
    }

    /// The folder `docker context` keeps a context's meta file in: the lowercase hex SHA-256 of its name.
    static func contextFolderName(_ context: String) -> String {
        SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Config: Decodable { let currentContext: String? }

    private struct ContextMeta: Decodable {
        struct Endpoints: Decodable {
            struct Endpoint: Decodable { let Host: String? }
            let docker: Endpoint?
        }
        let Endpoints: Endpoints?
    }

    private static func activeContextSocket(in files: SocketFiles) -> (path: String, runtime: String)? {
        let docker = "\(files.homeFolder)/.docker"
        guard let config = files.contents("\(docker)/config.json"),
            let name = (try? JSONDecoder().decode(Config.self, from: config))?.currentContext,
            let meta = files.contents("\(docker)/contexts/meta/\(contextFolderName(name))/meta.json"),
            let host = (try? JSONDecoder().decode(ContextMeta.self, from: meta))?.Endpoints?.docker?.Host,
            host.hasPrefix("unix:///")
        else { return nil }
        return (String(host.dropFirst("unix://".count)), DisplayText.sanitized(name))
    }
}
