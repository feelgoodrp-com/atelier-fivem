import type { Gender, LiveMap, Manifest } from '../types'
import { packLiveness } from '../state'

interface PackListProps {
    packs: Manifest[]
    live: LiveMap
    gender: Gender
    packFilter: string | null
    groupFilter: string | null
    onPackFilter: (dlcName: string | null) => void
    onGroupFilter: (groupId: string | null) => void
}

const BADGE_LABEL = {
    live: 'live',
    missing: 'not loaded',
    unknown: 'unknown',
} as const

export function PackList({
    packs,
    live,
    gender,
    packFilter,
    groupFilter,
    onPackFilter,
    onGroupFilter,
}: PackListProps) {
    const visiblePacks = packFilter ? packs.filter((p) => p.pack.dlcName === packFilter) : packs
    const groups = visiblePacks.flatMap((pack) =>
        pack.groups.map((group) => ({ ...group, packName: pack.pack.name })),
    )

    return (
        <>
        <section className="bar-section bar-section-packs">
            <div className="section-head">
                <span className="section-title">Packs</span>
                <span className="spacer" />
                <span className="count">{packs.length}</span>
            </div>

            <div className="section-scroll">
                <button
                    type="button"
                    className={`row ${packFilter === null ? 'is-active' : ''}`}
                    onClick={() => onPackFilter(null)}
                >
                    <span className="row-main">
                        <span className="row-label">All packs</span>
                        <span className="row-sub">every loaded manifest</span>
                    </span>
                </button>

                {packs.map((pack) => {
                    const state = packLiveness(pack, live, gender)
                    const count = pack.items.filter((i) => i.gender === gender).length
                    const active = packFilter === pack.pack.dlcName
                    return (
                        <button
                            type="button"
                            key={pack.pack.dlcName}
                            className={`row ${active ? 'is-active' : ''}`}
                            onClick={() => onPackFilter(active ? null : pack.pack.dlcName)}
                            title={`${pack.pack.resource} — ${pack.pack.dlcName}`}
                        >
                            <span className="row-main">
                                <span className="row-label">{pack.pack.name}</span>
                                <span className="row-sub">
                                    {pack.pack.partCount > 1
                                        ? `${pack.pack.partCount} parts · `
                                        : ''}
                                    {count} items
                                </span>
                            </span>
                            <span className={`badge badge-${state}`}>{BADGE_LABEL[state]}</span>
                        </button>
                    )
                })}

            </div>
        </section>

        {/* Groups is its OWN section, not a sub-heading inside the pack
            scroller. Nested, it sat below the fold of a capped 236px box: you
            saw a clipped "Groups 4" header and not a single group. */}
        {groups.length > 0 && (
            <section className="bar-section bar-section-groups">
                <div className="section-head">
                    <span className="section-title">Groups</span>
                    <span className="spacer" />
                    <span className="count">{groups.length}</span>
                </div>

                <div className="section-scroll">
                    <button
                        type="button"
                        className={`row row-group ${groupFilter === null ? 'is-active' : ''}`}
                        onClick={() => onGroupFilter(null)}
                    >
                        <span className="row-label">All groups</span>
                    </button>

                    {groups.map((group) => {
                        const active = groupFilter === group.id
                        return (
                            <button
                                type="button"
                                key={`${group.packName}:${group.id}`}
                                className={`row row-group ${active ? 'is-active' : ''}`}
                                onClick={() => onGroupFilter(active ? null : group.id)}
                            >
                                <span className="row-label">{group.name}</span>
                                {!packFilter && (
                                    <span className="row-tag">{group.packName}</span>
                                )}
                            </button>
                        )
                    })}
                </div>
            </section>
        )}
        </>
    )
}
