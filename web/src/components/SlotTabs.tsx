import type { SlotRef, SlotTab } from '../state'
import { slotCode, slotName } from '../slots'

interface SlotTabsProps {
    tabs: SlotTab[]
    slot: SlotRef | null
    onSlot: (slot: SlotRef) => void
}

/**
 * Components and prop anchors in one wrapping strip. Props are marked with a
 * dot rather than split into a second list: a pack usually has two or three of
 * them, and a whole second heading for two chips is worse than a dot.
 */
export function SlotTabs({ tabs, slot, onSlot }: SlotTabsProps) {
    return (
        <section className="bar-section bar-section-slots">
            <div className="section-head">
                <span className="section-title">Slots</span>
                <span className="spacer" />
                <span className="count">{tabs.length}</span>
            </div>

            <nav className="slot-tabs">
                {tabs.length === 0 && (
                    <span className="slot-empty">no slots in the loaded packs</span>
                )}
                {tabs.map((tab) => {
                    const active = slot?.kind === tab.kind && slot?.slotId === tab.slotId
                    return (
                        <button
                            type="button"
                            key={tab.key}
                            className={`slot-tab ${active ? 'is-active' : ''} ${
                                tab.kind === 'prop' ? 'is-prop' : ''
                            }`}
                            onClick={() => onSlot({ kind: tab.kind, slotId: tab.slotId })}
                            title={`${slotCode(tab.kind, tab.slotId)} · ${
                                tab.kind === 'prop' ? 'anchor' : 'component'
                            } ${tab.slotId}`}
                        >
                            <span className="slot-tab-name">{slotName(tab.kind, tab.slotId)}</span>
                            <span className="slot-tab-count">{tab.count}</span>
                        </button>
                    )
                })}
            </nav>
        </section>
    )
}
