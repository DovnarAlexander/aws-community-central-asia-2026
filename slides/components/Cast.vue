<script setup>
// A recorded terminal, played from a local asciinema cast.
//
// The player and its stylesheet are vendored into slides/public/vendor/ rather
// than pulled from a CDN, because the one situation this component exists for
// is the venue network being down. A fallback that needs the internet is not a
// fallback.
//
// It starts itself when its slide comes up and stops when the slide goes away,
// so the whole deck is one button: the clicker advances the slide, the segment
// on it plays, the clicker advances again. Nothing on stage needs a mouse, and
// no press ever means two different things.
//
// One recording, played in ranges. The show is recorded in a single pass and
// each slide plays one step out of it -- `step="1.4"` rather than a file of its
// own. That is not filing preference, it is the only way the segment is right:
// a cast cut into its own file starts on a blank terminal, so the stage tmux
// drew before the cut -- pane borders, k9s, the load panel -- is simply absent
// until something happens to repaint it. Seeking into the whole recording makes
// the player replay the history to rebuild the screen, which costs single-digit
// milliseconds and puts the whole stage on the first frame.
import { onMounted, onBeforeUnmount, ref } from 'vue'
import { onSlideEnter, onSlideLeave } from '@slidev/client'

const props = defineProps({
  src:      { type: String, required: true },
  // A step id out of the cut manifest that `task deck:split` writes next to the
  // recording. The slide names the step, never a timecode: re-recording the
  // show and re-cutting it moves every boundary without a slide being touched.
  step:     { type: String, default: null },
  // Left unset the player takes the geometry out of the cast's own header, so
  // a recording plays back in the exact shape it ran in -- 120x36 from the
  // default `task deck:record`, or a whole screen from `GEOM=native`. Pinning
  // numbers here instead reflows the recording into a terminal it never ran
  // in, which is where the clipped right-hand pane came from. Pass them only
  // to deliberately replay a cast at a size other than its own.
  cols:     { type: Number, default: null },
  rows:     { type: Number, default: null },
  // 'width' fills the frame and lets height fall out of the row count -- right
  // for a cast in a fixed-width window on a slide. 'both' fits the recording
  // inside a box that has a height of its own, which is what the full-bleed
  // slide gives it.
  fit:      { type: String, default: 'width' },
  // Left unset the player uses the palette the recording carries -- asciinema
  // writes the terminal's own fg, bg and 16 colours into the cast header, so a
  // light terminal plays back light and the deck shows what was actually on
  // screen. Naming a theme here overrides all of that. Pass one only to
  // deliberately recolour a recording ('asciinema', 'solarized-dark', ...).
  theme:    { type: String, default: null },
  speed:    { type: Number, default: 1 },
  // Off only for a segment you want to talk over before starting it.
  autoplay: { type: Boolean, default: true },
  // Both are overridden by `step` when one is given.
  startAt:  { type: [String, Number], default: 0 },
  poster:   { type: String, default: 'npt:0:02' },
})

const host = ref(null)
let player = null
let wantsPlay = false
let watching = null
let ticker = null
// [from, to] for this slide's step; to is null for the last one, which runs to
// the end of the recording.
let range = null
// The dead-air cap. It has to be whatever the cut times were measured against,
// because idleTimeLimit shortens the player's clock away from the recording's:
// play with a different number and every cut points at the wrong minute. The
// manifest carries the one `task deck:split` used, so the two cannot drift.
let idleTimeLimit = 2

// ── where the files are ──────────────────────────────────────────────────────
// Everything this component reaches for is named at runtime -- a <script> it
// builds, a fetch, the cast path handed down as a prop -- so Vite never sees
// these URLs and never rewrites them against the build's base the way it does
// the <img> on a slide. Left with a leading slash they resolve against the
// host's root, which is right only while the deck happens to be served from
// one: from any subfolder the player 404s and the slide reads "asciinema
// player missing from slides/public/vendor" while the file sits in dist/vendor
// exactly as built. Same reason the deck routes by hash -- a build that serves
// from any folder has to mean its assets too, not just its slide URLs.
//
// BASE_URL is '/' under the dev server and './' out of `slidev build --base
// ./`; resolving it against document.baseURI turns either into the folder the
// deck is actually being served from.
function asset(path) {
  const base = new URL(import.meta.env.BASE_URL, document.baseURI)
  return new URL(String(path).replace(/^\/+/, ''), base).href
}

// ── the cut manifest ─────────────────────────────────────────────────────────
// Every cast slide in the deck asks for the same file, so the fetch is shared:
// one request per recording rather than one per slide.
const manifests = new Map()

function manifestUrl(src) {
  return asset(src.replace(/\.cast$/, '.cuts.json'))
}

function loadCuts(src) {
  const url = manifestUrl(src)
  if (!manifests.has(url)) {
    manifests.set(url, fetch(url).then(r => {
      if (!r.ok) throw new Error(`${url} ${r.status}`)
      return r.json()
    }))
  }
  return manifests.get(url)
}

// The player wants a poster as a media timestamp, and for a step that is its
// own start plus a couple of seconds -- far enough in that the frame shows the
// step rather than the repaint that opens it.
function npt(seconds) {
  const s = Math.max(0, Math.round(seconds))
  const m = Math.floor(s / 60)
  return `npt:${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`
}

