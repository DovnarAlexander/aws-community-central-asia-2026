// Render slides/diagrams/*.excalidraw.json to slides/public/diagrams/*.svg.
//
// The slides load the SVGs, not the JSON. slidev-addon-excalidraw fetches the
// Excalidraw renderer from esm.sh when the slide mounts, and the one situation
// this deck exists for is a venue with no network — the same reason the
// asciinema player is vendored. So the CDN is used once, here, on a machine
// that has internet, and what ships is a flat SVG.
//
//   node scripts/render-diagrams.mjs        (or: task deck:diagrams)
import { createRequire } from 'node:module'
import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Playwright is a global install (`npm i -g playwright-chromium`), the same one
// `task deck:pdf` asks for. ESM will not look in the global tree, so resolve it
// through require, which will.
const require = createRequire(import.meta.url)
const pw = (() => {
  for (const base of ['playwright-chromium', 'playwright']) {
    try { return require(base) } catch {}
  }
  console.error('  render needs Playwright once: npm i -g playwright-chromium')
  process.exit(1)
})()

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const src  = join(root, 'slides', 'diagrams')
const out  = join(root, 'slides', 'public', 'diagrams')
await mkdir(out, { recursive: true })

const files = (await readdir(src)).filter(f => f.endsWith('.excalidraw.json'))
if (!files.length) { console.error('no scenes in slides/diagrams'); process.exit(1) }

const browser = await pw.chromium.launch()
const page = await browser.newPage()
await page.goto('about:blank')

for (const f of files) {
  const scene = JSON.parse(await readFile(join(src, f), 'utf8'))
  const svg = await page.evaluate(async (scene) => {
    const { exportToSvg } = await import('https://esm.sh/@excalidraw/excalidraw@0.18.0?bundle&exports=exportToSvg')
    const el = await exportToSvg({
      elements: scene.elements,
      appState: { ...scene.appState, exportBackground: false, exportWithDarkMode: false, exportPadding: 8 },
      files: scene.files ?? null,
    })
    return el.outerHTML
  }, scene)

  // Excalidraw writes @font-face rules that point at its own CDN. They are the
  // one thing in the output that still needs the network, and nothing here uses
  // a hand-drawn face anyway — the scenes are all fontFamily 2.
  const clean = svg
    .replace(/@font-face\s*\{[^}]*\}/g, '')
    .replace(/font-family:\s*"?Excalifont"?/g, 'font-family: "DM Sans"')
    .replace(/font-family:\s*"?Virgil"?/g, 'font-family: "DM Sans"')
    .replace(/font-family:\s*"?Helvetica"?/g, 'font-family: "DM Sans", system-ui, sans-serif')

  const name = f.replace('.excalidraw.json', '.svg')
  await writeFile(join(out, name), clean)
  console.log(`  slides/public/diagrams/${name}  ${(clean.length / 1024).toFixed(0)} KB`)
}
await browser.close()
