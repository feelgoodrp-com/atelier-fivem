import {
    initialCamera,
    type AppliedMap,
    type ApplyResult,
    type CameraState,
    type Framework,
    type Gender,
    type ItemKind,
    type LiveMap,
    type Manifest,
    type PackItem,
} from './types'
import { itemKey, liveKey } from './nui'
import { slotSortKey } from './slots'

export interface SlotRef {
    kind: ItemKind
    slotId: number
}

export interface AppState {
    open: boolean
    packs: Manifest[]
    framework: Framework
    gender: Gender
    applied: AppliedMap
    live: LiveMap
    probe: unknown | null
    showProbe: boolean
    /** dlcName of the pack the list is limited to, or null for every pack. */
    packFilter: string | null
    /** groupId within the filtered pack, or null for every group. */
    groupFilter: string | null
    slot: SlotRef | null
    search: string
    selectedKey: string | null
    applyResults: Record<string, ApplyResult>
    busyKey: string | null
    camera: CameraState
}

export const initialState: AppState = {
    open: false,
    packs: [],
    framework: 'none',
    gender: 'male',
    applied: {},
    live: {},
    probe: null,
    showProbe: false,
    packFilter: null,
    groupFilter: null,
    slot: null,
    search: '',
    selectedKey: null,
    applyResults: {},
    busyKey: null,
    camera: initialCamera,
}

export type Action =
    | { type: 'open'; packs: Manifest[]; framework: Framework }
    | { type: 'close' }
    | { type: 'state'; gender: Gender; applied: AppliedMap; live: LiveMap }
    | { type: 'probe'; report: unknown }
    | { type: 'toggleProbe' }
    | { type: 'setPackFilter'; dlcName: string | null }
    | { type: 'setGroupFilter'; groupId: string | null }
    | { type: 'setSlot'; slot: SlotRef }
    | { type: 'setSearch'; search: string }
    | { type: 'select'; key: string | null }
    | { type: 'setGender'; gender: Gender }
    | { type: 'applyStart'; key: string }
    | { type: 'applyDone'; key: string; result: ApplyResult }
    | { type: 'applyFailed'; key: string }
    | { type: 'clearSlot'; slot: SlotRef }
    | { type: 'resetResults' }
    | { type: 'camera'; patch: Partial<CameraState> }

/** kind + slotId out of an item key: dlcName|gender|kind|slotId|localIndex */
function keySlot(key: string): string {
    const parts = key.split('|')
    return `${parts[2]}|${parts[3]}`
}

export function reducer(state: AppState, action: Action): AppState {
    switch (action.type) {
        case 'open': {
            const slot = state.slot ?? firstSlot(action.packs)
            return { ...state, open: true, packs: action.packs, framework: action.framework, slot }
        }
        case 'close':
            return { ...state, open: false }
        case 'state':
            return {
                ...state,
                gender: action.gender,
                applied: action.applied ?? {},
                live: action.live ?? {},
            }
        case 'probe':
            return { ...state, probe: action.report }
        case 'toggleProbe':
            return { ...state, showProbe: !state.showProbe }
        case 'setPackFilter':
            return { ...state, packFilter: action.dlcName, groupFilter: null }
        case 'setGroupFilter':
            return { ...state, groupFilter: action.groupId }
        case 'setSlot':
            return { ...state, slot: action.slot, selectedKey: null }
        case 'setSearch':
            return { ...state, search: action.search }
        case 'select':
            return { ...state, selectedKey: action.key }
        case 'setGender':
            // Optimistic: the authoritative value arrives with the next state
            // message, but the list should not sit on the wrong gender until
            // then. The ped is rebuilt, so nothing stays applied.
            return {
                ...state,
                gender: action.gender,
                selectedKey: null,
                applied: {},
                applyResults: {},
            }
        case 'applyStart':
            return { ...state, busyKey: action.key }
        case 'applyDone': {
            // One drawable per slot: applying replaces whatever was recorded
            // for that slot, so only one row can read as worn.
            const slotKey = keySlot(action.key)
            const next: Record<string, ApplyResult> = {}
            for (const [key, value] of Object.entries(state.applyResults)) {
                if (keySlot(key) !== slotKey) next[key] = value
            }
            next[action.key] = action.result
            return {
                ...state,
                busyKey: state.busyKey === action.key ? null : state.busyKey,
                applyResults: next,
            }
        }
        case 'applyFailed':
            return { ...state, busyKey: state.busyKey === action.key ? null : state.busyKey }
        case 'clearSlot': {
            // Drop the recorded apply results for that slot so the list stops
            // showing an item as worn.
            const next: Record<string, ApplyResult> = {}
            const suffix = `|${action.slot.kind}|${action.slot.slotId}|`
            for (const [key, value] of Object.entries(state.applyResults)) {
                if (!key.includes(suffix)) next[key] = value
            }
            return { ...state, applyResults: next }
        }
        case 'resetResults':
            return { ...state, applyResults: {}, selectedKey: null }
        case 'camera':
            // Same action for a local control change and for the Lua echo. The
            // echo only ever carries the fields Lua actually decided, so an
            // undefined field must not wipe the value already on screen.
            return { ...state, camera: mergeCamera(state.camera, action.patch) }
        default:
            return state
    }
}