// ── the letterbox colour ─────────────────────────────────────────────────────
// The player keeps the recording's aspect ratio, so a slide that hands it the
// whole canvas has bars left over beside it. They have to be the terminal's own
// background rather than a fixed black, or a recording from a light terminal
// sits in a dark frame. The colour is not knowable from here -- it comes out of
// the cast header -- but the player writes it as an inline custom property on
// .ap-player once the recording is parsed, so this reads it back and hands it
// up to the slide, which paints the bars with it.
//
// Parsed, not created: at the end of onMounted the fetch has not landed yet and
// there is nothing to read, so the first look usually misses and the observer
// below is what actually catches it.
function syncBackground() {
  const el = host.value?.querySelector('.ap-player')
  // The inline value, not the computed one: the player carries a theme class
  // from the moment it is created, so getComputedStyle answers with that
  // theme's dark background straight away and the bars get painted with a
  // colour the terminal never used. The inline property is empty until the
  // recording's own palette arrives, and empty is the honest answer here --
  // a cast with no theme in its header really is played in the default theme,
  // which is what the CSS fallback already is.
  const bg = el && el.style.getPropertyValue('--term-color-background').trim()
  if (!bg) return false
  host.value.closest('.slidev-layout')?.style.setProperty('--nq-cast-bg', bg)
  return true
}

function watchBackground() {
  if (!host.value) return
  watching = new MutationObserver(() => {
    if (syncBackground()) { watching.disconnect(); watching = null }
  })
  watching.observe(host.value, { subtree: true, childList: true, attributeFilter: ['style'] })
}

function loadPlayer() {
  return new Promise((resolve, reject) => {
    if (window.AsciinemaPlayer) return resolve()
    if (!document.getElementById('asciinema-css')) {
      const link = document.createElement('link')
      link.id = 'asciinema-css'
      link.rel = 'stylesheet'
      link.href = asset('/vendor/asciinema-player.css')
      document.head.appendChild(link)
    }
    const s = document.createElement('script')
    s.src = asset('/vendor/asciinema-player.min.js')
    s.onload = () => resolve()
    s.onerror = () => reject(new Error('asciinema player missing from slides/public/vendor'))
    document.head.appendChild(s)
  })
}

// ── playing one step ─────────────────────────────────────────────────────────
// Nothing in the player stops at a time, so the end of a step is watched for
// rather than scheduled: a wall-clock timer would drift against `speed` and
// against every pause the presenter takes mid-segment.
function stopWatching() {
  if (ticker) { clearInterval(ticker); ticker = null }
}

function stopAtEndOfStep() {
  stopWatching()
  const end = range?.[1]
  if (end == null) return
  ticker = setInterval(() => {
    if (!player) return stopWatching()
    Promise.resolve(player.getCurrentTime()).then(t => {
      if (t >= end) { stopWatching(); player?.pause?.() }
    })
  }, 100)
}

function start() {
  if (!player) { wantsPlay = true; return }
  // Always from the top of the step: a segment half-played from the last
  // rehearsal is a worse surprise on stage than one that starts over.
  const from = range ? range[0] : (Number(props.startAt) || 0)
  Promise.resolve(player.seek(from)).then(() => {
    player?.play?.()
    stopAtEndOfStep()
  })
}

onMounted(async () => {
  try {
    await loadPlayer()
  } catch (e) {
    host.value.textContent = String(e.message)
    return
  }

  if (props.step) {
    try {
      const cuts = await loadCuts(props.src)
      const cut = (cuts.cuts || []).find(c => c.step === props.step)
      if (cut) {
        range = [cut.from, cut.to ?? null]
        if (typeof cuts.idle_time_limit === 'number') idleTimeLimit = cuts.idle_time_limit
      } else {
        host.value.textContent = `no step ${props.step} in ${manifestUrl(props.src)} -- run task deck:split`
      }
    } catch (e) {
      // Not fatal: without the manifest the slide plays the whole recording,
      // which is wrong but watchable, and says why in the console. A deck that
      // refuses to show anything is worse on stage than one showing too much.
      console.warn(`[Cast] ${e.message} -- playing the whole recording`)
    }
  }
  if (host.value.textContent) return

  player = window.AsciinemaPlayer.create(asset(props.src), host.value, {
    // undefined, not null: the player treats a present-but-empty option as a
    // size of zero rather than as "read it from the recording".
    cols: props.cols || undefined,
    rows: props.rows || undefined,
    speed: props.speed,
    autoPlay: false,
    startAt: range ? range[0] : (Number(props.startAt) || undefined),
    poster: range ? npt(range[0] + 2) : props.poster,
    fit: props.fit,
    // The show is mostly waiting -- a node being bought, a rollout settling.
    // Capping dead air keeps a recorded run watchable without cutting anything:
    // the countdowns redraw every second, so they are not idle and stay intact.
    // With a step, this is the manifest's value rather than a local one; see
    // the declaration above for why they must agree.
    idleTimeLimit,
    // Left on deliberately. Autoplay covers the rehearsed path; the controls are
    // what you reach for when a question sends you back to the middle of a run.
    controls: true,
    // undefined, not null: a present-but-empty theme is not the same as "use
    // the one in the recording".
    theme: props.theme || undefined,
  })
  if (!syncBackground()) watchBackground()
  if (wantsPlay || props.autoplay) start()
})

onSlideEnter(() => { if (props.autoplay) start() })
onSlideLeave(() => { stopWatching(); player?.pause?.() })
onBeforeUnmount(() => {
  stopWatching()
  watching?.disconnect()
  player?.dispose?.()
})
</script>

<template>
  <div ref="host" class="nq-cast" />
</template>

<style>
/* The player ships its own black; this keeps the corners consistent with the
   window frame it sits inside. */
.nq-cast .ap-player {
  border-radius: 0 0 6px 6px;
}

/* fit: 'both' measures the container, so on a full-bleed slide the host has to
   actually have a height -- otherwise the player reads zero and falls back to
   fitting width, which is the shape that overflows the canvas. */
.nq-cast {
  width: 100%;
  height: 100%;
}
</style>
