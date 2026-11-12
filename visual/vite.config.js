import { defineConfig } from 'vite'

// The Pip drawing page: Excalidraw (MIT) in one classic script for file:// in WKWebView. Nothing comes from a CDN.
// Trimmed to what Pip uses: English only, no Mermaid import, no font subsetting (that is for SVG export; Pip sends PNG).
const classicScript = {
  name: 'classic-script',
  transformIndexHtml: (html) => html.replace(/<script type="module" crossorigin/g, '<script defer'),
}
const unused = (msg) => `() => { throw new Error(${JSON.stringify(msg)}) }`
const STUBS = {
  '\0stub-locale': 'export default {}',
  '\0stub-mermaid': `export const parseMermaidToExcalidraw = ${unused('Mermaid is not in Pip')}`,
  '\0stub-subset-shared': `const no = ${unused('font subsetting is not in Pip')}; export const Commands = {}; export const subsetToBase64 = no; export const subsetToBinary = no; export const toBase64 = no`,
  '\0stub-subset-worker': 'export const WorkerUrl = undefined',
}
// Vite 8's bundler resolves these imports itself, so they are swapped when loaded, by file path.
const trim = {
  name: 'trim-excalidraw',
  load(id) {
    if (/[\\/]dist[\\/]prod[\\/]locales[\\/](?!en-)[^/\\]+\.js$/.test(id)) return STUBS['\0stub-locale']
    if (/[\\/]@excalidraw[\\/]mermaid-to-excalidraw[\\/]/.test(id)) return STUBS['\0stub-mermaid']
    if (id.endsWith('subset-shared.chunk.js')) return STUBS['\0stub-subset-shared']
    if (id.endsWith('subset-worker.chunk.js')) return STUBS['\0stub-subset-worker']
    return null
  },
}

export default defineConfig({
  base: './',
  plugins: [classicScript, trim],
  esbuild: { jsx: 'automatic' },
  define: { 'process.env.NODE_ENV': '"production"', 'process.env.IS_PREACT': '"false"' },
  build: {
    outDir: '../ios/Visual',
    emptyOutDir: true,
    minify: true,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 3000,
    rollupOptions: { output: { format: 'iife', inlineDynamicImports: true, entryFileNames: 'page.js', assetFileNames: '[name][extname]' } },
  },
})
