// Copies the one Excalidraw font Pip draws with (Excalifont, for callout notes) next to the page.
// Labels use the system Helvetica family, so no other font ships.
import { cpSync, mkdirSync } from 'node:fs'
const from = new URL('./node_modules/@excalidraw/excalidraw/dist/prod/fonts/Excalifont/', import.meta.url)
const to = new URL('../ios/Visual/fonts/Excalifont/', import.meta.url)
mkdirSync(to, { recursive: true })
cpSync(from, to, { recursive: true })
console.log('copied Excalifont')
