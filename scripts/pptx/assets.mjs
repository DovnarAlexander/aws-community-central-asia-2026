// The deck's pictures, rasterised for PowerPoint.
//
//   node scripts/pptx/assets.mjs <outdir>
//
// PowerPoint's SVG support is uneven and the diagrams are the one thing that has
// to look right on somebody else's laptop, so everything ships as PNG.
//
// qr.svg and the logo carry width and height but no viewBox. Setting a width on
// such an SVG resizes the canvas and leaves the drawing at its original size in
// the corner, which is how the QR first came out as a stamp in a white field.
// deviceScaleFactor scales the drawing with it.
import { createRequire } from 'node:module'

// NODE_PATH is a CommonJS mechanism, so a bare ESM import of a globally
// installed package does not resolve. check-slides.mjs already goes through
// createRequire for exactly this reason.
const require = createRequire(import.meta.url)
const { chromium } = require('playwright-chromium')
import fs from 'node:fs'

const OUT = process.argv[2]
fs.mkdirSync(`${OUT}/img`, { recursive: true })
const browser = await chromium.launch()

const jobs = [
  ['slides/public/diagrams/architecture.svg', 'architecture', {}],
  ['slides/public/diagrams/loop.svg', 'loop', {}],
  ['slides/public/diagrams/probes.svg', 'probes', {}],
  ['slides/public/diagrams/verdicts.svg', 'verdicts', {}],
  ['slides/public/qr.svg', 'qr', {}],
  ['slides/public/brand/naviteq-logo.svg', 'logo', { transparent: true }],
  // The mark is dark navy, and the cover and the closing card are dark navy.
  ['slides/public/brand/naviteq-logo.svg', 'logo-white', { transparent: true, invert: true }],
]

for (const [src, name, opt] of jobs) {
  if (!fs.existsSync(src)) { console.log(`  ${name.padEnd(13)} missing, skipped`); continue }
  const svg = fs.readFileSync(src, 'utf8')
  const box = svg.match(/viewBox="([\d.\-\s]+)"/)
  const w = box ? Number(box[1].trim().split(/\s+/)[2]) : Number((svg.match(/width="(\d+)"/) || [])[1] || 800)
  const h = box ? Number(box[1].trim().split(/\s+/)[3]) : Number((svg.match(/height="(\d+)"/) || [])[1] || 600)
  const scale = Math.max(1, Math.min(8, Math.round(1600 / w)))
  const page = await browser.newPage({ viewport: { width: Math.round(w), height: Math.round(h) }, deviceScaleFactor: scale })
  const filter = opt.invert ? 'filter:brightness(0) invert(1);' : ''
  await page.setContent(`<style>html,body{margin:0;${opt.transparent ? '' : 'background:#fff'}}`
    + `svg{display:block;width:${w}px;height:${h}px;${filter}}</style>` + svg)
  await page.waitForTimeout(250)
  await page.screenshot({ path: `${OUT}/img/${name}.png`, omitBackground: !!opt.transparent })
  console.log(`  ${name.padEnd(13)} ${Math.round(w * scale)}x${Math.round(h * scale)}`)
  await page.close()
}
await browser.close()
