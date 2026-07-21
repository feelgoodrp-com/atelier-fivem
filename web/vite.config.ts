import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The fxmanifest lists the built files BY HAND:
//   web/dist/index.html
//   web/dist/assets/index.js
//   web/dist/assets/index.css
// so the build must emit exactly those names — no content hashes, no code
// splitting, no extra chunk. Everything below exists to guarantee that.
export default defineConfig({
    plugins: [react()],
    // Relative, because FiveM serves the page from
    // https://cfx-nui-<resource>/web/dist/index.html — an absolute "/assets/…"
    // would resolve to the wrong root.
    base: './',
    build: {
        outDir: 'dist',
        emptyOutDir: true,
        // FiveM's CEF is an older Chromium than current evergreen Chrome.
        // UNVERIFIED: the exact CEF version shipped by the client build the
        // server runs. chrome89 is a deliberately conservative floor.
        target: 'chrome89',
        // One CSS file, always — otherwise per-chunk CSS could appear and the
        // hand-written `files {}` list would miss it.
        cssCodeSplit: false,
        // Nothing may be inlined into a data: URI and nothing may be emitted as
        // a second asset file; the manifest only knows about index.css/index.js.
        assetsInlineLimit: 0,
        sourcemap: false,
        rollupOptions: {
            output: {
                entryFileNames: 'assets/index.js',
                chunkFileNames: 'assets/index.js',
                assetFileNames: 'assets/index.[ext]',
                manualChunks: undefined,
                inlineDynamicImports: true,
            },
        },
    },
})
