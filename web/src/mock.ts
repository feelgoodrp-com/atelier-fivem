import type {
    ApplyRequest,
    ApplyResponse,
    Gender,
    LiveMap,
    Manifest,
    PackItem,
} from './types'
import { liveKey } from './nui'

// ---------------------------------------------------------------------------
// Browser dev fallback. None of this is reachable inside FiveM (see IS_BROWSER)
// — it exists so the layout can be checked without launching the game.
// It is deliberately big enough to exercise the windowed list.
// ---------------------------------------------------------------------------

const ADJECTIVES = [
    'Oversized', 'Cropped', 'Vintage', 'Puffer', 'Tech', 'Wool', 'Distressed',
    'Slim', 'Baggy', 'Quilted', 'Faded', 'Layered', 'Heavy', 'Light',
]
const NOUNS: Record<number, string> = {
    3: 'Hoodie', 4: 'Cargos', 6: 'Sneakers', 8: 'Tee', 11: 'Jacket',
}

interface MakeOptions {
    gender: Gender
    ped: string
    kind: 'component' | 'prop'
    slot: string
    slotId: number
    count: number
    groupId: string | null
    startLabelIndex: number
    /**
     * The part these items came from. Set on a merged pack so the items carry
     * their own dlc — localIndex restarts at 0 in every part, so two parts of
     * one pack both hold a "#0" for the same slot and only the dlc tells them
     * apart.
     */
    dlcName?: string
    part?: number
}

function makeItems(options: MakeOptions): PackItem[] {
    const { gender, ped, kind, slot, slotId, count, groupId, startLabelIndex } = options
    const out: PackItem[] = []
    for (let i = 0; i < count; i++) {
        const adj = ADJECTIVES[(i + startLabelIndex) % ADJECTIVES.length]
        const noun = kind === 'prop' ? 'Cap' : (NOUNS[slotId] ?? 'Piece')
        out.push({
            kind,
            gender,
            ped,
            slot,
            slotId,
            localIndex: i,
            textures: 1 + (i % 6),
            label: `${adj} ${noun} ${String(i + 1).padStart(2, '0')}`,
            groupId,
            mode: i % 11 === 0 ? 'replace' : 'addon',
            replaceTargetId: i % 11 === 0 ? i : null,
            flags: {
                highHeels: slotId === 6 && gender === 'female' && i % 3 === 0,
                firstPerson: i % 7 !== 0,
                hairScale: slotId === 2 ? 0.5 : null,
            },
            dlcName: options.dlcName,
            part: options.part,
        })
    }
    return out
}

