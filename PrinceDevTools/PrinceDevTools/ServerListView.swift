import AppKit
import LocalServers
import os
import PanelKit
import SwiftUI

/// The panel's second view: a table of the servers listening, orphaned first, each row offering
/// actions on its cells and its menu, under a header with Back and above Open Activity Monitor.
/// A stop asks first, and says so when it fails.
struct ServerListView: View {
    private static let logger = Logger(subsystem: "com.princelundgren.princedevtools", category: "ServerList")

    let monitor: ServerMonitor
    @State private var pendingStop: PendingStop?
    @State private var stopFailure: String?

    private struct PendingStop {
        let server: Server
        let signal: StopSignal
        var confirmation: StopConfirmation { ServerText.stopConfirmation(server, with: signal) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListHeader(title: ServerText.title, back: monitor.hideList)
            rows
            Button("Open Activity Monitor", action: ActivityMonitor.open)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .confirmationDialog(
            pendingStop?.confirmation.title ?? "", isPresented: isAsking(), titleVisibility: .visible,
            presenting: pendingStop
        ) { pending in
            Button(pending.confirmation.button, role: .destructive) {
                stopFailure = ServerText.stopFailure(
                    monitor.stop(pending.server, with: pending.signal), port: pending.server.port)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.confirmation.message)
        }
        .alert(stopFailure ?? "", isPresented: isShowingFailure()) {
            Button("OK") {}
        }
    }

    private func isAsking() -> Binding<Bool> {
        Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } })
    }

    private func isShowingFailure() -> Binding<Bool> {
        Binding(get: { stopFailure != nil }, set: { if !$0 { stopFailure = nil } })
    }

    @ViewBuilder private var rows: some View {
        if let scan = monitor.scan {
            if scan.servers.isEmpty {
                Text(ServerText.emptyList)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ColumnTitles<ServerColumn>()
                    Divider()
                    if scan.servers.count > ListScrolling.rowsBeforeScrolling {
                        ScrollView { rowStack(scan) }
                            .frame(height: ListScrolling.height)
                    } else {
                        rowStack(scan)
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    private func rowStack(_ scan: ServerScan) -> some View {
        VStack(spacing: 0) {
            ForEach(scan.servers) { server in
                ServerRow(
                    text: ServerText.row(server, now: scan.time, home: monitor.homeFolder, locale: .current),
                    isOrphaned: server.isParentGone,
                    folder: server.isFolderGone ? nil : server.folderPath.map { URL(filePath: $0) },
                    link: Self.link(port: server.port),
                    stop: { pendingStop = PendingStop(server: server, signal: $0) })
            }
        }
    }

    private static func link(port: UInt16) -> URL? {
        let url = URL(string: "http://localhost:\(port)")
        if url == nil { logger.error("No URL for port \(port, privacy: .public)") }
        return url
    }
}

/// The server table's columns, in order.
private enum ServerColumn: ListColumn {
    case port, process, pid, folder, running, orphaned, more

    var isClickable: Bool {
        switch self {
        case .port, .process, .pid, .folder: true
        case .running, .orphaned, .more: false
        }
    }

    var title: String {
        switch self {
        case .port: "Port"
        case .process: "Process"
        case .folder: "Folder"
        case .pid: "PID"
        case .running: "Running"
        case .orphaned: "Orphaned"
        case .more: ""
        }
    }

    var width: CGFloat? {
        switch self {
        case .port: 52
        case .process, .folder: nil
        case .pid: 48
        case .running: 56
        case .orphaned: 60
        case .more: 20
        }
    }

    var alignment: Alignment {
        switch self {
        case .port, .process, .folder: .leading
        case .pid, .running: .trailing
        case .orphaned, .more: .center
        }
    }
}

extension View {
    fileprivate func column(_ column: ServerColumn) -> some View { columnFrame(column) }
}

/// One server on one line, ⚠ when orphaned. Clicking the port copies its link, the name or pid
/// copies it, and the folder shows it in Finder; right-click, or the … that shows under the
/// pointer, offers those and the row's other actions.
private struct ServerRow: View {
    private static let menuSide: CGFloat = 20

    let text: ServerRowText
    let isOrphaned: Bool
    /// `nil` when the folder is gone or unknown.
    let folder: URL?
    let link: URL?
    let stop: (StopSignal) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: ServerColumn.spacing) {
            ActionCell(help: "Copy \(link?.absoluteString ?? "")", isEnabled: link != nil, confirms: true, action: copyLink) {
                Text(text.port).monospacedDigit()
            }
            .column(.port)
            ActionCell(help: "Copy \(text.name)", confirms: true, action: { copyToPasteboard(text.name) }) {
                Text(text.name).lineLimit(1)
            }
            .column(.process)
            ActionCell(help: "Copy PID \(text.pid)", confirms: true, action: { copyToPasteboard(text.pid) }) {
                Text(text.pid).foregroundStyle(.secondary).monospacedDigit()
            }
            .column(.pid)
            ActionCell(help: "Show in Finder", isEnabled: folder != nil, confirms: false, action: showFolder) {
                Text(text.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .column(.folder)
            Text(text.running)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(text.spokenRunning)
                .column(.running)
            if isOrphaned {
                orphanedIcon.column(.orphaned)
            } else {
                orphanedIcon.hidden().accessibilityHidden(true).column(.orphaned)
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: Self.menuSide, height: Self.menuSide)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .pointerStyle(.link)
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("More actions for port \(text.port)")
            .help("More actions")
            .column(.more)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, ListInset.row)
        .contentShape(Rectangle())
        .help(text.description)
        .onHover { isHovered = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text.description)
    }

    /// Hidden rather than left out in a healthy row, so every row keeps the column's width.
    private var orphanedIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(PanelTone.yellow.color)
            .help(ServerText.orphanedHelp)
    }

    @ViewBuilder private var actions: some View {
        Button("Open in Browser", action: openLink)
            .disabled(link == nil)
        Button("Copy Link", action: copyLink)
            .disabled(link == nil)
        Button("Copy PID") { copyToPasteboard(text.pid) }
        Button("Show Folder in Finder", action: showFolder)
            .disabled(folder == nil)
        Divider()
        Button("Stop Server…") { stop(.terminate) }
        Button("Force Stop Server…") { stop(.kill) }
    }

    private func openLink() {
        if let link { NSWorkspace.shared.open(link) }
    }

    private func copyLink() {
        if let link { copyToPasteboard(link.absoluteString) }
    }

    private func showFolder() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }
}
