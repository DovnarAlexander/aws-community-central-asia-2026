// slides/talk.md, as a PowerPoint deck.
//
//   node scripts/pptx/build.mjs <workdir> [out.pptx]
//
// Reads the structure extract.py wrote, the pictures assets.mjs rasterised and
// the recordings film.mjs cut, and lays them out. Nothing here parses markdown.
//
// Fonts are Calibri and Courier New rather than the deck's DM Sans and Fira
// Code: PowerPoint renders whatever the opener has installed, and those two are
// the ones every Office already ships.
import { createRequire } from 'node:module'

// NODE_PATH is a CommonJS mechanism, so a bare ESM import of a globally
// installed package does not resolve. check-slides.mjs already goes through
// createRequire for exactly this reason.
const require = createRequire(import.meta.url)
const PptxGenJS = require('pptxgenjs')
import fs from 'node:fs'
const SP = process.argv[2]
const FILE = process.argv[3] || 'slides/talk.pptx'
const deck = JSON.parse(fs.readFileSync(SP + '/deck.json', 'utf8'))
const cuts = JSON.parse(fs.readFileSync('slides/public/casts/full.cuts.json', 'utf8'))
const titleOf = s => (cuts.cuts.find(c => c.step === s) || {}).title || ''

// The deck's own palette, straight out of the Naviteq theme.
const INK = '1E1E2F', BRAND = '3B3DBF', DEEP = '1E1E6E', MUTED = '6B7280', SURF = 'F7F8FC', LINE = 'E5E7EB'
const SANS = 'Calibri', MONO = 'Courier New'      

const pres = new PptxGenJS()
pres.layout = 'LAYOUT_WIDE'                        // 13.3 x 7.5, the same 16:9 Slidev uses
pres.author = 'Alexander Dovnar'
pres.title  = 'The probe that killed itself'

const img = n => ({ path: SP + '/img/' + n + '.png' })
const still = s => ({ path: SP + '/stills/' + s + '.png' })
const has = n => fs.existsSync(SP + '/img/' + n + '.png')

function notes(sl, s) { if (s.notes && s.notes.trim()) sl.addNotes(s.notes.trim()) }

// Background as a rectangle as well as a property. pptxgenjs writes <p:bgPr>
// without the <a:effectLst/> the schema asks for: PowerPoint forgives that,
// LibreOffice does not, and every dark slide comes out white. A rectangle is
// something every renderer draws.
function paint(sl, color) {
  sl.background = { color }
  sl.addShape(pres.ShapeType.rect, { x: 0, y: 0, w: 13.33, h: 7.5, fill: { color }, line: { color, width: 0 } })
}

