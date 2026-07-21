import { forwardRef } from 'react'
import type { ApplyResult, Framework, Gender, LiveMap, Manifest } from '../types'
import type { GridItem, SlotRef, SlotTab } from '../state'
import { PackList } from './PackList'
import { SlotTabs } from './SlotTabs'
import { ItemList } from './ItemList'
import { StatusBar } from './StatusBar'

interface LeftBarProps {
    packs: Manifest[]
    live: LiveMap
    gender: Gender
    packFilter: string | null
    groupFilter: string | null
    tabs: SlotTab[]
    slot: SlotRef | null
    search: string
    items: GridItem[]
    selectedKey: string | null
    busyKey: string | null
    applyResults: Record<string, ApplyResult>
    appliedIndex: number | null
    resetKey: string
    framework: Framework
    probe: unknown | null
    showProbe: boolean
    onPackFilter: (dlcName: string | null) => void
    onGroupFilter: (groupId: string | null) => void
    onSlot: (slot: SlotRef) => void
    onSearch: (search: string) => void
    onGender: (gender: Gender) => void
    onSelect: (entry: GridItem) => void
    onApply: (entry: GridItem, texture: number) => void
    onClearSlot: () => void
    onRandomize: () => void
    onToggleProbe: () => void
    onClose: () => void
}

/**
 * The whole browse side, stacked into one column.
 *
 * Everything that used to be spread across a full-screen workbench lives here,
 * because the middle of the screen is not ours to use: the mannequin stands
 * there and has to stay visible.
 */
export const LeftBar = forwardRef<HTMLElement, LeftBarProps>(function LeftBar(props, ref) {
    return (
        <aside className="bar bar-left" ref={ref}>
            <span className="bar-glow" aria-hidden="true" />

            <header className="bar-head">
                <img className="brand-logo" src="atelier-logo.png" alt="" aria-hidden="true" />
                <span className="brand-name">atelier</span>
                <span className="spacer" />
                <button
                    type="button"
                    className="btn btn-small btn-ghost"
                    onClick={props.onRandomize}
                    title="Put one random item on every slot"
                >
                    Randomize
                </button>
                <button
                    type="button"
                    className="btn btn-small btn-ghost"
                    onClick={props.onClose}
                    title="Close the viewer (Esc)"
                >
                    Close
                </button>
            </header>

            <div className="bar-controls">
                <div className="gender-switch" role="group" aria-label="Gender">
                    {(['male', 'female'] as const).map((value) => (
                        <button
                            type="button"
                            key={value}
                            className={`gender-option ${props.gender === value ? 'is-active' : ''}`}
                            onClick={() => props.onGender(value)}
                        >
                            {value === 'male' ? 'Male' : 'Female'}
                        </button>
                    ))}
                </div>

                <div className="search">
                    <input
                        className="search-input"
                        type="text"
                        value={props.search}
                        placeholder="Search label, slot or index…"
                        onChange={(e) => props.onSearch(e.target.value)}
                    />
                    {props.search !== '' && (
                        <button
                            type="button"
                            className="search-clear"
                            onClick={() => props.onSearch('')}
                            aria-label="Clear search"
                        >
                            ×
                        </button>
                    )}
                </div>
            </div>

            <PackList
                packs={props.packs}
                live={props.live}
                gender={props.gender}
                packFilter={props.packFilter}
                groupFilter={props.groupFilter}
                onPackFilter={props.onPackFilter}
                onGroupFilter={props.onGroupFilter}
            />

            <SlotTabs tabs={props.tabs} slot={props.slot} onSlot={props.onSlot} />

            <ItemList
                items={props.items}
                slot={props.slot}
                selectedKey={props.selectedKey}
                busyKey={props.busyKey}
                applyResults={props.applyResults}
                appliedIndex={props.appliedIndex}
                resetKey={props.resetKey}
                onSelect={props.onSelect}
                onApply={props.onApply}
                onClearSlot={props.onClearSlot}
            />

            <StatusBar
                framework={props.framework}
                packCount={props.packs.length}
                itemCount={props.items.length}
                probe={props.probe}
                showProbe={props.showProbe}
                onToggleProbe={props.onToggleProbe}
            />
        </aside>
    )
})
