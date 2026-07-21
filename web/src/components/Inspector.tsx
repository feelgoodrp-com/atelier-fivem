import type { CSSProperties } from 'react'
import type { ApplyResult } from '../types'
import type { GridItem } from '../state'
import { slotCode, slotName } from '../slots'

interface InspectorProps {
    entry: GridItem | null
    result: ApplyResult | undefined
    busy: boolean
    liveCount: number | null
    onApply: (entry: GridItem, texture: number) => void
    onClearSlot: () => void
}

function Field({ label, value, hint }: { label: string; value: string; hint?: string }) {
    return (
        <div className="field" title={hint}>
            <span className="field-label">{label}</span>
            <span className="field-value">{value}</span>
        </div>
    )
}

export function Inspector({ entry, result, busy, liveCount, onApply, onClearSlot }: InspectorProps) {
    if (!entry) {
        return (
            <section className="bar-section bar-section-grow inspector-empty-wrap">
                <div className="section-head">
                    <span className="section-title">Inspector</span>
                </div>
                <div className="inspector-empty">
                    <span className="inspector-empty-mark" aria-hidden="true" />
                    <p>Pick an item to see its slot, index and flags.</p>
                    <p className="muted">Double-click a row to put it on the mannequin.</p>
                </div>
            </section>
        )
    }

    const { item } = entry
    const activeTexture = result?.texture ?? 0
    const clamped = result?.clamped === true

    return (
        <section className="bar-section bar-section-grow">
            <div className="section-head">
                <span className="section-title">Inspector</span>
                <span className="spacer" />
                <span className="section-sub">{entry.packName}</span>
            </div>

            <div className="section-scroll inspector">
                <h2 className="inspector-title">{item.label}</h2>
                <div className="inspector-tags">
                    <span
                        className={`chip ${item.mode === 'replace' ? 'chip-replace' : 'chip-addon'}`}
                    >
                        {item.mode}
                    </span>
                    <span className="chip">{item.kind}</span>
                    {entry.groupName && <span className="chip chip-quiet">{entry.groupName}</span>}
                </div>

                <div className="fields">
                    <Field
                        label="Slot"
                        value={`${slotName(item.kind, item.slotId)} · ${slotCode(item.kind, item.slotId)}`}
                    />
                    <Field
                        label={item.kind === 'prop' ? 'Anchor id' : 'Component id'}
                        value={String(item.slotId)}
                    />
                    <Field
                        label="Local index"
                        value={String(item.localIndex)}
                        hint="NNN in the stream name. Restarts at 0 in every part, so it is only unique together with the DLC name."
                    />
                    <Field
                        label="DLC name"
                        value={entry.dlcName}
                        hint={
                            entry.dlcName === entry.packDlcName
                                ? "The pack's own DLC."
                                : `This item comes from a different part of the merged pack (pack DLC: ${entry.packDlcName}).`
                        }
                    />
                    {entry.part !== null && <Field label="Part" value={String(entry.part)} />}
                    <Field label="Ped" value={item.ped} />
                    <Field label="Textures" value={String(item.textures)} />
                    {item.mode === 'replace' && (
                        <Field
                            label="Replaces"
                            value={
                                item.replaceTargetId === null ? '—' : String(item.replaceTargetId)
                            }
                        />
                    )}
                    <Field
                        label="Live variations"
                        value={liveCount === null ? 'unknown' : String(liveCount)}
                        hint="Drawables the engine reports for this slot at runtime — vanilla plus every loaded DLC, not just this pack."
                    />
                </div>

                <div className="inspector-section">
                    <span className="section-title">Flags</span>
                    <div className="flags">
                        <span className={`flag ${item.flags.highHeels ? 'is-on' : ''}`}>
                            high heels
                        </span>
                        <span className={`flag ${item.flags.firstPerson ? 'is-on' : ''}`}>
                            first person
                        </span>
                        <span className={`flag ${item.flags.hairScale !== null ? 'is-on' : ''}`}>
                            hair scale {item.flags.hairScale ?? '—'}
                        </span>
                    </div>
                </div>

                <div className="inspector-section">
                    <span className="section-title">Textures</span>
                    <div className="swatches">
                        {Array.from({ length: Math.max(1, item.textures) }, (_, i) => (
                            <button
                                type="button"
                                key={i}
                                className={`swatch ${result && activeTexture === i ? 'is-active' : ''}`}
                                style={{ '--swatch-hue': `${(i * 47) % 360}` } as CSSProperties}
                                onClick={() => onApply(entry, i)}
                                disabled={busy}
                                title={`Apply with texture ${i}`}
                            >
                                {i}
                            </button>
                        ))}
                    </div>
                </div>

                {result && (
                    <div className={`readback ${clamped ? 'is-clamped' : 'is-ok'}`}>
                        <span className="section-title">Read-back</span>
                        <div className="readback-row">
                            <span>asked</span>
                            <strong>{result.applied}</strong>
                        </div>
                        <div className="readback-row">
                            <span>engine reported</span>
                            <strong>{result.readback}</strong>
                        </div>
                        <p className="readback-note">
                            {clamped
                                ? 'The engine clamped the index — this drawable is not present at runtime. The pack is probably not loaded, or the index mapping is off.'
                                : 'The engine reported back exactly what was asked for.'}
                        </p>
                    </div>
                )}

                <div className="inspector-actions">
                    <button
                        type="button"
                        className="btn btn-primary"
                        onClick={() => onApply(entry, activeTexture)}
                        disabled={busy}
                    >
                        {busy ? 'Applying…' : 'Apply'}
                    </button>
                    <button type="button" className="btn" onClick={onClearSlot}>
                        Clear slot
                    </button>
                </div>
            </div>
        </section>
    )
}
