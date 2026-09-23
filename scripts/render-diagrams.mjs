// Render slides/diagrams/*.excalidraw.json to slides/public/diagrams/*.svg.
//
// The slides load the SVGs, not the JSON. slidev-addon-excalidraw fetches the
// Excalidraw renderer from esm.sh when the slide mounts, and the one situation
// this deck exists for is a venue with no network — the same reason the
// asciinema player is vendored. So the CDN is used once, here, on a machine
// that has internet, and what ships is a flat SVG.
//
// A scene the deck reveals on clicks is also exported once per group as
// <name>-<k>.svg, the same way diagram-layers.mjs cuts the PowerPoint copy:
// the elements outside the group at zero opacity, so they still count towards
// the bounds and every layer lands on the same origin at the same size. The
// groups come from onto-template.py's SCENES via `extract.py --scenes`, so the
// web deck and the .pptx cannot fall out of step about what a click shows.
//
//   node scripts/render-diagrams.mjs        (or: task deck:diagrams)
import { createRequire } from 'node:module'
import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises'
import { execFileSync } from 'node:child_process'
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

const scenes = {}
for (const line of execFileSync('python3',
    [join(root, 'scripts', 'pptx', 'extract.py'), '--scenes'],
    { encoding: 'utf8' }).trim().split('\n')) {
  const [name, groups] = line.split('|')
  scenes[name] = JSON.parse(groups)
}

const files = (await readdir(src)).filter(f => f.endsWith('.excalidraw.json'))
if (!files.length) { console.error('no scenes in slides/diagrams'); process.exit(1) }

const browser = await pw.chromium.launch()
const page = await browser.newPage()
await page.goto('about:blank')

const render = async (elements, appState, sceneFiles) => {
  const svg = await page.evaluate(async ({ elements, appState, files }) => {
    const { exportToSvg } = await import('https://esm.sh/@excalidraw/excalidraw@0.18.0?bundle&exports=exportToSvg')
    const el = await exportToSvg({
      elements,
      appState: { ...appState, exportBackground: false, exportWithDarkMode: false, exportPadding: 8 },
      files: files ?? null,
    })
    return el.outerHTML
  }, { elements, appState, files: sceneFiles })

  // Excalidraw writes @font-face rules that point at its own CDN. They are the
  // one thing in the output that still needs the network, and nothing here uses
  // a hand-drawn face anyway — the scenes are all fontFamily 2.
  return svg
    .replace(/@font-face\s*\{[^}]*\}/g, '')
    .replace(/font-family:\s*"?Excalifont"?/g, 'font-family: "DM Sans"')
    .replace(/font-family:\s*"?Virgil"?/g, 'font-family: "DM Sans"')
    .replace(/font-family:\s*"?Helvetica"?/g, 'font-family: "DM Sans", system-ui, sans-serif')
}

for (const f of files) {
  const scene = JSON.parse(await readFile(join(src, f), 'utf8'))
  const base = f.replace('.excalidraw.json', '')

  const clean = await render(scene.elements, scene.appState, scene.files)
  await writeFile(join(out, `${base}.svg`), clean)
  console.log(`  slides/public/diagrams/${base}.svg  ${(clean.length / 1024).toFixed(0)} KB`)

  for (const [g, keepList] of (scenes[base] ?? []).entries()) {
    const keep = new Set(keepList)
    const masked = scene.elements.map((e, i) => keep.has(i) ? e : { ...e, opacity: 0 })
    const layer = await render(masked, scene.appState, scene.files)
    await writeFile(join(out, `${base}-${g + 1}.svg`), layer)
    console.log(`  slides/public/diagrams/${base}-${g + 1}.svg  ${(layer.length / 1024).toFixed(0)} KB  ${keep.size} elements`)
  }
}
await browser.close()
