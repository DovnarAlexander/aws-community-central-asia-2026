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

// The terminal element asciinema draws is transparent: cells with characters in
// them get painted, and everything else shows whatever is behind. Behind it was
// a hardcoded #1e1e1e, so a recording from a light terminal came out with a
// black band under its last line -- not padding, and nothing downstream could
// reach it. The recording carries the terminal's own background in its header,
// which is the only right answer for both the page and the bars beside it.
const HEAD = JSON.parse(fs.readFileSync(`${CASTS}/full.cast`, 'utf8').split('\n')[0])
const ROWS = HEAD.term?.rows || HEAD.height || 24
const BG = (HEAD.term?.theme?.bg || '#1e1e1e')
const bg = BG.replace('#', '0x')

// Steps held longer in the deck than they ran, as a factor on every frame's
// duration. Shared with extract.py, which has to tell the notes how long the
// slide is; the file says why each entry is there.
const HOLD = JSON.parse(fs.readFileSync('scripts/pptx/hold.json', 'utf8'))
// A step cut into beats is `1.2.3`, and the factor is written against `1.2`:
// stretching is a property of the step, not of which slide of it you are on.
const held = c => HOLD[c.step] ?? HOLD[c.parent] ?? 1

const PAGE = `<!doctype html><meta charset="utf-8">
<link rel="stylesheet" href="/vendor/asciinema-player.css">
<style>html,body{margin:0;background:${BG};overflow:hidden}#p{width:100vw}
 .ap-player,.ap-term{background:${BG} !important}
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

// One player, one measurement, every film.
//
// This used to open a page per step and measure the terminal inside it, which
// is correct for a deck where every step is its own scene and wrong the moment
// two slides are two halves of the same shot: the box came back a pixel or two
// different each time -- the same recording, a fresh layout pass -- so the pad
// and the scale differed, and the join between the two films showed every glyph
// doubled a few pixels sideways. Measured once, every frame of every film is on
// the same grid. It is also the whole megabyte-parsing cost paid once instead of
// thirty-four times.
const page = await browser.newPage({ viewport: { width: WIDTH, height: 1200 } })
await page.goto(base, { waitUntil: 'networkidle' })
// Wait for the recording's own geometry, not for a clock. The cast is
// megabytes and the player shows a default 80x24 until it has parsed the
// header; measuring during that window gives the box of a terminal half the
// size, and every frame afterwards is a 44-row terminal sitting in it with
// the remainder left over. A fixed timeout was doing exactly that.
// Seeking is what makes the player parse the recording and adopt its size,
// so it comes first and the wait is for the result of it.
await page.waitForFunction(() => !!window.ap, null, { timeout: 60000 })
await page.evaluate(async () => { await window.ap.seek(0); await window.ap.pause() })
await page.waitForFunction(
  n => document.querySelectorAll('.ap-line').length === n, ROWS, { timeout: 60000 })
await page.waitForTimeout(500)
// Clipped to the terminal, not to the player. .ap-player is taller than the
// rows it draws -- the hidden control bar still has its space -- and the page
// behind it is dark, so a frame the height of the player carries a black band
// under the last line. It is not padding and no amount of recolouring the pad
// reaches it: it is page showing through. The terminal's own box is exactly
// what was recorded.
const box = await page.evaluate(() => {
  const r = document.querySelector('.ap-term').getBoundingClientRect()
  return { x: Math.floor(r.x), y: Math.floor(r.y),
           width: Math.round(r.width), height: Math.round(r.height) }
})
box.width -= box.width % 2                     // yuv420p refuses odd dimensions
box.height -= box.height % 2
const H = box.height
// The terminal is usually taller than the window it was measured in, and a
// row below the fold is a row Chromium has not laid out. Give the window the
// terminal's height before asking for any of it.
await page.setViewportSize({ width: WIDTH, height: box.y + H })
await page.waitForTimeout(500)
const cdp = await page.context().newCDPSession(page)

// Padded to the slide's shape. The recording is 167x44 characters, which comes
// out near 3:2, and a slide is 16:9; played at its own proportions it sits in
// the middle of the slide with the template showing around it, which is the
// one place the template and the terminal fight. The bars are the terminal's
// own background colour out of the cast header, so the film simply fills the
// slide. Padding rather than cropping: every column of the stage stays.
const padW = Math.round(H * 16 / 9 / 2) * 2

for (const c of steps) {
  const end = c.to ?? cuts.duration
  // Rate-limited to MAXFPS, keeping the LAST write of every burst rather than
  // the first. A repaint arrives as several writes a millisecond apart -- tmux
  // redraws a pane in pieces -- so the first of them is a half-drawn screen.
  // Keeping it was invisible while the next real frame was forty milliseconds
  // behind, and is not invisible at the end of a film: a slide that stops on the
  // first write of a burst holds a half-painted terminal for as long as the
  // presenter takes to press the clicker, and the slide after it opens on the
  // finished one. That was the whole of the flicker at a join.
  const times = []
  for (const t of marks) {
    if (t < c.from || t >= end) continue
    if (times.length && t - times[times.length - 1] < 1 / MAXFPS) times[times.length - 1] = t
    else times.push(t)
  }
  if (!times.length || times[0] > c.from) times.unshift(c.from)

  const work = `${OUT}/frames/${c.step}`
  fs.rmSync(work, { recursive: true, force: true })
  fs.mkdirSync(work, { recursive: true })

  for (let i = 0; i < times.length; i++) {
    await page.evaluate(async t => { await window.ap.seek(t); await window.ap.pause() }, times[i])
    const { data } = await cdp.send('Page.captureScreenshot',
      { format: 'jpeg', quality: 90, clip: { ...box, scale: 1 }, captureBeyondViewport: true })
    fs.writeFileSync(`${work}/f${String(i).padStart(5, '0')}.jpg`, Buffer.from(data, 'base64'))
  }

  const list = []
  for (let i = 0; i < times.length; i++) {
    list.push(`file 'f${String(i).padStart(5, '0')}.jpg'`)
    const next = i + 1 < times.length ? times[i + 1] : end
    list.push(`duration ${Math.max(0.01, (next - times[i]) * held(c)).toFixed(4)}`)
  }
  // The last frame twice, with a beat of its own. A slide of a cut step ends on
  // the frame the show was waiting on and then waits for the clicker, and a film
  // whose final frame has no duration is a film PowerPoint can decide is over
  // while the presenter is still talking over it.
  list.push(`file 'f${String(times.length - 1).padStart(5, '0')}.jpg'`)
  list.push('duration 0.5000')
  list.push(`file 'f${String(times.length - 1).padStart(5, '0')}.jpg'`)
  fs.writeFileSync(`${work}/list.txt`, list.join('\n'))

  // A progress bar burnt into the film, so the slide itself says how much of the
  // step is left. PowerPoint cannot report a video's position on the slide, and a
  // PowerPoint animation timed to match would drift the moment playback did.
  // In the film it cannot drift.
  //
  // A bar rather than a clock because this ffmpeg has no drawtext -- no
  // libfreetype -- and because a presenter reads a proportion faster than digits.
  // The ticks every thirty seconds are what make it absolute as well: count the
  // marks left of the end and you have the time.
  //
  // The bar belongs to the STEP, not to the slide. A step cut into four beats is
  // four films, and a bar that fills and empties four times says the recording
  // restarted, which is the one thing the join is supposed to hide. Each slide
  // draws only its own slice of the step's bar, so across the four of them it
  // travels once, left to right, and the ticks stay where they were.
  const BAR = 10
  const secs = end - c.from
  const stepFrom = c.step_from ?? c.from
  const stepSecs = (c.step_to ?? cuts.duration) - stepFrom
  const p0 = (c.from - stepFrom) / stepSecs
  const p1 = (end - stepFrom) / stepSecs
  // ffmpeg's `t` is the film's own clock, and a held step's film is longer than
  // the seconds it was recorded in. Measuring against the recorded length is how
  // step 0's bar used to reach the end less than half way through the slide.
  const runs = (secs * held(c)).toFixed(3)
  const bars = [
    `drawbox=x=0:y=ih-${BAR}:w=iw:h=${BAR}:color=0x000000@0.55:t=fill`,
    `drawbox=x=0:y=ih-${BAR}:w='iw*(${p0.toFixed(5)}+${(p1 - p0).toFixed(5)}*t/${runs})'`
      + `:h=${BAR}:color=0xE97132@0.95:t=fill`,
  ]
  for (let mark = 30; mark < stepSecs; mark += 30) {
    const at = (mark / stepSecs).toFixed(5)
    bars.push(`drawbox=x='iw*${at}':y=ih-${BAR}:w=3:h=${BAR}:color=0xFFFFFF@0.45:t=fill`)
  }

  const mp4 = `${OUT}/video/${c.step}.mp4`
  // Written for the machine at the venue, which is a Windows laptop until it is
  // proved otherwise:
  //
  //   scale + SAR     one shape for every film, 1920x1080, so nothing is left to
  //                   PowerPoint's own scaler and no slide has a hairline of
  //                   template down one side.
  //   format=yuv420p  JPEG frames are full-range, and the frames going in are
  //                   JPEG. Without this the stream comes out yuvj420p, which
  //                   Media Foundation renders with its own idea of black.
  //   high@4.1        the profile every PowerPoint since 2013 decodes in
  //                   hardware. High@5.0, which 2012x1132 was producing, is
  //                   inside the spec and outside what old laptops accelerate.
  //
  // Not a keyframe a second, which was the first attempt at making thirty-four
  // films start promptly on thirty-four slide changes. A keyframe of a full
  // screen of terminal text is a third of a megabyte and the deck came out at
  // 343MB, four times what one film per step cost. It bought nothing either:
  // PowerPoint starts each film at zero, which is a keyframe whatever the GOP
  // is, and no slide ever seeks.
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', `${work}/list.txt`,
    '-r', '30', '-vf', [`pad=${padW}:${H}:(ow-iw)/2:0:color=${bg}`, ...bars,
      'scale=1920:1080:flags=lanczos', 'setsar=1', 'format=yuv420p'].join(','),
    '-c:v', 'libx264', '-preset', 'slow', '-crf', CRF, '-tune', 'stillimage',
    '-profile:v', 'high', '-level', '4.1',
    '-pix_fmt', 'yuv420p', '-color_range', 'tv', '-movflags', '+faststart', mp4])
  // The poster is the film's FIRST frame, never one from the middle.
  //
  // PowerPoint paints the poster for the moment between the slide arriving and
  // the video starting itself, so the poster is what the room sees at the join.
  // A frame from the middle of the film means every slide opens on a picture
  // from its own future and then jumps backwards -- which is invisible on a
  // nine-slide deck where each film is a fresh scene, and is the whole problem
  // on a thirty-four-slide one where the film before it ended two frames ago.
  // Taken back out of the finished mp4, not out of the frame directory. The
  // frames are the terminal's own width; the film is that padded to 16:9 and
  // scaled to the slide. PowerPoint stretches the poster over the video's
  // rectangle either way, so a raw frame arrives on the slide wider than the
  // film that replaces it, and the terminal snaps narrower the instant playback
  // starts. Frame zero of the film is the only picture guaranteed to be the one
  // the film opens on, progress bar included.
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', '0', '-i', mp4,
    '-vframes', '1', '-q:v', '3', `${OUT}/covers/${c.step}.jpg`])
  fs.rmSync(work, { recursive: true, force: true })
  const mb = fs.statSync(mp4).size / 1048576
  const shown = Math.round(secs * held(c))
  const beat = c.beats > 1 ? `${c.beat}/${c.beats}` : '   '
  console.log(`  ${c.step.padEnd(7)} ${beat}  ${String(shown).padStart(3)}s  1920x1080`
    + `  ${times.length} frames  ${mb.toFixed(1)} MB`)
}
await page.close()
await browser.close()
srv.close()
