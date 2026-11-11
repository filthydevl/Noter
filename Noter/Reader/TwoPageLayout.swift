import UIKit

/// The text view as an open book (landscape, "Two pages"): the book's pages side by
/// side, two to a row — left, right, then the next two below — in reading order across
/// all PDF pages and spread halves. Each page is as tall as its text; a row is as tall
/// as its taller page.
final class TwoPageLayout: UICollectionViewLayout {
    /// Widest a page's column of text gets (the reading options' margins).
    var maxTextWidth: CGFloat = 740
    private let gap: CGFloat = 36
    private let estimatedHeight: CGFloat = 1200

    private var heights: [IndexPath: CGFloat] = [:]
    private var attributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    /// Rows in order: their top, bottom and items (for fast lookups while scrolling).
    private var rows: [(minY: CGFloat, maxY: CGFloat, items: [IndexPath])] = []
    private var contentHeight: CGFloat = 0
    private var columnWidth: CGFloat = 0

    final class Attributes: UICollectionViewLayoutAttributes {}

    override class var layoutAttributesClass: AnyClass { Attributes.self }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        attributes = [:]
        rows = []
        let width = cv.bounds.width - cv.adjustedContentInset.left - cv.adjustedContentInset.right
        columnWidth = max(min(maxTextWidth, (width - gap - 56) / 2), 200)
        let side = max((width - columnWidth * 2 - gap) / 2, 0)

        var items: [IndexPath] = []
        for section in 0..<cv.numberOfSections {
            for item in 0..<cv.numberOfItems(inSection: section) { items.append(IndexPath(item: item, section: section)) }
        }
        var y: CGFloat = 0
        var i = 0
        while i < items.count {
            let pair = Array(items[i..<min(i + 2, items.count)])
            let rowHeight = pair.map { heights[$0] ?? estimatedHeight }.max() ?? estimatedHeight
            for (column, ip) in pair.enumerated() {
                let a = Attributes(forCellWith: ip)
                a.frame = CGRect(x: side + CGFloat(column) * (columnWidth + gap), y: y,
                                 width: columnWidth, height: heights[ip] ?? estimatedHeight)
                attributes[ip] = a
            }
            rows.append((y, y + rowHeight, pair))
            y += rowHeight
            i += 2
        }
        contentHeight = y
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // First row reaching into the rect (rows are in order), then until past it.
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].maxY < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var out: [UICollectionViewLayoutAttributes] = []
        var r = lo
        while r < rows.count, rows[r].minY <= rect.maxY {
            out += rows[r].items.compactMap { attributes[$0] }
            r += 1
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    // MARK: Self-sizing

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        abs(preferred.frame.height - original.frame.height) > 0.5
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred,
                                                withOriginalAttributes: original)
        let ip = original.indexPath
        // How much its row grows / shrinks; above what you're reading, keep the text still.
        if let row = rows.first(where: { $0.items.contains(ip) }), let cv = collectionView {
            let oldRow = row.maxY - row.minY
            heights[ip] = preferred.frame.height
            let newRow = row.items.map { heights[$0] ?? estimatedHeight }.max() ?? oldRow
            if row.maxY <= cv.contentOffset.y + cv.adjustedContentInset.top {
                context.contentOffsetAdjustment = CGPoint(x: 0, y: newRow - oldRow)
            }
        } else {
            heights[ip] = preferred.frame.height
        }
        return context
    }

    /// The text was re-laid out (font, size, options): measure again.
    func resetHeights() {
        heights = [:]
        invalidateLayout()
    }
}
