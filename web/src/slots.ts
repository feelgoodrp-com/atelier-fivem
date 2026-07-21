import type { ItemKind } from './types'

/**
 * Human names for the freemode component ids. The short code in the tab comes
 * from the manifest's own `slot` field where present — this table is only the
 * readable name and the tab ORDER, so a pack using a slot name we never heard
 * of still gets a tab.
 */
export const COMPONENT_SLOTS: Record<number, { code: string; name: string }> = {
    0: { code: 'head', name: 'Head' },
    1: { code: 'berd', name: 'Masks' },
    2: { code: 'hair', name: 'Hair' },
    3: { code: 'uppr', name: 'Arms' },
    4: { code: 'lowr', name: 'Legs' },
    5: { code: 'hand', name: 'Bags' },
    6: { code: 'feet', name: 'Shoes' },
    7: { code: 'teef', name: 'Neck' },
    8: { code: 'accs', name: 'Undershirt' },
    9: { code: 'task', name: 'Armour' },
    10: { code: 'decl', name: 'Decals' },
    11: { code: 'jbib', name: 'Tops' },
}

/**
 * Prop anchors. config.lua treats {0,1,2,6,7} as the runtime convention and
 * hides 8 behind Config.includeHipAnchor.
 *
 * UNVERIFIED: anchors 3, 4 and 5 (mouth / left hand / right hand) are listed
 * here for completeness only — they are not part of the runtime convention in
 * config.lua and were not confirmed in-game. A tab for them only ever appears
 * if a manifest actually contains items for them.
 */
export const PROP_SLOTS: Record<number, { code: string; name: string }> = {
    0: { code: 'p_head', name: 'Hats' },
    1: { code: 'p_eyes', name: 'Glasses' },
    2: { code: 'p_ears', name: 'Ears' },
    3: { code: 'p_mouth', name: 'Mouth' },
    4: { code: 'p_lhand', name: 'Left hand' },
    5: { code: 'p_rhand', name: 'Right hand' },
    6: { code: 'p_lwrist', name: 'Watches' },
    7: { code: 'p_rwrist', name: 'Bracelets' },
    8: { code: 'p_hip', name: 'Hip' },
}

export function slotName(kind: ItemKind, slotId: number): string {
    const table = kind === 'prop' ? PROP_SLOTS : COMPONENT_SLOTS
    return table[slotId]?.name ?? `${kind === 'prop' ? 'Anchor' : 'Component'} ${slotId}`
}

export function slotCode(kind: ItemKind, slotId: number): string {
    const table = kind === 'prop' ? PROP_SLOTS : COMPONENT_SLOTS
    return table[slotId]?.code ?? String(slotId)
}

/** Components first in component order, then prop anchors in anchor order. */
export function slotSortKey(kind: ItemKind, slotId: number): number {
    return (kind === 'prop' ? 1000 : 0) + slotId
}
