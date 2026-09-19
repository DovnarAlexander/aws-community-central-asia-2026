// One Excalidraw scene, rendered as a stack of transparent layers.
//
//   node scripts/pptx/diagram-layers.mjs <scene.json> <outdir> <name> '<groups>'
//
// The deck's diagrams are drawn by hand in Excalidraw, which is what makes them
// read as drawn rather than as boxes. A slide that reveals one on clicks needs
// them in pieces, and pieces cut from one picture have to line up to the pixel.
//
// So every layer is exported from the whole scene with the elements that do not
// belong to it set to zero opacity. They still count towards the bounds, so all
// the layers come out the same size on the same origin and stack back into the
// original drawing.
import { createRequire } from 'node:module'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { join } from 'node:path'

const require = createRequire(import.meta.url)
const pw = (() => {
  for (const base of ['playwright-chromium', 'playwright']) {
    try { return require(base) } catch {}
  }
  console.error('  needs Playwright once: npm i -g playwright-chromium')
  process.exit(1)
})()

const [scenePath, outDir, name, groupsJson] = process.argv.slice(2)
const scene = JSON.parse(await readFile(scenePath, 'utf8'))
const groups = JSON.parse(groupsJson)
await mkdir(outDir, { recursive: true })

const browser = await pw.chromium.launch()
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } })
await page.goto('about:blank')

const SCALE = 3
for (let g = 0; g < groups.length; g++) {
  const keep = new Set(groups[g])
  const elements = scene.elements.map((e, i) =>
    keep.has(i) ? e : { ...e, opacity: 0 })
  const svg = await page.evaluate(async ({ elements, appState, files }) => {
    const { exportToSvg } = await import(
      'https://esm.sh/@excalidraw/excalidraw@0.18.0?bundle&exports=exportToSvg')
    const el = await exportToSvg({
      elements,
      appState: { ...appState, exportBackground: false, exportWithDarkMode: false, exportPadding: 8 },
      files: files ?? null,
    })
    return el.outerHTML
  }, { elements, appState: scene.appState, files: scene.files })

  const clean = svg
    .replace(/@font-face\s*\{[^}]*\}/g, '')
    .replace(/font-family:\s*"?(Excalifont|Virgil)"?/g, 'font-family: "DM Sans"')
    .replace(/font-family:\s*"?Helvetica"?/g, 'font-family: "DM Sans", system-ui, sans-serif')

  const w = Number(clean.match(/width="([\d.]+)"/)[1])
  const h = Number(clean.match(/height="([\d.]+)"/)[1])
  const shot = await browser.newPage({
    viewport: { width: Math.ceil(w), height: Math.ceil(h) }, deviceScaleFactor: SCALE })
  await shot.setContent(
    `<style>html,body{margin:0;background:transparent}svg{display:block;width:${w}px;height:${h}px}</style>` + clean)
  await shot.waitForTimeout(300)
  const file = join(outDir, `${name}-${g + 1}.png`)
  await shot.screenshot({ path: file, omitBackground: true })
  await shot.close()
  console.log(`  ${name}-${g + 1}.png  ${Math.round(w * SCALE)}x${Math.round(h * SCALE)}  ${keep.size} elements`)
}
await browser.close()
