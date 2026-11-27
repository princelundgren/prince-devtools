import Containers
import SwiftUI

/// The panel's second view for the Containers card: a table of the running containers, largest
/// memory first, under a header with Back, and a line under it for each runtime that couldn't be
/// read. A click on a name or image copies it.
struct ContainerListView: View {
    let monitor: ContainerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListHeader(title: ContainerText.title, back: monitor.hideList)
            if let scan = monitor.scan {
                rows(scan)
                ForEach(scan.unreadableRuntimes, id: \.self) { runtime in
                    Text(ContainerText.unreadable(runtime))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func rows(_ scan: ContainerScan) -> some View {
        if scan.containers.isEmpty {
            if let emptyList = ContainerText.emptyList(scan) {
                Text(emptyList)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                ColumnTitles<ContainerColumn>()
                Divider()
                if scan.containers.count > ListScrolling.rowsBeforeScrolling {
                    ScrollView { LazyVStack(spacing: 0) { containerRows(scan) } }
                        .frame(height: ListScrolling.height)
                } else {
                    VStack(spacing: 0) { containerRows(scan) }
                }
            }
        }
    }

    private func containerRows(_ scan: ContainerScan) -> some View {
        ForEach(scan.containers) { container in
            ContainerRow(text: ContainerText.row(container, now: scan.time, locale: .current))
        }
    }
}

/// The container table's columns, in order.
private enum ContainerColumn: ListColumn {
    case name, image, runtime, up, memory

    var isClickable: Bool {
        switch self {
        case .name, .image: true
        case .runtime, .up, .memory: false
        }
    }

    var title: String {
        switch self {
        case .name: "Name"
        case .image: "Image"
        case .runtime: "Runtime"
        case .up: "Up"
        case .memory: "Memory"
        }
    }

    var width: CGFloat? {
        switch self {
        case .name, .image: nil
        case .runtime: 104
        case .up: 52
        case .memory: 72
        }
    }

    var alignment: Alignment {
        switch self {
        case .name, .image, .runtime: .leading
        case .up, .memory: .trailing
        }
    }
}

extension View {
    fileprivate func column(_ column: ContainerColumn) -> some View { columnFrame(column) }
}

/// One container on one line; clicking its name or image copies it.
private struct ContainerRow: View {
    let text: ContainerRowText

    var body: some View {
        HStack(spacing: ContainerColumn.spacing) {
            ActionCell(help: "Copy \(text.name)", confirms: true, action: { copyToPasteboard(text.name) }) {
                Text(text.name).lineLimit(1)
            }
            .column(.name)
            ActionCell(help: text.copyImage, confirms: true, action: { copyToPasteboard(text.imageReference) }) {
                Text(text.image).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .column(.image)
            Text(text.runtime)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .column(.runtime)
            Text(text.up)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(text.spokenUp)
                .column(.up)
            Text(text.memory)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(text.spokenMemory)
                .column(.memory)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, ListInset.row)
        .contentShape(Rectangle())
        .help(text.description)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text.description)
    }
}
