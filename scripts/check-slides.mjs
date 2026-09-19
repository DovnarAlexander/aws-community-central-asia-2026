// Check that every slide fits the canvas, at every click.
//
// Slidev clips a slide at 980x551 and says nothing, so a slide that grew by one
// line looks fine in the editor and loses its last sentence on the projector.
// This walks the deck in a headless browser, steps through each slide's clicks,
// and measures the bottom and right edge of every element against the canvas.
//
//   task deck:check
//
// It drives the dev server rather than the build, so the checked deck is the
// one being edited. Start it first (`task deck`) or pass a URL:
//
//   node scripts/check-slides.mjs http://localhost:3030
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const pw = (() => {
  for (const base of ['playwright-chromium', 'playwright']) {
    try { return require(base) } catch { /* try the next one */ }
  }
  console.error('  checking needs Playwright once: npm i -g playwright-chromium')
  process.exit(1)
})()

const base = process.argv[2] || 'http://localhost:3030'

const browser = await pw.chromium.launch()
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } })

try {
  await page.goto(`${base}/1`, { waitUntil: 'networkidle', timeout: 15000 })
} catch {
  console.error(`  nothing answering at ${base} — start the deck first: task deck`)
  await browser.close()
  process.exit(1)
}
await page.waitForTimeout(1500)

const total = await page.evaluate(() => window.__slidev__?.nav?.total ?? 0)
if (!total) {
  console.error('  could not read the slide count — is that URL a Slidev dev server?')
  await browser.close()
  process.exit(1)
}

// The visible page, not the layout: Slidev keeps neighbouring slides mounted at
// zero height, and the first `.slidev-layout` in the document is usually one of
// those rather than the slide on screen.
const measure = () => page.evaluate(() => {
  const root = [...document.querySelectorAll('.slidev-page')].find(e => e.offsetHeight > 0)
  if (!root) return null
  const canvas = root.getBoundingClientRect()
  const scale = canvas.width / root.offsetWidth
  let bottom = 0, right = 0, culprit = ''
  for (const el of root.querySelectorAll('*')) {
    // The hover-only copy button sits outside the canvas by design.
    if (el.tagName === 'BUTTON' || el.closest('.slidev-code-copy')) continue
    const b = el.getBoundingClientRect()
    if (b.width < 1 || b.height < 1) continue
    if (b.bottom - canvas.bottom > bottom) {
      bottom = b.bottom - canvas.bottom
      culprit = el.tagName.toLowerCase() +
        (el.className?.toString?.() ? `.${el.className.toString().split(' ').slice(0, 3).join('.')}` : '')
    }
    if (b.right - canvas.right > right) right = b.right - canvas.right
  }
  return { bottom: Math.round(bottom / scale), right: Math.round(right / scale), culprit }
})

let failed = 0
for (let slide = 1; slide <= total; slide++) {
  await page.goto(`${base}/${slide}`, { waitUntil: 'networkidle' })
  await page.waitForTimeout(900)
  const clicks = await page.evaluate(() => window.__slidev__?.nav?.clicksTotal ?? 0)

  let worst = { bottom: -Infinity, right: 0, culprit: '', click: 0 }
  for (let click = 0; click <= clicks; click++) {
    await page.goto(`${base}/${slide}?clicks=${click}`, { waitUntil: 'networkidle' })
    // Recordings and diagrams settle after the load event; clicks do not.
    await page.waitForTimeout(click === 0 ? 1100 : 450)
    const m = await measure()
    if (m && m.bottom > worst.bottom) worst = { ...m, click }
  }

  const over = worst.bottom > 0 || worst.right > 0
  if (over) failed++
  const where = clicks ? ` (worst at click ${worst.click} of ${clicks})` : ''
  console.log(
    over
      ? `  ✗ ${String(slide).padStart(2)}  ${worst.bottom > 0 ? `${worst.bottom}px past the bottom` : ''}` +
        `${worst.right > 0 ? ` ${worst.right}px past the right` : ''}${where} — ${worst.culprit}`
      : `  ✓ ${String(slide).padStart(2)}  fits${where}`
  )
}

await browser.close()
console.log(failed ? `\n  ${failed} of ${total} slides do not fit\n` : `\n  all ${total} slides fit\n`)
process.exit(failed ? 1 : 0)
