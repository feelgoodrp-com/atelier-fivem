import { useCallback, useEffect, useMemo, useReducer, useRef } from 'react'
import type {
    ApplyRequest,
    ApplyResponse,
    CameraRequest,
    Gender,
    NuiMessage,
    ViewportRequest,
} from './types'
import { appliedKey, fetchNui, IS_BROWSER, liveKey } from './nui'
import { initialState, reducer, slotTabs, visibleItems, type GridItem, type SlotRef } from './state'
import { mockApply, mockLive, mockPacks } from './mock'
import { LeftBar } from './components/LeftBar'
import { RightBar } from './components/RightBar'

/**
 * Trailing window for slider-driven camera posts. A range input fires an event
 * per pixel of travel and every post is a real fetch through CEF's NUI
 * transport, so a single drag would otherwise send a hundred of them a second.
 * The on-screen handle still follows every event — only the wire is throttled.
 */
const CAMERA_THROTTLE_MS = 60

export function App() {
    const [state, dispatch] = useReducer(reducer, initialState)

    // -- Lua -> NUI ---------------------------------------------------------
    useEffect(() => {
        const onMessage = (event: MessageEvent) => {
            const data = event.data as NuiMessage | undefined
            if (!data || typeof data !== 'object' || typeof data.action !== 'string') return
            switch (data.action) {
                case 'open':
                    dispatch({
                        type: 'open',
                        packs: Array.isArray(data.packs) ? data.packs : [],
                        framework: data.framework ?? 'none',
                    })
                    break
                case 'close':
                    dispatch({ type: 'close' })
                    break
                case 'state':
                    dispatch({
                        type: 'state',
                        gender: data.gender,
                        applied: data.applied,
                        live: data.live,
                    })
                    break
                case 'probe':
                    dispatch({ type: 'probe', report: data.report })
                    break
                case 'camera': {
                    // Echo of what Lua settled on. A preset click leaves the
                    // zoom/height to Lua, and this is how the sliders learn
                    // where they ended up.
                    const { action: _action, ...patch } = data
                    dispatch({ type: 'camera', patch })
                    break
                }
            }
        }
        window.addEventListener('message', onMessage)
        return () => window.removeEventListener('message', onMessage)
    }, [])

    // -- browser dev fallback ----------------------------------------------
    // Outside FiveM nothing ever posts a message, so seed the same state the
    // `open` and `state` messages would have produced.
    useEffect(() => {
        if (!IS_BROWSER) return
        const packs = mockPacks()
        dispatch({ type: 'open', packs, framework: 'qbx' })
        dispatch({ type: 'state', gender: 'male', applied: {}, live: mockLive(packs) })
        dispatch({
            type: 'probe',
            report: {
                note: 'mock probe — browser preview only',
                anchor8: 'unverified',
                live: { 'male:component:3': 174 },
            },
        })
    }, [])

    const close = useCallback(() => {
        dispatch({ type: 'close' })
        void fetchNui('close')
    }, [])

    useEffect(() => {
        const onKey = (event: KeyboardEvent) => {
            if (event.key === 'Escape') close()
        }
        window.addEventListener('keydown', onKey)
        return () => window.removeEventListener('keydown', onKey)
    }, [close])

    // -- viewport report ----------------------------------------------------
    // Lua aims the camera at the centre of the strip between the two bars, so
    // it needs their REAL widths. Measured, never the CSS constant: a media
    // query, a scrollbar or a font fallback all move the true edge, and the
    // constant would keep claiming 320 while the ped sits off-centre.
    const leftRef = useRef<HTMLElement | null>(null)
    const rightRef = useRef<HTMLElement | null>(null)
    const lastViewport = useRef('')

    useEffect(() => {
        if (!state.open) return

        lastViewport.current = ''
        let timer: ReturnType<typeof setTimeout> | null = null

        const report = () => {
            timer = null
            const payload: ViewportRequest = {
                left: Math.round(leftRef.current?.getBoundingClientRect().width ?? 0),
                right: Math.round(rightRef.current?.getBoundingClientRect().width ?? 0),
                width: Math.round(window.innerWidth),
                height: Math.round(window.innerHeight),
            }
            const signature = `${payload.left}|${payload.right}|${payload.width}|${payload.height}`
            if (signature === lastViewport.current) return
            lastViewport.current = signature
            void fetchNui('viewport', payload)
        }

        // Coalesce bursts: a resize drag fires continuously and a
        // ResizeObserver can fire twice for one layout pass.
        //
        // A timer, NOT requestAnimationFrame. rAF only runs when the page is
        // actually being composited, so on a frame the client does not paint
        // the callback simply never arrives — and this is a one-shot message
        // Lua cannot do without: miss it and the camera keeps aiming at the
        // centre of the screen with the ped sitting behind a bar, with nothing
        // in any log to say why.
        const schedule = () => {
            if (timer === null) timer = setTimeout(report, 50)
        }

        // The first report goes out straight away rather than through the
        // coalescer — it is the one Lua is waiting for to frame the shot.
        report()
        window.addEventListener('resize', schedule)

        // Also watch the bars themselves — a media query changes their width
        // without the window resizing in any way Lua could infer.
        const observer = new ResizeObserver(schedule)
        if (leftRef.current) observer.observe(leftRef.current)
        if (rightRef.current) observer.observe(rightRef.current)

        return () => {
            if (timer !== null) clearTimeout(timer)
            window.removeEventListener('resize', schedule)
            observer.disconnect()
        }
    }, [state.open])

    // -- camera -------------------------------------------------------------
    const cameraPending = useRef<CameraRequest | null>(null)
    const cameraTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

    const flushCamera = useCallback(() => {
        const patch = cameraPending.current
        cameraPending.current = null
        if (patch) void fetchNui('camera', patch)
    }, [])

    useEffect(
        () => () => {
            if (cameraTimer.current !== null) clearTimeout(cameraTimer.current)
        },
        [],
    )

    /** Buttons and toggles: one discrete change, post it now. */
    const handleCamera = useCallback(
        (patch: CameraRequest) => {
            dispatch({ type: 'camera', patch })
            cameraPending.current = { ...(cameraPending.current ?? {}), ...patch }
            if (cameraTimer.current !== null) {
                clearTimeout(cameraTimer.current)
                cameraTimer.current = null
            }
            flushCamera()
        },
        [flushCamera],
    )

    /** Sliders: same patch, coalesced into one post per throttle window. */
    const handleCameraDrag = useCallback(
        (patch: CameraRequest) => {
            dispatch({ type: 'camera', patch })
            cameraPending.current = { ...(cameraPending.current ?? {}), ...patch }
            if (cameraTimer.current !== null) return
            cameraTimer.current = setTimeout(() => {
                cameraTimer.current = null
                flushCamera()
            }, CAMERA_THROTTLE_MS)
        },
        [flushCamera],
    )

    // -- derived ------------------------------------------------------------
    const tabs = useMemo(() => slotTabs(state.packs, state.gender), [state.packs, state.gender])

    // Deliberately narrow deps: filtering thousands of entries must not rerun
    // because a selection, a camera nudge or an in-flight apply changed the
    // state object.
    const items = useMemo(
        () => visibleItems(state),
        // eslint-disable-next-line react-hooks/exhaustive-deps
        [state.packs, state.gender, state.slot, state.packFilter, state.groupFilter, state.search],
    )

    // Keep the slot selection valid: switching gender can remove a slot
    // entirely (a pack may only ship male shoes, for instance).
    useEffect(() => {
        if (tabs.length === 0) return
        const stillThere =
            state.slot &&
            tabs.some((t) => t.kind === state.slot?.kind && t.slotId === state.slot?.slotId)
        if (!stillThere) {
            dispatch({ type: 'setSlot', slot: { kind: tabs[0].kind, slotId: tabs[0].slotId } })
        }
    }, [tabs, state.slot])

    const selected = useMemo(
        () => items.find((entry) => entry.key === state.selectedKey) ?? null,
        [items, state.selectedKey],
    )

    const appliedIndex = state.slot
        ? (state.applied[appliedKey(state.slot.kind, state.slot.slotId)]?.index ?? null)
        : null

    const selectedLive = selected
        ? (state.live[liveKey(selected.item.gender, selected.item.kind, selected.item.slotId)] ??
          null)
        : null

    // -- NUI -> Lua ---------------------------------------------------------
    const handleApply = useCallback(async (entry: GridItem, texture: number) => {
        const key = entry.key
        dispatch({ type: 'select', key })
        dispatch({ type: 'applyStart', key })

        const request: ApplyRequest = {
            kind: entry.item.kind,
            slotId: entry.item.slotId,
            localIndex: entry.item.localIndex,
            // The ITEM's dlc, not the pack's: in a merged multi-part pack they
            // are different for every part but the first, and the wrong one
            // still resolves — to the wrong garment.
            dlcName: entry.dlcName,
            texture,
        }

        const response = IS_BROWSER
            ? mockApply(request)
            : await fetchNui<ApplyResponse>('apply', request)

        if (!response || typeof response !== 'object' || typeof response.readback !== 'number') {
            dispatch({ type: 'applyFailed', key })
            return
        }

        if (response.superseded === true) {
            // A newer apply overtook this one before it ran, so nothing was put
            // on for THIS item and the read-back belongs to whatever the slot
            // happens to hold. Recording it would either mark a scrubbed-past
            // item as worn or accuse it of being clamped, on a number that was
            // never about it.
            dispatch({ type: 'applyFailed', key })
            return
        }

        dispatch({
            type: 'applyDone',
            key,
            result: {
                ok: response.ok === true,
                applied: response.applied,
                readback: response.readback,
                // The engine silently clamps an index it does not have, so a
                // mismatch here is the only signal that the apply missed.
                clamped: response.readback !== response.applied,
                texture,
                at: Date.now(),
            },
        })
    }, [])

    const handleClearSlot = useCallback(() => {
        if (!state.slot) return
        const slot: SlotRef = state.slot
        dispatch({ type: 'clearSlot', slot })
        void fetchNui('clearSlot', { kind: slot.kind, slotId: slot.slotId })
    }, [state.slot])

    const handleGender = useCallback(
        (gender: Gender) => {
            if (gender === state.gender) return
            dispatch({ type: 'setGender', gender })
            void fetchNui('setGender', { gender })
        },
        [state.gender],
    )

    const handleRandomize = useCallback(() => {
        dispatch({ type: 'resetResults' })
        void fetchNui('randomize', {})
    }, [])

    if (!state.open) return null

    const resetKey = [
        state.gender,
        state.slot ? `${state.slot.kind}:${state.slot.slotId}` : 'none',
        state.packFilter ?? '*',
        state.groupFilter ?? '*',
        state.search,
    ].join('|')

    return (
        // Two bars and nothing else. The shell spans the screen only so the
        // bars can sit on its edges — it paints nothing and takes no pointer
        // events, so the middle strip belongs to the game and a drag there
        // reaches the ped.
        <div className="shell">
            <LeftBar
                ref={leftRef}
                packs={state.packs}
                live={state.live}
                gender={state.gender}
                packFilter={state.packFilter}
                groupFilter={state.groupFilter}
                tabs={tabs}
                slot={state.slot}
                search={state.search}
                items={items}
                selectedKey={state.selectedKey}
                busyKey={state.busyKey}
                applyResults={state.applyResults}
                appliedIndex={appliedIndex}
                resetKey={resetKey}
                framework={state.framework}
                probe={state.probe}
                showProbe={state.showProbe}
                onPackFilter={(dlcName) => dispatch({ type: 'setPackFilter', dlcName })}
                onGroupFilter={(groupId) => dispatch({ type: 'setGroupFilter', groupId })}
                onSlot={(slot) => dispatch({ type: 'setSlot', slot })}
                onSearch={(search) => dispatch({ type: 'setSearch', search })}
                onGender={handleGender}
                onSelect={(entry) => dispatch({ type: 'select', key: entry.key })}
                onApply={handleApply}
                onClearSlot={handleClearSlot}
                onRandomize={handleRandomize}
                onToggleProbe={() => dispatch({ type: 'toggleProbe' })}
                onClose={close}
            />

            <RightBar
                ref={rightRef}
                entry={selected}
                result={selected ? state.applyResults[selected.key] : undefined}
                busy={selected ? state.busyKey === selected.key : false}
                liveCount={selectedLive}
                camera={state.camera}
                onApply={handleApply}
                onClearSlot={handleClearSlot}
                onCamera={handleCamera}
                onCameraDrag={handleCameraDrag}
            />
        </div>
    )
}
