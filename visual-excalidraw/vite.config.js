import { defineConfig } from 'vite'

// The Excalidraw drawing page (MIT), built next to the tldraw one for a side-by-side preview.
// One classic script for file:// in WKWebView; English only (other locales are stubbed out); fonts copied by the build step.
const classicScript = {
  name: 'classic-script',
  transformIndexHtml: (html) => html.replace(/<script type="module" crossorigin/g, '<script defer'),
}
const englishOnly = {
  name: 'english-only',
  resolveId(id) { return /locales\/(?!en-)[a-z]{2}(-[A-Z]{2,})?-[A-Z0-9]+\.js$/.test(id) ? '\0empty-locale' : null },
  load(id) { return id === '\0empty-locale' ? 'export default {}' : null },
}

export default defineConfig({
  base: './',
  plugins: [classicScript, englishOnly],
  esbuild: { jsx: 'automatic' },
  define: { 'process.env.NODE_ENV': '"production"', 'process.env.IS_PREACT': '"false"' },
  build: {
    outDir: '../ios/VisualExcalidraw',
    emptyOutDir: true,
    minify: true,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 6000,
    rollupOptions: { output: { format: 'iife', inlineDynamicImports: true, entryFileNames: 'page.js', assetFileNames: '[name][extname]' } },
  },
})
