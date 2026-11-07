//
//  FlowLayout.swift
//  CamCardClone
//
//  标签云 / 自动换行布局。用于详情页标签与筛选栏。
//

import SwiftUI

struct FlowLayout: Layout {

    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = makeRows(maxWidth: maxWidth, subviews: subviews)

        let height = rows.reduce(CGFloat.zero) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing

        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = proposal.width ?? bounds.width
        let rows = makeRows(maxWidth: maxWidth, subviews: subviews)

        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(
                        width: item.size.width,
                        height: item.size.height
                    )
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    // MARK: - Row model

    private struct Row {
        var items: [(subview: LayoutSubview, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let additionalWidth = current.items.isEmpty
                ? size.width
                : size.width + horizontalSpacing

            if current.width + additionalWidth > maxWidth,
               !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }

            if !current.items.isEmpty {
                current.width += horizontalSpacing
            }
            current.items.append((subview, size))
            current.width += size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
