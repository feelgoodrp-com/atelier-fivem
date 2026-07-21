import type { Framework } from '../types'
import { IS_BROWSER, resourceName } from '../nui'

interface StatusBarProps {
    framework: Framework
    packCount: number
    itemCount: number
    probe: unknown | null
    showProbe: boolean
    onToggleProbe: () => void
}

const FRAMEWORK_LABEL: Record<Framework, string> = {
    qbx: 'qbox',
    qb: 'qb-core',
    esx: 'ESX',
    none: 'standalone',
}

export function StatusBar({
    framework,
    packCount,
    itemCount,
    probe,
    showProbe,
    onToggleProbe,
}: StatusBarProps) {
    return (
        <>
            {showProbe && probe !== null && (
                <div className="probe-drawer">
                    <div className="probe-head">
                        <span className="section-title">Index probe</span>
                    </div>
                    <pre className="probe-body">{JSON.stringify(probe, null, 2)}</pre>
                </div>
            )}

            <footer className="status">
                <span className={`fw fw-${framework}`}>
                    <span className="fw-dot" aria-hidden="true" />
                    <strong>{FRAMEWORK_LABEL[framework]}</strong>
                </span>
                <span className="status-sep" aria-hidden="true" />
                <span className="muted" title={resourceName()}>
                    {packCount} {packCount === 1 ? 'pack' : 'packs'} · {itemCount} shown
                </span>

                <span className="spacer" />

                {IS_BROWSER && <span className="chip chip-dev">mock</span>}
                {probe !== null && (
                    <button type="button" className="btn btn-small btn-ghost" onClick={onToggleProbe}>
                        {showProbe ? 'Hide probe' : 'Probe'}
                    </button>
                )}
            </footer>
        </>
    )
}
