import { memo } from 'react'
import type { ApplyResult } from '../types'
import type { GridItem, SlotRef } from '../state'
import { slotCode, slotName } from '../slots'
import { VirtualGrid } from './VirtualGrid'

interface ItemListProps {
    items: GridItem[]
    slot: SlotRef | null
    selectedKey: string | null
    busyKey: string | null
    applyResults: Record<string, ApplyResult>
    /** engine index currently reported for this slot, or null */
    appliedIndex: number | null
    resetKey: string
    onSelect: (entry: GridItem) => void
    onApply: (entry: GridItem, texture: number) => void
    onClearSlot: () => void
}

interface RowProps {
    entry: GridItem
    selected: boolean
    busy: boolean
    result: ApplyResult | undefined
    onSelect: (entry: GridItem) => void
    onApply: (entry: GridItem, texture: number) => void
}

const ItemRow = memo(function ItemRow({
    entry,
    selected,
    busy,
    result,
    onSelect,
    onApply,
}: RowProps) {
    const { item } = entry
    const clamped = result?.clamped === true
    const worn = result !== undefined && !clamped

    return (
        <button
            type="button"
            className={`item ${selected ? 'is-selected' : ''} ${worn ? 'is-worn' : ''} ${
                clamped ? 'is-clamped' : ''
            } ${busy ? 'is-busy' : ''}`}
            onClick={() => onSelect(entry)}
            onDoubleClick={() => onApply(entry, 0)}
            title={`${item.label} — ${entry.dlcName} #${item.localIndex}`}
        >
            <span className="item-index">{item.localIndex}</span>

            <span className="item-main">
                <span className="item-label">{item.label}</span>
                <span className="item-sub">
                    {entry.dlcName}
                    {entry.part !== null && ` · part ${entry.part}`} · {item.textures}
                    {item.textures === 1 ? ' texture' : ' textures'}
                </span>
            </span>

            {item.mode === 'replace' && <span className="chip chip-replace">rep</span>}
            {clamped && (
                <span
                    className="chip chip-clamped"
                    title={`Asked the engine for index ${result?.applied}, it reported ${result?.readback} — the index was clamped, so this drawable is not present at runtime.`}
                >
                    clamped
                </span>
            )}
        </button>
    )
})

export function ItemList({
    items,
    slot,
    selectedKey,
    busyKey,
    applyResults,
    appliedIndex,
    resetKey,
    onSelect,
    onApply,
    onClearSlot,
}: ItemListProps) {
    return (
        <section className="bar-section bar-section-grow">
            <div className="section-head">
                <span className="section-title">
                    {slot ? slotName(slot.kind, slot.slotId) : 'No slot'}
                </span>
                {slot && (
                    <span className="section-sub">
                        {slotCode(slot.kind, slot.slotId)} · {slot.slotId}
                    </span>
                )}
                <span className="spacer" />
                {appliedIndex !== null && (
                    <span
                        className="section-sub"
                        title="Index the engine reports for this slot right now"
                    >
                        idx {appliedIndex}
                    </span>
                )}
                <span className="count">{items.length}</span>
                <button
                    type="button"
                    className="btn btn-small btn-ghost"
                    onClick={onClearSlot}
                    disabled={!slot}
                >
                    Clear
                </button>
            </div>

            <VirtualGrid
                items={items}
                cardWidth={280}
                cardHeight={52}
                gap={4}
                columns={1}
                resetKey={resetKey}
                itemKey={(entry) => entry.key}
                empty={<span>Nothing here. Try another slot, gender or search.</span>}
                renderItem={(entry) => (
                    <ItemRow
                        entry={entry}
                        selected={entry.key === selectedKey}
                        busy={entry.key === busyKey}
                        result={applyResults[entry.key]}
                        onSelect={onSelect}
                        onApply={onApply}
                    />
                )}
            />
        </section>
    )
}
