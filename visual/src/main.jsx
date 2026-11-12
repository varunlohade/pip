import { createRoot } from 'react-dom/client'
import { CaptureUpdateAction, Excalidraw, FONT_FAMILY, convertToExcalidrawElements, exportToBlob, restoreElements } from '@excalidraw/excalidraw'
import '@excalidraw/excalidraw/index.css'

// The Pip drawing page (Excalidraw, MIT). Native calls window.pip.*; the page answers on webkit.messageHandlers.pip with
// {type: 'ready' | 'step' | 'stepDrawn' | 'done' | 'png' | 'error'}. A scene is {title, canvas, steps: [{say, shapes}]} from
// POST /v1/explain/visual or the phone's chart builder. Pip's look: clean strokes (no sketchy wobble), the sky palette,
// solid fills, a sans for labels and the hand font only for callout notes.

const post = (msg) => window.webkit?.messageHandlers?.pip?.postMessage(msg)

// Pip's sky family with slate and ink. Any other colour a scene names becomes sky.
const PALETTE = { black: '#0B0C0F', grey: '#758696', blue: '#00B3FF', violet: '#0082F3', 'light-blue': '#7FD6FF', other: '#00B3FF' }
const ink = (c) => PALETTE[c] ?? PALETTE.other
// Stroke widths: ticks, axes, shapes and curves (a freehand curve is divided by 4.25 where it is drawn).
const WIDTH = { tick: 2.6, axis: 3.4, curve: 6.5, shape: 4.5 }
const STYLE = { roughness: 0, fillStyle: 'solid', roundness: { type: 3 } }
const FONT_SIZE = { s: 20, m: 26, l: 34 }
/** A clean sans for labels and numbers; the hand font only for callout notes (larger sky text). */
const fontFor = (s) => (s.size !== 's' && s.color === 'blue' ? FONT_FAMILY.Excalifont : FONT_FAMILY.Helvetica)

let api
let scene
let run = 0
// With voice on, each step waits after drawing until the app says its line is spoken (pip.next()).
let voice = false
let release = null
const Cancelled = Symbol('cancelled')
const pen = Object.assign(document.createElement('div'), { className: 'pip-pen' })
pen.style.opacity = '0'
document.body.append(pen)

const frame = () => new Promise((r) => requestAnimationFrame(r))
async function wait(ms, token) {
  const end = performance.now() + ms
  while (performance.now() < end) {
    if (token !== run) throw Cancelled
    await frame()
  }
}

function movePen(x, y) {
  const st = api.getAppState()
  pen.style.left = `${(x + st.scrollX) * st.zoom.value}px`
  pen.style.top = `${(y + st.scrollY) * st.zoom.value}px`
  pen.style.opacity = '1'
}

const base = (id, color, width) => ({ id, strokeColor: ink(color), strokeWidth: width, roughness: STYLE.roughness })

/** One scene shape as Excalidraw elements (one, or a few for a labelled box). */
function toElements(s, id) {
  switch (s.type) {
    case 'text':
      return convertToExcalidrawElements([{ ...base(id, s.color, 1), type: 'text', x: s.x, y: s.y, text: s.text, fontSize: FONT_SIZE[s.size] ?? 24, fontFamily: fontFor(s) }], { regenerateIds: false })
    case 'rect':
    case 'ellipse': {
      const small = s.w < 30
      const fill = s.fill === 'solid' || small ? 'solid' : null
      return convertToExcalidrawElements([{
        ...base(id, s.color, WIDTH.shape), type: s.type === 'rect' ? 'rectangle' : 'ellipse', x: s.x, y: s.y, width: s.w, height: s.h,
        backgroundColor: fill ? ink(s.color) : 'transparent', fillStyle: fill ?? STYLE.fillStyle,
        // A filled bar or swatch keeps square corners; an outlined box gets the soft corner.
        roundness: s.type === 'rect' && !fill ? STYLE.roundness : null,
        ...(s.label ? { label: { text: s.label, fontSize: 18, fontFamily: fontFor({ size: 's' }), strokeColor: ink(s.color) } } : {}),
      }], { regenerateIds: false })
    }
    case 'arrow':
      return convertToExcalidrawElements([{
        ...base(id, s.color, WIDTH.shape), type: 'arrow', x: s.x1, y: s.y1, points: [[0, 0], [s.x2 - s.x1, s.y2 - s.y1]],
        endArrowhead: 'arrow', startArrowhead: null, roundness: null,
        ...(s.label ? { label: { text: s.label, fontSize: 18, fontFamily: fontFor({ size: 's' }) } } : {}),
      }], { regenerateIds: false })
    case 'line': {
      const [ox, oy] = s.points[0]
      const rel = s.points.map(([x, y]) => [x - ox, y - oy])
      // Two points: an axis tick or a stroke. More: a plot, drawn as a smooth freehand stroke of even width.
      if (s.points.length <= 2) {
        return convertToExcalidrawElements([{ ...base(id, s.color, WIDTH.tick), type: 'line', x: ox, y: oy, points: rel, roundness: null }], { regenerateIds: false })
      }
      return [freedraw(id, s.color, ox, oy, rel)]
    }
    case 'polygon': {
      const [ox, oy] = s.points[0]
      const rel = [...s.points, s.points[0]].map(([x, y]) => [x - ox, y - oy])
      return convertToExcalidrawElements([{
        ...base(id, s.color, 2), type: 'line', x: ox, y: oy, points: rel, roundness: null,
        strokeColor: '#ffffff', backgroundColor: ink(s.color), fillStyle: 'solid',
      }], { regenerateIds: false })
    }
  }
  return []
}

