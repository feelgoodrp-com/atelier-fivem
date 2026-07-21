import {
    CAMERA_LIGHTS,
    CAMERA_PRESETS,
    type CameraLight,
    type CameraPreset,
    type CameraRequest,
    type CameraState,
} from '../types'

interface CameraPanelProps {
    camera: CameraState
    /** Buttons and toggles: post at once. */
    onCamera: (patch: CameraRequest) => void
    /** Sliders: same patch, but throttled on the way out. */
    onCameraDrag: (patch: CameraRequest) => void
}

const PRESET_LABEL: Record<CameraPreset, string> = {
    full: 'Full body',
    upper: 'Upper',
    head: 'Head',
    legs: 'Legs',
    feet: 'Feet',
}

const LIGHT_LABEL: Record<CameraLight, string> = {
    studio: 'Studio',
    bright: 'Bright',
    dark: 'Dark',
    none: 'None',
}

/**
 * Camera controls.
 *
 * Each control posts ONLY the field it changed. A preset makes Lua pick its own
 * zoom and height, and those come back on the { action: "camera" } echo — so
 * sending the whole state on every click would shove a stale zoom back at Lua
 * and undo the preset it just applied.
 */
export function CameraPanel({ camera, onCamera, onCameraDrag }: CameraPanelProps) {
    return (
        <section className="bar-section camera">
            <div className="section-head">
                <span className="section-title">Camera</span>
            </div>

            <div className="camera-body">
                <div className="preset-grid">
                    {CAMERA_PRESETS.map((preset) => (
                        <button
                            type="button"
                            key={preset}
                            className={`preset ${camera.preset === preset ? 'is-active' : ''}`}
                            onClick={() => onCamera({ preset })}
                        >
                            {PRESET_LABEL[preset]}
                        </button>
                    ))}
                </div>

                <label className="slider">
                    <span className="slider-head">
                        <span className="slider-label">Zoom</span>
                        <span className="slider-value">{Math.round(camera.zoom * 100)}</span>
                    </span>
                    <input
                        type="range"
                        min={0}
                        max={100}
                        step={1}
                        value={Math.round(camera.zoom * 100)}
                        onChange={(e) => onCameraDrag({ zoom: Number(e.target.value) / 100 })}
                    />
                    <span className="slider-ends">
                        <span>far</span>
                        <span>close</span>
                    </span>
                </label>

                <label className="slider">
                    <span className="slider-head">
                        <span className="slider-label">Height</span>
                        <span className="slider-value">{Math.round(camera.height * 100)}</span>
                    </span>
                    <input
                        type="range"
                        min={0}
                        max={100}
                        step={1}
                        value={Math.round(camera.height * 100)}
                        onChange={(e) => onCameraDrag({ height: Number(e.target.value) / 100 })}
                    />
                    <span className="slider-ends">
                        <span>feet</span>
                        <span>head</span>
                    </span>
                </label>

                <button
                    type="button"
                    className={`toggle ${camera.autoRotate ? 'is-on' : ''}`}
                    onClick={() => onCamera({ autoRotate: !camera.autoRotate })}
                    aria-pressed={camera.autoRotate}
                >
                    <span className="toggle-label">Auto-rotate</span>
                    <span className="toggle-track" aria-hidden="true">
                        <span className="toggle-knob" />
                    </span>
                </button>

                <div className="camera-lights">
                    <span className="field-label">Light</span>
                    <div className="light-grid">
                        {CAMERA_LIGHTS.map((light) => (
                            <button
                                type="button"
                                key={light}
                                className={`preset ${camera.light === light ? 'is-active' : ''}`}
                                onClick={() => onCamera({ light })}
                            >
                                {LIGHT_LABEL[light]}
                            </button>
                        ))}
                    </div>
                </div>

                <p className="camera-hint">
                    Drag in the middle of the screen to turn the mannequin.
                </p>
            </div>
        </section>
    )
}
