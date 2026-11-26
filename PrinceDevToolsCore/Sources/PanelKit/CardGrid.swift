import SwiftUI

/// Lays cards out in two equal columns, every cell as tall as the tallest card, so all cards share
/// one size whatever lines each one shows.
public struct CardGrid: Layout {
    private let spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cell = cellSize(proposedWidth: proposal.width, subviews: subviews)
        let rows = (subviews.count + 1) / 2
        return CGSize(
            width: 2 * cell.width + spacing,
            height: CGFloat(rows) * cell.height + CGFloat(max(rows - 1, 0)) * spacing)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellSize(proposedWidth: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = CGPoint(
                x: bounds.minX + CGFloat(index % 2) * (cell.width + spacing),
                y: bounds.minY + CGFloat(index / 2) * (cell.height + spacing))
            subview.place(at: origin, proposal: ProposedViewSize(cell))
        }
    }

    /// Half the proposed width each, or the widest card's ideal width when no width is proposed.
    private func cellSize(proposedWidth: CGFloat?, subviews: Subviews) -> CGSize {
        let width = proposedWidth.map { max(0, ($0 - spacing) / 2) }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let tallest = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max()
        return CGSize(width: width, height: tallest ?? 0)
    }
}