export function mockPacks(): Manifest[] {
    const male = 'mp_m_freemode_01'
    const female = 'mp_f_freemode_01'

    /**
     * A MERGED multi-part pack: one entry in the list, items from two parts.
     * Both parts hold a localIndex 0 for slot 3, and they are different
     * garments in different DLCs — this is the shape that catches a UI stamping
     * pack.dlcName onto every item.
     */
    const winter: Manifest = {
        schema: 'feelgood.atelier.pack/1',
        generatedAt: new Date().toISOString(),
        tool: 'atelier 1.9.1 (mock)',
        pack: {
            projectId: 'mock-winterdrop',
            name: 'Winter Drop',
            resource: 'winterdrop',
            dlcName: 'winterdrop1',
            part: 1,
            partCount: 2,
        },
        groups: [
            { id: 'g1', name: 'Hoodies' },
            { id: 'g2', name: 'Outerwear' },
            { id: 'g3', name: 'Footwear' },
        ],
        items: [
            // part 1 — a deliberately large slot so the windowing has work to do
            ...makeItems({ gender: 'male', ped: male, kind: 'component', slot: 'uppr', slotId: 3, count: 256, groupId: 'g1', startLabelIndex: 0, dlcName: 'winterdrop1', part: 1 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'component', slot: 'uppr', slotId: 3, count: 256, groupId: 'g1', startLabelIndex: 3, dlcName: 'winterdrop1', part: 1 }),
            ...makeItems({ gender: 'male', ped: male, kind: 'component', slot: 'lowr', slotId: 4, count: 40, groupId: null, startLabelIndex: 2, dlcName: 'winterdrop1', part: 1 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'component', slot: 'lowr', slotId: 4, count: 40, groupId: null, startLabelIndex: 4, dlcName: 'winterdrop1', part: 1 }),
            ...makeItems({ gender: 'male', ped: male, kind: 'prop', slot: 'p_head', slotId: 0, count: 18, groupId: null, startLabelIndex: 1, dlcName: 'winterdrop1', part: 1 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'prop', slot: 'p_head', slotId: 0, count: 18, groupId: null, startLabelIndex: 9, dlcName: 'winterdrop1', part: 1 }),

            // part 2 — SAME slots, localIndex restarts at 0, different dlc
            ...makeItems({ gender: 'male', ped: male, kind: 'component', slot: 'uppr', slotId: 3, count: 96, groupId: 'g2', startLabelIndex: 6, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'component', slot: 'uppr', slotId: 3, count: 96, groupId: 'g2', startLabelIndex: 8, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'male', ped: male, kind: 'component', slot: 'jbib', slotId: 11, count: 64, groupId: 'g2', startLabelIndex: 5, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'component', slot: 'jbib', slotId: 11, count: 64, groupId: 'g2', startLabelIndex: 7, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'male', ped: male, kind: 'component', slot: 'feet', slotId: 6, count: 24, groupId: 'g3', startLabelIndex: 6, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'component', slot: 'feet', slotId: 6, count: 24, groupId: 'g3', startLabelIndex: 8, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'male', ped: male, kind: 'prop', slot: 'p_eyes', slotId: 1, count: 12, groupId: null, startLabelIndex: 4, dlcName: 'winterdrop2', part: 2 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'prop', slot: 'p_eyes', slotId: 1, count: 12, groupId: null, startLabelIndex: 6, dlcName: 'winterdrop2', part: 2 }),
        ],
    }

    // A single-part pack that stays "not loaded", so the badge has both states.
    // Its items carry no dlcName of their own — the pack's is the right one,
    // which is the fallback path.
    const capsule: Manifest = {
        schema: 'feelgood.atelier.pack/1',
        generatedAt: new Date().toISOString(),
        tool: 'atelier 1.9.1 (mock)',
        pack: {
            projectId: 'mock-capsule',
            name: 'Capsule 01',
            resource: 'capsule01',
            dlcName: 'capsule01',
            part: 1,
            partCount: 1,
        },
        groups: [{ id: 'c1', name: 'Accessories' }],
        items: [
            ...makeItems({ gender: 'male', ped: male, kind: 'component', slot: 'accs', slotId: 8, count: 20, groupId: 'c1', startLabelIndex: 3 }),
            ...makeItems({ gender: 'female', ped: female, kind: 'component', slot: 'accs', slotId: 8, count: 20, groupId: 'c1', startLabelIndex: 5 }),
            ...makeItems({ gender: 'male', ped: male, kind: 'prop', slot: 'p_rwrist', slotId: 7, count: 9, groupId: 'c1', startLabelIndex: 2 }),
        ],
    }

    return [winter, capsule]
}

/**
 * Fake `live` counts: everything the Winter Drop pack touches reports runtime
 * variations, the Capsule pack reports none — which is exactly the shape that
 * makes one pack render as "live" and the other as "not loaded".
 */
export function mockLive(packs: Manifest[]): LiveMap {
    const live: LiveMap = {}
    for (const pack of packs) {
        if (pack.pack.dlcName === 'capsule01') continue
        for (const item of pack.items) {
            const key = liveKey(item.gender, item.kind, item.slotId)
            const base = item.kind === 'prop' ? 12 : 128
            live[key] = Math.max(live[key] ?? 0, base + item.localIndex + 1)
        }
    }
    return live
}

/**
 * Fake apply. Mimics the one behaviour that matters: the engine clamps an
 * index it does not have, and only the read-back reveals it. Here every
 * localIndex above 200 comes back clamped.
 */
export function mockApply(req: ApplyRequest): ApplyResponse {
    const base = req.kind === 'prop' ? 12 : 128
    const asked = base + req.localIndex
    const ceiling = base + 200
    const readback = Math.min(asked, ceiling)
    return { ok: readback === asked, applied: asked, readback }
}
