import { forwardRef } from 'react'
import type { ApplyResult, CameraRequest, CameraState } from '../types'
import type { GridItem } from '../state'
import { Inspector } from './Inspector'
import { CameraPanel } from './CameraPanel'

interface RightBarProps {
    entry: GridItem | null
    result: ApplyResult | undefined
    busy: boolean
    liveCount: number | null
    camera: CameraState
    onApply: (entry: GridItem, texture: number) => void
    onClearSlot: () => void
    onCamera: (patch: CameraRequest) => void
    onCameraDrag: (patch: CameraRequest) => void
}

/** Inspector on top, camera underneath. */
export const RightBar = forwardRef<HTMLElement, RightBarProps>(function RightBar(props, ref) {
    return (
        <aside className="bar bar-right" ref={ref}>
            <span className="bar-glow" aria-hidden="true" />

            <Inspector
                entry={props.entry}
                result={props.result}
                busy={props.busy}
                liveCount={props.liveCount}
                onApply={props.onApply}
                onClearSlot={props.onClearSlot}
            />

            <CameraPanel
                camera={props.camera}
                onCamera={props.onCamera}
                onCameraDrag={props.onCameraDrag}
            />
        </aside>
    )
})
