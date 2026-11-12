import { createRoot } from 'react-dom/client'
import { Tldraw, createShapeId, getIndices, toRichText } from 'tldraw'
import 'tldraw/tldraw.css'

// The visual explanation page inside the Pip keyboard. Native calls window.pip.*; the page answers on
// webkit.messageHandlers.pip with {type: 'ready' | 'step' | 'done' | 'png' | 'error'}.
// A scene is {title, canvas: {w, h}, steps: [{say, shapes}]} from POST /v1/explain/visual, already clamped by the server.

const post = (msg) => window.webkit?.messageHandlers?.pip?.postMessage(msg)
// The fonts are inlined as data URLs, so the PNG export can embed them (it cannot fetch file:// URLs).
import sans from './fonts/IBMPlexSans-Medium.woff2?inline'
import sansBold from './fonts/IBMPlexSans-Bold.woff2?inline'
import draw from './fonts/Shantell_Sans-Informal_Regular.woff2?inline'
import drawBold from './fonts/Shantell_Sans-Informal_Bold.woff2?inline'
// Only four font files ship. The other tldraw font slots point at them, so nothing is fetched from the tldraw CDN.
const assetUrls = {
  fonts: Object.fromEntries(['mono', 'serif', 'sans', 'draw'].flatMap((f) => {
    const [reg, bold] = f === 'draw' ? [draw, drawBold] : [sans, sansBold]
    return [[`tldraw_${f}`, reg], [`tldraw_${f}_italic`, reg], [`tldraw_${f}_bold`, bold], [`tldraw_${f}_italic_bold`, bold]]
  })),
}

let editor
let scene
let run = 0
const Cancelled = Symbol('cancelled')

const pen = Object.assign(document.createElement('div'), { className: 'pip-pen' })
pen.style.opacity = '0'
document.body.append(pen)

function movePen(x, y) {
  const p = editor.pageToViewport({ x, y })
  pen.style.left = `${p.x}px`
  pen.style.top = `${p.y}px`
  pen.style.opacity = '1'
}

const frame = () => new Promise((r) => requestAnimationFrame(r))
async function wait(ms, token) {
  const end = performance.now() + ms
  while (performance.now() < end) {
    if (token !== run) throw Cancelled
    await frame()
  }
  if (token !== run) throw Cancelled
}

/** The part of a polyline from its start to fraction t of its length. */
function partial(points, t) {
  const lens = [0]
  for (let i = 1; i < points.length; i++) lens.push(lens[i - 1] + Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]))
  const want = lens[lens.length - 1] * t
  const out = [points[0]]
  for (let i = 1; i < points.length; i++) {
    if (lens[i] <= want) { out.push(points[i]); continue }
    const f = (want - lens[i - 1]) / (lens[i] - lens[i - 1] || 1)
    out.push([points[i - 1][0] + (points[i][0] - points[i - 1][0]) * f, points[i - 1][1] + (points[i][1] - points[i - 1][1]) * f])
    break
  }
  if (out.length === 1) out.push(points[0])
  return { out, length: lens[lens.length - 1] }
}

function lineProps(points, ox, oy) {
  const keys = getIndices(points.length)
  return Object.fromEntries(points.map(([x, y], i) => [`p${i}`, { id: `p${i}`, index: keys[i], x: x - ox, y: y - oy }]))
}

/** Draws a polyline the way a pen would: a line shape that grows, with the buddy dot at its tip. */
async function trace(points, color, token, { keep = true, dash = 'draw' } = {}) {
  const id = createShapeId()
  const [ox, oy] = points[0]
  editor.createShape({ id, type: 'line', x: ox, y: oy, props: { color, dash, size: 'm', spline: 'line', points: lineProps([points[0], points[0]], ox, oy) } })
  const { length } = partial(points, 1)
  const ms = Math.min(1100, Math.max(280, length * 1.6))
  const start = performance.now()
  for (;;) {
    if (token !== run) throw Cancelled
    const t = Math.min(1, (performance.now() - start) / ms)
    const { out } = partial(points, t)
    editor.updateShape({ id, type: 'line', props: { points: lineProps(out, ox, oy) } })
    const tip = out[out.length - 1]
    movePen(tip[0], tip[1])
    if (t >= 1) break
    await frame()
  }
  if (!keep) editor.deleteShape(id)
  return id
}

async function typeText(shape, text, token) {
  const id = createShapeId()
  editor.createShape({ id, type: 'text', x: shape.x, y: shape.y, props: { color: shape.color, size: shape.size, font: 'draw', autoSize: true, richText: toRichText(text[0]) } })
  const perChar = Math.min(45, 900 / text.length)
  for (let n = 1; n <= text.length; n++) {
    editor.updateShape({ id, type: 'text', props: { richText: toRichText(text.slice(0, n)) } })
    const b = editor.getShapePageBounds(id)
    if (b) movePen(b.maxX + 4, b.midY)
    await wait(perChar, token)
  }
}