let made = 0
for (const s of deck) {
  const sl = pres.addSlide()
  made++

  // ── cover and closing card: dark ground, one heading ─────────────────────
  if (s.layout === 'cover' || s.layout === 'end') {
    paint(sl, DEEP)
    sl.addText(s.title, { x: 0.9, y: 2.0, w: 11.5, h: 1.2,
      fontFace: SANS, fontSize: 40, bold: true, color: 'FFFFFF' })
    let ty = 3.35
    if (s.subtitle) {
      sl.addText(s.subtitle, { x: 0.9, y: ty, w: 10.5, h: 0.6,
        fontFace: SANS, fontSize: 20, color: 'CADCFC' })
      ty += 0.95
    }
    // The subtitle appears both on its own and inside prose; without removing
    // it the two lines were drawn on top of each other at the same point.
    const seen = new Set([s.subtitle, s.title].filter(Boolean))
    const tail = s.prose.split('\n').filter(l => l.length > 3 && !seen.has(l))
    if (tail.length) sl.addText(tail.slice(0, 4).join('\n'), { x: 0.9, y: ty,
      w: s.layout === 'end' ? 7.6 : 10.5, h: 2.0, fontFace: SANS, fontSize: 14,
      color: 'CADCFC', lineSpacingMultiple: 1.35, valign: 'top' })
    if (s.layout === 'end' && has('qr')) sl.addImage({ ...img('qr'), x: 9.5, y: 3.2, w: 2.7, h: 2.7 })
    // The mark has to be white here: the original is navy, and so is the slide.
    if (has('logo-white')) sl.addImage({ ...img('logo-white'), x: 0.9, y: 6.45, w: 1.5, h: 1.5 * 352 / 960 })
    notes(sl, s); continue
  }

  // ── incident dividers ────────────────────────────────────────────────────
  if (s.layout === 'section') {
    paint(sl, BRAND)
    sl.addText(s.title, { x: 0.9, y: 3.0, w: 11.5, h: 1.3,
      fontFace: SANS, fontSize: 44, bold: true, color: 'FFFFFF' })
    if (s.prose) sl.addText(s.prose.split('\n')[0], { x: 0.9, y: 4.3, w: 10, h: 0.7,
      fontFace: SANS, fontSize: 18, color: 'CADCFC' })
    notes(sl, s); continue
  }

  // ── a recorded step: the film, with its number above it ──────────────────
  if (s.step) {
    paint(sl, '1E1E1E')
    // Video rather than a still: H.264 at the recording's own resolution, timed
    // by the cast itself. The cover is not optional -- without one pptxgenjs
    // draws its default poster, a play button on grey, in the middle of the slide.
    const vid = SP + '/video/' + s.step + '.mp4'
    const AR = 1920 / 1294
    const h = 7.01, w = h * AR
    if (fs.existsSync(vid)) {
      // cover takes a data URI, not a path; a path throws.
      const cov = 'image/jpeg;base64,' + fs.readFileSync(SP + '/covers/' + s.step + '.jpg').toString('base64')
      sl.addMedia({ type: 'video', path: vid, cover: cov, x: (13.33 - w) / 2, y: 0.38, w, h })
    } else {
      sl.addImage({ ...still(s.step), x: 0.0, y: 0.38, w: 13.33, h: 7.01 })
    }
    sl.addText(`${s.step}  ·  ${titleOf(s.step)}`, { x: 0, y: 0, w: 13.33, h: 0.38,
      fontFace: MONO, fontSize: 12, color: 'CADCFC', align: 'center', valign: 'middle', margin: 0 })
    notes(sl, s); continue
  }

  // ── an ordinary slide ────────────────────────────────────────────────────
  paint(sl, 'FFFFFF')
  sl.addText(s.title, { x: 0.75, y: 0.5, w: 11.8, h: 0.9,
    fontFace: SANS, fontSize: 32, bold: true, color: BRAND })

  const lead = s.prose.split('\n').filter(l => l.length > 3)
  const diagram = { 'What is actually running': 'architecture', 'The loop': 'loop',
                    'The question the probe was asking': 'probes',
                    'The fix is three things, and only one is a probe': 'verdicts' }[s.title]

  let y = 1.55
  const textW = diagram || s.code.length ? 6.0 : 11.8

  if (s.bullets.length) {
    sl.addText(s.bullets.map((b, i) => ({ text: b, options: { bullet: true, breakLine: i < s.bullets.length - 1 } })),
      { x: 0.75, y, w: 11.8, h: 5.0, fontFace: SANS, fontSize: 15, color: INK, paraSpaceAfter: 8, valign: 'top' })
  } else if (lead.length) {
    sl.addText(lead.slice(0, 6).join('\n\n'), { x: 0.75, y, w: textW, h: 5.0,
      fontFace: SANS, fontSize: 15, color: INK, lineSpacingMultiple: 1.35, valign: 'top' })
  }

  const tbl = (s.tables || [])[0]
  if (tbl && tbl.length > 1) {
    sl.addTable(
      tbl.map((row, r) => row.map(cell => ({ text: cell, options: {
        bold: r === 0, color: r === 0 ? 'FFFFFF' : INK,
        fill: { color: r === 0 ? BRAND : (r % 2 ? 'FFFFFF' : SURF) } } }))),
      { x: 7.0, y: 1.6, w: 5.55, fontFace: SANS, fontSize: 13, border: { type: 'solid', color: LINE, pt: 1 },
        align: 'left', valign: 'middle', rowH: 0.42, margin: 6 })
  } else if (s.code.length) {
    const code = s.code[0].text.split('\n').slice(0, 14).join('\n')
    sl.addShape(pres.ShapeType.roundRect, { x: 7.0, y: 1.45, w: 5.55, h: 4.6,
      fill: { color: SURF }, line: { color: LINE, width: 1 }, rectRadius: 0.06 })
    sl.addText(code, { x: 7.25, y: 1.65, w: 5.05, h: 4.2,
      fontFace: MONO, fontSize: 11, color: INK, valign: 'top', margin: 0 })
  } else if (diagram && has(diagram)) {
    sl.addImage({ ...img(diagram), x: 6.9, y: 1.7, w: 5.7, h: 5.7 * 0.46 })
  }
  notes(sl, s)
}

await pres.writeFile({ fileName: FILE })
console.log('  ' + made + ' slides')
