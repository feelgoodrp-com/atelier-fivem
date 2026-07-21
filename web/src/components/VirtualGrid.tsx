import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'

interface VirtualGridProps<T> {
    items: T[]
    /** Target card width in px. Only used to decide the column count; the
     *  cards themselves stretch to fill the row. */
    cardWidth: number
    cardHeight: number
    gap: number
    /** Force a column count instead of deriving one from the width. The bars
     *  are a fixed narrow column, so their lists are always single-file. */
    columns?: number
    /** Rows rendered above and below the viewport, to hide scroll tearing. */
    overscanRows?: number
    /** Change this to jump back to the top (new slot, new search, …). */
    resetKey?: string
    renderItem: (item: T, index: number) => ReactNode
    itemKey: (item: T, index: number) => string
    empty?: ReactNode
}

/**
 * Row-windowed grid.
 *
 * A pack can hold thousands of entries (256 drawables x 12 slots x 2 genders)
 * and CEF drops frames long before that if every card is in the DOM. Only the
 * rows that intersect the viewport are mounted; a single spacer div carries the
 * full scroll height so the scrollbar still tells the truth.
 *
 * Written by hand on purpose — the resource ships with no runtime dependencies.
 */
export function VirtualGrid<T>({
    items,
    cardWidth,
    cardHeight,
    gap,
    columns: fixedColumns,
    overscanRows = 3,
    resetKey,
    renderItem,
    itemKey,
    empty,
}: VirtualGridProps<T>) {
    const viewportRef = useRef<HTMLDivElement | null>(null)
    const [scrollTop, setScrollTop] = useState(0)
    const [size, setSize] = useState({ width: 0, height: 0 })
    const frame = useRef(0)

    // Measure the viewport. ResizeObserver rather than a window resize
    // listener, because the panel also changes width when the inspector or the
    // probe drawer opens.
    useLayoutEffect(() => {
        const el = viewportRef.current
        if (!el) return
        const measure = () =>
            setSize({ width: el.clientWidth, height: el.clientHeight })
        measure()
        const ro = new ResizeObserver(measure)
        ro.observe(el)
        return () => ro.disconnect()
    }, [])

    // Coalesce scroll events into one state update per animation frame.
    const onScroll = useCallback(() => {
        if (frame.current) return
        frame.current = requestAnimationFrame(() => {
            frame.current = 0
            const el = viewportRef.current
            if (el) setScrollTop(el.scrollTop)
        })
    }, [])

    useEffect(() => () => {
        if (frame.current) cancelAnimationFrame(frame.current)
    }, [])

    // A new list means the old scroll offset is meaningless.
    useLayoutEffect(() => {
        const el = viewportRef.current
        if (el) el.scrollTop = 0
        setScrollTop(0)
    }, [resetKey])

    const columns =
        fixedColumns ?? Math.max(1, Math.floor((size.width + gap) / (cardWidth + gap)))
    const rowHeight = cardHeight + gap
    const rowCount = Math.ceil(items.length / columns)
    const totalHeight = Math.max(0, rowCount * rowHeight - gap)

    const firstRow = Math.max(0, Math.floor(scrollTop / rowHeight) - overscanRows)
    const lastRow = Math.min(
        rowCount,
        Math.ceil((scrollTop + (size.height || 600)) / rowHeight) + overscanRows,
    )

    const start = firstRow * columns
    const end = Math.min(items.length, lastRow * columns)
    const window = items.slice(start, end)

    return (
        <div className="vgrid" ref={viewportRef} onScroll={onScroll}>
            {items.length === 0 ? (
                <div className="vgrid-empty">{empty}</div>
            ) : (
                <div className="vgrid-spacer" style={{ height: totalHeight }}>
                    <div
                        className="vgrid-window"
                        style={{
                            transform: `translateY(${firstRow * rowHeight}px)`,
                            gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))`,
                            gap,
                        }}
                    >
                        {window.map((item, i) => (
                            <div key={itemKey(item, start + i)} style={{ height: cardHeight }}>
                                {renderItem(item, start + i)}
                            </div>
                        ))}
                    </div>
                </div>
            )}
        </div>
    )
}