/** A freehand stroke through the points, even width (no simulated pressure), so a plot reads as a clean curve. */
function freedraw(id, color, x, y, rel) {
  const [line] = convertToExcalidrawElements([{ ...base(id, color, WIDTH.curve), type: 'line', x, y, points: rel }], { regenerateIds: false })
  return restoreElements([{
    ...line, type: 'freedraw', roundness: null, lastCommittedPoint: null,
    // Excalidraw draws a freehand stroke about 4.25 times its stroke width.
    strokeWidth: WIDTH.curve / 4.25,
    simulatePressure: false, pressures: rel.map(() => 0.5),
  }], null)[0]
}

/** The path a pen follows to draw a shape. */
function penPath(s) {
  switch (s.type) {
    case 'line': return s.points
    case 'polygon': return [...s.points, s.points[0]]
    case 'arrow': return [[s.x1, s.y1], [s.x2, s.y2]]
    case 'rect': return [[s.x, s.y], [s.x + s.w, s.y], [s.x + s.w, s.y + s.h], [s.x, s.y + s.h], [s.x, s.y]]
    case 'ellipse': return Array.from({ length: 33 }, (_, i) => {
      const a = (i / 32) * Math.PI * 2 - Math.PI / 2
      return [s.x + s.w / 2 + (Math.cos(a) * s.w) / 2, s.y + s.h / 2 + (Math.sin(a) * s.h) / 2]
    })
  }
  return null
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

let done = []
const show = (extra = []) => api.updateScene({ elements: [...done, ...extra], captureUpdate: CaptureUpdateAction.NEVER })

async function drawShape(s, id, token) {
  const final = toElements(s, id)
  if (s.type === 'text') {
    const per = Math.min(45, 900 / s.text.length)
    for (let n = 1; n <= s.text.length; n++) {
      const [el] = toElements({ ...s, text: s.text.slice(0, n) }, id)
      show([el])
      movePen(el.x + el.width + 4, el.y + el.height / 2)
      await wait(per, token)
    }
  } else {
    const path = penPath(s)
    const { length } = partial(path, 1)
    const ms = Math.min(1100, Math.max(280, length * 1.6))
    const start = performance.now()
    for (;;) {
      if (token !== run) throw Cancelled
      const t = Math.min(1, (performance.now() - start) / ms)
      const { out } = partial(path, t)
      const [ox, oy] = out[0]
      const color = s.type === 'polygon' ? s.color : s.color
      const width = s.type === 'line' && s.points.length > 2 ? WIDTH.curve : s.type === 'line' ? WIDTH.tick : WIDTH.shape
      // While the pen moves it leaves a plain stroke; the finished shape (fill, label, arrow head) replaces it at the end.
      const trail = s.type === 'line' && s.points.length > 2
        ? freedraw(`${id}-trail`, color, ox, oy, out.map(([x, y]) => [x - ox, y - oy]))
        : convertToExcalidrawElements([{ ...base(`${id}-trail`, color, width), type: 'line', x: ox, y: oy, points: out.map(([x, y]) => [x - ox, y - oy]), roundness: null }], { regenerateIds: false })[0]
      show([trail])
      const tip = out[out.length - 1]
      movePen(tip[0], tip[1])
      if (t >= 1) break
      await frame()
    }
  }
  done = [...done, ...final]
  show()
}

function fit() {
  if (!api || !scene) return
  const all = scene.steps.flatMap((st, i) => st.shapes.flatMap((s, j) => toElements(s, `fit-${i}-${j}`)))
  // The drawing fills the panel with about 8% room around it.
  api.scrollToContent(all, { fitToViewport: true, viewportZoomFactor: 0.86, animate: false })
}

async function play() {
  const token = ++run
  release?.()
  done = []
  show()
  fit()
  try {
    const m = scene.steps.length
    for (let i = 0; i < m; i++) {
      const st = scene.steps[i]
      post({ type: 'step', n: i + 1, m, say: st.say })
      for (let j = 0; j < st.shapes.length; j++) await drawShape(st.shapes[j], `s${i}-${j}`, token)
      pen.style.opacity = '0'
      post({ type: 'stepDrawn', n: i + 1 })
      if (voice) {
        await new Promise((resolve) => { release = resolve })
        release = null
        if (token !== run) throw Cancelled
      } else {
        await wait(i === m - 1 ? 0 : 700, token)
      }
    }
    pen.style.opacity = '0'
    // The finished drawing becomes the first undo step, so Undo removes only what the owner draws on it.
    api.updateScene({ elements: done, captureUpdate: CaptureUpdateAction.IMMEDIATELY })
    post({ type: 'done', m })
  } catch (e) {
    if (e !== Cancelled) post({ type: 'error', message: String(e?.message ?? e) })
  }
}

async function exportPng() {
  try {
    run++
    pen.style.opacity = '0'
    const elements = api.getSceneElements()
    if (!elements.length) throw new Error('nothing to export')
    const blob = await exportToBlob({
      elements, files: api.getFiles(), mimeType: 'image/png', exportPadding: 24,
      // 2x, so the image stays sharp when it is pasted into a chat.
      getDimensions: (width, height) => ({ width: width * 2, height: height * 2, scale: 2 }),
      appState: { ...api.getAppState(), exportBackground: true, viewBackgroundColor: '#ffffff', exportWithDarkMode: false },
    })
    const data = await new Promise((resolve, reject) => {
      const r = new FileReader()
      r.onload = () => resolve(String(r.result).split(',')[1])
      r.onerror = () => reject(r.error)
      r.readAsDataURL(blob)
    })
    post({ type: 'png', data })
  } catch (e) {
    post({ type: 'error', message: String(e?.message ?? e) })
  }
}

/** Excalidraw has no undo call in its API; it listens for the keyboard shortcut, so the toolbar sends that. */
function shortcut(redo) {
  for (const target of [document.querySelector('.excalidraw'), document]) {
    target?.dispatchEvent(new KeyboardEvent('keydown', { key: redo ? 'Z' : 'z', code: 'KeyZ', metaKey: true, ctrlKey: true, shiftKey: redo, bubbles: true }))
  }
}

window.pip = {
  play(json) { scene = typeof json === 'string' ? JSON.parse(json) : json; play() },
  replay() { if (scene) play() },
  voice(on) { voice = !!on; if (!voice) release?.() },
  next() { release?.() },
  tool(name) { api.setActiveTool({ type: name === 'draw' ? 'freedraw' : name === 'eraser' ? 'eraser' : 'hand' }) },
  undo() { shortcut(false) },
  redo() { shortcut(true) },
  theme() {},
  export: exportPng,
}

function App() {
  return (
    <Excalidraw
      excalidrawAPI={(a) => {
        if (api) return
        api = a
        setTimeout(() => { api.setActiveTool({ type: 'hand' }); post({ type: 'ready' }) }, 0)
        window.addEventListener('resize', () => setTimeout(fit, 60))
      }}
      initialData={{
        appState: {
          viewBackgroundColor: '#ffffff',
          // Excalidraw's grid is lines, which look busy in a small panel, so the page stays plain white.
          gridModeEnabled: false,
          currentItemStrokeColor: PALETTE.blue,
          currentItemStrokeWidth: 2.6,
          currentItemRoughness: STYLE.roughness,
        },
      }}
      UIOptions={{ canvasActions: { changeViewBackgroundColor: false, clearCanvas: false, export: false, loadScene: false, saveToActiveFile: false, toggleTheme: false, saveAsImage: false } }}
      zenModeEnabled
      detectScroll={false}
      handleKeyboardGlobally
    />
  )
}

createRoot(document.getElementById('root')).render(<App />)
