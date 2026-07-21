import type { PackItem } from './types'

declare global {
    interface Window {
        invokeNative?: unknown
        GetParentResourceName?: () => string
    }
}

/**
 * True when the page is open in a normal browser instead of FiveM's CEF.
 * `invokeNative` is injected by the game frame and exists nowhere else, so its
 * absence is the reliable signal. Used to drive the mock-data dev fallback.
 */
export const IS_BROWSER = typeof window.invokeNative === 'undefined'

/**
 * Never hardcode the resource name — the folder can be renamed on any server.
 * The fallback string is only ever reached in the browser fallback, where no
 * request is actually sent.
 */
export function resourceName(): string {
    return typeof window.GetParentResourceName === 'function'
        ? window.GetParentResourceName()
        : 'atelier-fivem'
}

/**
 * POST to a RegisterNUICallback. Resolves with the decoded cb(...) value, or
 * null in the browser fallback / on any transport error — callers treat null
 * as "no answer" rather than crashing the menu.
 */
export async function fetchNui<T>(name: string, data: unknown = {}): Promise<T | null> {
    if (IS_BROWSER) return null
    try {
        const res = await fetch(`https://${resourceName()}/${name}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data ?? {}),
        })
        const text = await res.text()
        if (!text) return null
        return JSON.parse(text) as T
    } catch {
        return null
    }
}

/**
 * The item key from the shared contract. localIndex alone is ambiguous across
 * parts, so identity is always (dlcName, gender, slotId, localIndex) — plus
 * kind, because a component and a prop can share a slotId number.
 */
export function itemKey(dlcName: string, item: PackItem): string {
    return `${dlcName}|${item.gender}|${item.kind}|${item.slotId}|${item.localIndex}`
}

/** Key shape used by the `applied` map in the state message. */
export function appliedKey(kind: string, slotId: number): string {
    return `${slotId}:${kind}`
}

/** Key shape used by the `live` map in the state message. */
export function liveKey(gender: string, kind: string, slotId: number): string {
    return `${gender}:${kind}:${slotId}`
}
