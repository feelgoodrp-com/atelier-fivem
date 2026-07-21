// Mirror of the manifest schema "feelgood.atelier.pack/1" that atelier writes
// and client/discovery.lua hands to the NUI. Do not widen these types to be
// "nice" — if a build writes something else, that is a bug worth seeing.

export type Gender = 'male' | 'female'
export type ItemKind = 'component' | 'prop'
export type ItemMode = 'addon' | 'replace'

export interface ItemFlags {
    highHeels: boolean
    firstPerson: boolean
    hairScale: number | null
}

export interface PackItem {
    kind: ItemKind
    gender: Gender
    ped: string
    /** atelier slot id, e.g. "uppr" */
    slot: string
    /** componentId when kind=component, anchorId when kind=prop */
    slotId: number
    /** NNN in the stream name. Restarts at 0 in EVERY part. */
    localIndex: number
    textures: number
    label: string
    groupId: string | null
    mode: ItemMode
    replaceTargetId: number | null
    flags: ItemFlags
    /**
     * The dlcName of the PART this item came from.
     *
     * A merged multi-part pack is one entry in the pack list but holds items
     * from several parts, and every part is its own DLC with its own name and
     * its own localIndex counting from 0. So pack.dlcName describes the pack,
     * NOT necessarily the item: the only correct dlc for an item is this field
     * when discovery.lua stamped it, and pack.dlcName only as the fallback for
     * a single-part pack that never needed stamping.
     *
     * Getting this wrong is silent — a valid dlcName with a valid localIndex
     * resolves to a real drawable, just the wrong garment.
     */
    dlcName?: string
    /** Part number this item came from, when the pack was merged. */
    part?: number
}

export interface PackGroup {
    id: string
    name: string
}

export interface PackMeta {
    projectId: string
    name: string
    resource: string
    dlcName: string
    part: number
    partCount: number
}

export interface Manifest {
    schema: string
    generatedAt: string
    tool: string
    pack: PackMeta
    groups: PackGroup[]
    items: PackItem[]
}

export type Framework = 'qbx' | 'qb' | 'esx' | 'none'

/** What the engine currently has on the mannequin, keyed "slotId:kind". */
export interface AppliedEntry {
    index: number
    texture: number
}
export type AppliedMap = Record<string, AppliedEntry>

/** Runtime variation counts, keyed "gender:kind:slotId". */
export type LiveMap = Record<string, number>

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

export type CameraPreset = 'full' | 'upper' | 'head' | 'legs' | 'feet'
export type CameraLight = 'studio' | 'bright' | 'dark' | 'none'

export interface CameraState {
    preset: CameraPreset
    /** 0 = far, 1 = close */
    zoom: number
    /** 0 = feet, 1 = head */
    height: number
    autoRotate: boolean
    light: CameraLight
}

export const CAMERA_PRESETS: CameraPreset[] = ['full', 'upper', 'head', 'legs', 'feet']
export const CAMERA_LIGHTS: CameraLight[] = ['studio', 'bright', 'dark', 'none']

export const initialCamera: CameraState = {
    preset: 'full',
    zoom: 0.35,
    height: 0.5,
    autoRotate: false,
    light: 'studio',
}

// ---------------------------------------------------------------------------
// Lua -> NUI
// ---------------------------------------------------------------------------

export interface OpenMessage {
    action: 'open'
    packs: Manifest[]
    framework: Framework
}
export interface CloseMessage {
    action: 'close'
}
export interface StateMessage {
    action: 'state'
    gender: Gender
    applied: AppliedMap
    live: LiveMap
}
export interface ProbeMessage {
    action: 'probe'
    report: unknown
}
/**
 * Echo of the camera state Lua actually settled on. Every field is optional:
 * a preset click makes Lua choose its own zoom/height, and the echo is how
 * those land back on the sliders.
 */
export interface CameraMessage extends Partial<CameraState> {
    action: 'camera'
}

export type NuiMessage =
    | OpenMessage
    | CloseMessage
    | StateMessage
    | ProbeMessage
    | CameraMessage

// ---------------------------------------------------------------------------
// NUI -> Lua
// ---------------------------------------------------------------------------

export interface ApplyRequest {
    kind: ItemKind
    slotId: number
    localIndex: number
    dlcName: string
    texture: number
}

/**
 * Answer to "apply". `applied` is the index the resource asked the engine for,
 * `readback` is what GetPedDrawableVariation/GetPedPropIndex reported after.
 * They differ when the engine silently clamped an out-of-range index — which
 * is the only way to tell a real miss from a success.
 *
 * `superseded` marks a debounced apply that a newer one overtook: NOTHING was
 * applied, and `readback` is the slot's unrelated current value. Recording it
 * would paint the scrubbed-past item as worn (or as clamped) on the strength
 * of a number that has nothing to do with it.
 */
export interface ApplyResponse {
    ok: boolean
    applied: number
    readback: number
    superseded?: boolean
}

/** Local record of the last apply attempt for one item. */
export interface ApplyResult {
    ok: boolean
    applied: number
    readback: number
    clamped: boolean
    texture: number
    at: number
}

/**
 * NUI -> Lua "viewport": the REAL rendered widths of the two bars, so Lua can
 * aim the camera at the centre of the free strip between them instead of the
 * centre of the screen.
 */
export interface ViewportRequest {
    left: number
    right: number
    width: number
    height: number
}

/**
 * NUI -> Lua "camera". Only the fields that changed are sent — a preset click
 * must not drag a stale zoom along with it and fight the preset Lua just
 * chose.
 */
export type CameraRequest = Partial<CameraState>
