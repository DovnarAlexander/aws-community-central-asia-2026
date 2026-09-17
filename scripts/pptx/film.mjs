// One recorded step out of full.cast, as an H.264 video PowerPoint can play.
//
//   node scripts/pptx/film.mjs <outdir> [step ...]
//
// Frames come from the asciinema player itself, driven to each of the moments
// the recording actually writes something. Capturing in real time does not work:
// Chromium's screencast in headless is capped around three frames a second, which
// is where the first attempt's jerk came from. Seeking to the event times instead
// takes the browser out of the timing question entirely -- every frame the player
// would ever paint is captured, and the durations come from the cast, so playback
// matches the recording to the millisecond.
//
// The player is served from a throwaway static server over slides/public rather
// than from a running `task deck`, so this needs nothing else to be up.
import { createRequire } from 'node:module'

// NODE_PATH is a CommonJS mechanism, so a bare ESM import of a globally
// installed package does not resolve. check-slides.mjs already goes through
// createRequire for exactly this reason.
const require = createRequire(import.meta.url)
const { chromium } = require('playwright-chromium')
import { createServer } from 'node:http'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const OUT = process.argv[2]
const WIDTH = Number(process.env.PPTX_WIDTH || 1920)
const MAXFPS = Number(process.env.PPTX_FPS || 25)
const CRF = String(process.env.PPTX_CRF || 20)
const CASTS = 'slides/public/casts'
const cuts = JSON.parse(fs.readFileSync(`${CASTS}/full.cuts.json`, 'utf8'))
const want = process.argv.slice(3)
const steps = cuts.cuts.filter(c => !want.length || want.includes(c.step))

const PAGE = `<!doctype html><meta charset="utf-8">
<link rel="stylesheet" href="/vendor/asciinema-player.css">
<style>html,body{margin:0;background:#1e1e1e;overflow:hidden}#p{width:100vw}
 /* The paused overlay draws a play button over the terminal; it is not part of
    the recording and must not be part of the film. */
 .ap-overlay-start,.ap-play-button,.ap-control-bar{display:none !important}</style>
<div id="p"></div><script src="/vendor/asciinema-player.min.js"></script>
<script>window.ap = AsciinemaPlayer.create('/casts/full.cast', document.getElementById('p'),
  { fit:'width', autoPlay:false, controls:false, poster:null, idleTimeLimit:${cuts.idle_time_limit} })</script>`

const TYPES = { '.css': 'text/css', '.js': 'text/javascript', '.cast': 'text/plain', '.json': 'application/json' }
const srv = createServer((req, res) => {
  const url = req.url.split('?')[0]
  if (url === '/') { res.setHeader('content-type', 'text/html'); return res.end(PAGE) }
  const file = path.join('slides/public', url)
  if (!fs.existsSync(file)) { res.statusCode = 404; return res.end('no') }
  res.setHeader('content-type', TYPES[path.extname(file)] || 'application/octet-stream')
  res.end(fs.readFileSync(file))
})
await new Promise(r => srv.listen(0, r))
const base = `http://127.0.0.1:${srv.address().port}/`

// Every moment the recording writes to the terminal, in the player's own clock.
const idle = cuts.idle_time_limit
const marks = []
let clock = 0
for (const l of fs.readFileSync(`${CASTS}/full.cast`, 'utf8').split('\n').slice(1)) {
  if (!l.startsWith('[')) continue
  const [dt, kind] = JSON.parse(l)
  clock += Math.min(dt, idle)
  if (kind === 'o') marks.push(clock)
}

fs.mkdirSync(`${OUT}/video`, { recursive: true })
fs.mkdirSync(`${OUT}/covers`, { recursive: true })

