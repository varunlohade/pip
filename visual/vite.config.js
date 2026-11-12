import { defineConfig } from 'vite'

// The page loads from file:// inside the keyboard, so every path is relative and nothing comes from a CDN.
// Without VITE_TLDRAW_LICENSE_KEY this is a development build: tldraw runs with its watermark (development use only).
// With a key it is a production build that passes the key to tldraw.
// A classic deferred script, not a module: WKWebView loads it from file:// without any CORS question.
const classicScript = {
  name: 'classic-script',
  transformIndexHtml: (html) => html.replace(/<script type="module" crossorigin/g, '<script defer'),
}

export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [classicScript],
  esbuild: { jsx: 'automatic' },
  build: {
    outDir: '../ios/Visual',
    emptyOutDir: true,
    minify: true,
    sourcemap: false,
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 4000,
    rollupOptions: { output: { format: 'iife', entryFileNames: 'page.js', assetFileNames: '[name][extname]' } },
  },
  define: mode === 'development' ? { 'process.env.NODE_ENV': '"development"' } : {},
}))
