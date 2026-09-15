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
import { onMounted, onBeforeUnmount, ref } from 'vue'
import { onSlideEnter, onSlideLeave } from '@slidev/client'

const props = defineProps({
  src:      { type: String, required: true },
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
  startAt:  { type: [String, Number], default: 0 },
  poster:   { type: String, default: 'npt:0:02' },
})

const host = ref(null)
let player = null
let wantsPlay = false
let watching = null

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
      link.href = '/vendor/asciinema-player.css'
      document.head.appendChild(link)
    }
    const s = document.createElement('script')
    s.src = '/vendor/asciinema-player.min.js'
    s.onload = () => resolve()
    s.onerror = () => reject(new Error('asciinema player missing from slides/public/vendor'))
    document.head.appendChild(s)
  })
}

function start() {
  if (!player) { wantsPlay = true; return }
  // Always from the top: a segment half-played from the last rehearsal is a
  // worse surprise on stage than one that starts over.
  player.seek(props.startAt || 0)
  player.play()
}

onMounted(async () => {
  try {
    await loadPlayer()
  } catch (e) {
    host.value.textContent = String(e.message)
    return
  }
  player = window.AsciinemaPlayer.create(props.src, host.value, {
    // undefined, not null: the player treats a present-but-empty option as a
    // size of zero rather than as "read it from the recording".
    cols: props.cols || undefined,
    rows: props.rows || undefined,
    speed: props.speed,
    autoPlay: false,
    startAt: props.startAt || undefined,
    poster: props.poster,
    fit: props.fit,
    // The show is mostly waiting -- a node being bought, a rollout settling.
    // Capping dead air keeps a recorded run watchable without cutting anything:
    // the countdowns redraw every second, so they are not idle and stay intact.
    idleTimeLimit: 2,
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
onSlideLeave(() => player?.pause?.())
onBeforeUnmount(() => {
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