const ellipsePoints = (s) => Array.from({ length: 33 }, (_, i) => {
  const a = (i / 32) * Math.PI * 2 - Math.PI / 2
  return [s.x + s.w / 2 + (Math.cos(a) * s.w) / 2, s.y + s.h / 2 + (Math.sin(a) * s.h) / 2]
})

async function drawShape(s, token) {
  switch (s.type) {
    case 'text':
      return typeText(s, s.text, token)
    case 'line':
      return trace(s.points, s.color, token, { dash: 'solid' })
    case 'rect':
    case 'ellipse': {
      const path = s.type === 'rect' ? [[s.x, s.y], [s.x + s.w, s.y], [s.x + s.w, s.y + s.h], [s.x, s.y + s.h], [s.x, s.y]] : ellipsePoints(s)
      await trace(path, s.color, token, { keep: false })
      editor.createShape({ type: 'geo', x: s.x, y: s.y, props: {
        geo: s.type === 'rect' ? 'rectangle' : 'ellipse', w: s.w, h: s.h, color: s.color, labelColor: s.color,
        fill: s.fill ?? (s.w < 30 ? 'solid' : 'none'), dash: s.fill === 'solid' ? 'solid' : 'draw', size: s.w < 30 ? 's' : 'm', font: 'draw', richText: toRichText(s.label ?? ''),
      } })
      return
    }
    case 'arrow':
      await trace([[s.x1, s.y1], [s.x2, s.y2]], s.color, token, { keep: false })
      editor.createShape({ type: 'arrow', x: s.x1, y: s.y1, props: {
        start: { x: 0, y: 0 }, end: { x: s.x2 - s.x1, y: s.y2 - s.y1 }, color: s.color, labelColor: s.color,
        dash: 'draw', size: 'm', font: 'draw', richText: toRichText(s.label ?? ''),
      } })
  }
}

function fit() {
  if (!editor || !scene) return
  editor.zoomToBounds({ x: -12, y: -12, w: scene.canvas.w + 24, h: scene.canvas.h + 24 }, { immediate: true })
}

async function play() {
  const token = ++run
  editor.selectNone()
  editor.deleteShapes([...editor.getCurrentPageShapeIds()])
  fit()
  try {
    const m = scene.steps.length
    for (let i = 0; i < m; i++) {
      const st = scene.steps[i]
      post({ type: 'step', n: i + 1, m, say: st.say })
      for (const s of st.shapes) await drawShape(s, token)
      pen.style.opacity = '0'
      await wait(i === m - 1 ? 0 : 700, token)
    }
    pen.style.opacity = '0'
    post({ type: 'done', m })
  } catch (e) {
    if (e !== Cancelled) post({ type: 'error', message: String(e?.message ?? e) })
  }
}

async function exportPng() {
  try {
    run++
    pen.style.opacity = '0'
    const ids = [...editor.getCurrentPageShapeIds()]
    if (!ids.length) throw new Error('nothing to export')
    const { blob, width, height } = await editor.toImage(ids, { format: 'png', background: true, padding: 24, scale: 1, pixelRatio: 2, darkMode: false })
    const data = await new Promise((resolve, reject) => {
      const r = new FileReader()
      r.onload = () => resolve(String(r.result).split(',')[1])
      r.onerror = () => reject(r.error)
      r.readAsDataURL(blob)
    })
    post({ type: 'png', data, width, height })
  } catch (e) {
    post({ type: 'error', message: String(e?.message ?? e) })
  }
}

window.pip = {
  play(json) { scene = typeof json === 'string' ? JSON.parse(json) : json; play() },
  replay() { if (scene) play() },
  tool(name) { editor.setCurrentTool(['draw', 'eraser'].includes(name) ? name : 'hand') },
  undo() { editor.undo() },
  theme(dark) { editor.user.updateUserPreferences({ colorScheme: dark ? 'dark' : 'light' }) },
  export: exportPng,
}

function App() {
  return (
    <Tldraw
      hideUi
      assetUrls={assetUrls}
      licenseKey={import.meta.env.VITE_TLDRAW_LICENSE_KEY || undefined}
      onMount={(e) => {
        editor = e
        editor.setCurrentTool('hand')
        editor.updateInstanceState({ isGridMode: true })
        window.addEventListener('resize', fit)
        post({ type: 'ready' })
      }}
    />
  )
}

createRoot(document.getElementById('root')).render(<App />)