/** Copy only the defined fields of `patch` over `base`. */
export function mergeCamera(base: CameraState, patch: Partial<CameraState>): CameraState {
    const next: CameraState = { ...base }
    if (patch.preset !== undefined) next.preset = patch.preset
    if (typeof patch.zoom === 'number') next.zoom = clamp01(patch.zoom)
    if (typeof patch.height === 'number') next.height = clamp01(patch.height)
    if (typeof patch.autoRotate === 'boolean') next.autoRotate = patch.autoRotate
    if (patch.light !== undefined) next.light = patch.light
    return next
}

export function clamp01(value: number): number {
    if (!Number.isFinite(value)) return 0
    return Math.min(1, Math.max(0, value))
}

// ---------------------------------------------------------------------------
// Derived data
// ---------------------------------------------------------------------------

export interface SlotTab extends SlotRef {
    key: string
    count: number
}

function firstSlot(packs: Manifest[]): SlotRef | null {
    const tabs = slotTabs(packs, 'male')
    return tabs.length > 0 ? { kind: tabs[0].kind, slotId: tabs[0].slotId } : null
}

/** Every slot that the loaded packs actually contain, for the current gender. */
export function slotTabs(packs: Manifest[], gender: Gender): SlotTab[] {
    const seen = new Map<string, SlotTab>()
    for (const pack of packs) {
        for (const item of pack.items) {
            if (item.gender !== gender) continue
            const key = `${item.kind}:${item.slotId}`
            const existing = seen.get(key)
            if (existing) existing.count += 1
            else seen.set(key, { key, kind: item.kind, slotId: item.slotId, count: 1 })
        }
    }
    return [...seen.values()].sort(
        (a, b) => slotSortKey(a.kind, a.slotId) - slotSortKey(b.kind, b.slotId),
    )
}

/**
 * The dlc an ITEM belongs to.
 *
 * A merged multi-part pack carries items from several parts. Each part is its
 * own DLC and each part counts localIndex from 0, so stamping the pack's
 * dlcName on every item points half of them at the wrong DLC — and because the
 * wrong (dlcName, localIndex) pair is still a perfectly resolvable one, the
 * mannequin just quietly wears the wrong garment.
 */
export function itemDlcName(item: PackItem, packDlcName: string): string {
    return item.dlcName ?? packDlcName
}

export interface GridItem {
    key: string
    item: PackItem
    /** The item's own dlc — what the apply payload must carry. */
    dlcName: string
    /** The merged pack's dlc — what the pack filter matches on. */
    packDlcName: string
    packName: string
    groupName: string | null
    part: number | null
}

/** The item list contents: current gender + slot, then pack/group/search. */
export function visibleItems(state: AppState): GridItem[] {
    const { packs, gender, slot, packFilter, groupFilter, search } = state
    if (!slot) return []
    const needle = search.trim().toLowerCase()
    const out: GridItem[] = []

    for (const pack of packs) {
        const packDlcName = pack.pack.dlcName
        // Filtering is per PACK, so it matches the pack's dlcName and not the
        // per-item one — otherwise picking a merged pack would drop every item
        // that came from one of its other parts.
        if (packFilter && packFilter !== packDlcName) continue
        const groupNames = new Map(pack.groups.map((g) => [g.id, g.name]))

        for (const item of pack.items) {
            if (item.gender !== gender) continue
            if (item.kind !== slot.kind || item.slotId !== slot.slotId) continue
            if (groupFilter && item.groupId !== groupFilter) continue
            if (needle) {
                const hay = `${item.label} ${item.slot} ${item.localIndex}`.toLowerCase()
                if (!hay.includes(needle)) continue
            }
            const dlcName = itemDlcName(item, packDlcName)
            out.push({
                // Identity is per DLC too: two parts of one pack both hold a
                // localIndex 0 for the same slot.
                key: itemKey(dlcName, item),
                item,
                dlcName,
                packDlcName,
                packName: pack.pack.name,
                groupName: item.groupId ? (groupNames.get(item.groupId) ?? null) : null,
                part: item.part ?? null,
            })
        }
    }
    return out
}

export type PackLiveness = 'live' | 'missing' | 'unknown'

/**
 * Badge state for a pack, derived from the runtime variation counts in the
 * state message.
 *
 * UNVERIFIED: the `live` map reports how many variations a slot has AT RUNTIME
 * for the whole game — vanilla plus every DLC — so it cannot prove that THIS
 * pack is the one contributing them. A pack whose slots report zero variations
 * is definitely not loaded; a pack whose slots report some is only probably
 * loaded. The badge says "live"/"not loaded" on that basis and nothing more.
 */
export function packLiveness(pack: Manifest, live: LiveMap, gender: Gender): PackLiveness {
    if (!live || Object.keys(live).length === 0) return 'unknown'
    let checked = 0
    let present = 0
    const seen = new Set<string>()
    for (const item of pack.items) {
        if (item.gender !== gender) continue
        const key = liveKey(item.gender, item.kind, item.slotId)
        if (seen.has(key)) continue
        seen.add(key)
        checked += 1
        if ((live[key] ?? 0) > 0) present += 1
    }
    if (checked === 0) return 'unknown'
    return present > 0 ? 'live' : 'missing'
}