const browser = await chromium.launch()
for (const c of steps) {
  const end = c.to ?? cuts.duration
  const times = []
  for (const t of marks) {
    if (t < c.from || t >= end) continue
    if (!times.length || t - times[times.length - 1] >= 1 / MAXFPS) times.push(t)
  }
  if (!times.length || times[0] > c.from) times.unshift(c.from)

  const work = `${OUT}/frames/${c.step}`
  fs.rmSync(work, { recursive: true, force: true })
  fs.mkdirSync(work, { recursive: true })

  const page = await browser.newPage({ viewport: { width: WIDTH, height: 1200 } })
  await page.goto(base, { waitUntil: 'networkidle' })
  await page.waitForTimeout(2500)
  let H = await page.evaluate(() => Math.round(document.querySelector('.ap-player').getBoundingClientRect().height))
  H -= H % 2                                     // yuv420p refuses odd dimensions
  await page.setViewportSize({ width: WIDTH, height: H })
  await page.waitForTimeout(500)
  const cdp = await page.context().newCDPSession(page)

  for (let i = 0; i < times.length; i++) {
    await page.evaluate(async t => { await window.ap.seek(t); await window.ap.pause() }, times[i])
    const { data } = await cdp.send('Page.captureScreenshot', { format: 'jpeg', quality: 90 })
    fs.writeFileSync(`${work}/f${String(i).padStart(5, '0')}.jpg`, Buffer.from(data, 'base64'))
  }
  await page.close()

  const list = []
  for (let i = 0; i < times.length; i++) {
    list.push(`file 'f${String(i).padStart(5, '0')}.jpg'`)
    const next = i + 1 < times.length ? times[i + 1] : end
    list.push(`duration ${Math.max(0.01, next - times[i]).toFixed(4)}`)
  }
  list.push(`file 'f${String(times.length - 1).padStart(5, '0')}.jpg'`)
  fs.writeFileSync(`${work}/list.txt`, list.join('\n'))

  // Padded to the slide's shape. The recording is 167x44 characters, which comes
  // out near 3:2, and a slide is 16:9; played at its own proportions it sits in
  // the middle of the slide with the template showing around it, which is the
  // one place the template and the terminal fight. The bars are the terminal's
  // own background colour out of the cast header, so the film simply fills the
  // slide. Padding rather than cropping: every column of the stage stays.
  const bg = (JSON.parse(fs.readFileSync(`${CASTS}/full.cast`, 'utf8').split('\n')[0])
    .term?.theme?.bg || '#1e1e1e').replace('#', '0x')
  const padW = Math.round(H * 16 / 9 / 2) * 2

  // A progress bar burnt into the film, so the slide itself says how much of the
  // step is left. PowerPoint cannot report a video's position on the slide, and a
  // PowerPoint animation timed to match would drift the moment playback did.
  // In the film it cannot drift.
  //
  // A bar rather than a clock because this ffmpeg has no drawtext -- no
  // libfreetype -- and because a presenter reads a proportion faster than digits.
  // The ticks every thirty seconds are what make it absolute as well: count the
  // marks left of the end and you have the time.
  const BAR = 10
  const secs = end - c.from
  const bars = [
    `drawbox=x=0:y=ih-${BAR}:w=iw:h=${BAR}:color=0x000000@0.55:t=fill`,
    `drawbox=x=0:y=ih-${BAR}:w='iw*t/${secs.toFixed(3)}':h=${BAR}:color=0xE97132@0.95:t=fill`,
  ]
  for (let mark = 30; mark < secs; mark += 30) {
    const at = (mark / secs).toFixed(5)
    bars.push(`drawbox=x='iw*${at}':y=ih-${BAR}:w=3:h=${BAR}:color=0xFFFFFF@0.45:t=fill`)
  }

  const mp4 = `${OUT}/video/${c.step}.mp4`
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', `${work}/list.txt`,
    '-r', '30', '-vf', [`pad=${padW}:${H}:(ow-iw)/2:0:color=${bg}`, ...bars].join(','),
    '-c:v', 'libx264', '-preset', 'slow', '-crf', CRF, '-tune', 'stillimage',
    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', mp4])
  // A poster, so the slide shows the terminal rather than pptxgenjs's grey
  // play-button placeholder while the video waits to start.
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', String((end - c.from) * 0.6),
    '-i', mp4, '-vframes', '1', '-q:v', '4', `${OUT}/covers/${c.step}.jpg`])
  fs.rmSync(work, { recursive: true, force: true })
  const mb = fs.statSync(mp4).size / 1048576
  console.log(`  ${c.step.padEnd(5)} ${String(Math.round(end - c.from)).padStart(3)}s  ${padW}x${H} (16:9)  ${times.length} frames  ${mb.toFixed(1)} MB`)
}
await browser.close()
srv.close()
