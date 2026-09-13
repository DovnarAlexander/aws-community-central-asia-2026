<script setup>
// A recorded terminal, played from a local asciinema cast.
//
// The player and its stylesheet are vendored into slides/public/vendor/ rather
// than pulled from a CDN, because the one situation this component exists for
// is the venue network being down. A fallback that needs the internet is not a
// fallback.
//
// Casts are per segment, not one file for the whole show: if the cluster dies
// at step 2.2 the talk plays 2.2 and carries on, instead of switching to a
// thirty-minute video and starting from the titles.
import { onMounted, onBeforeUnmount, ref } from 'vue'

const props = defineProps({
  src:      { type: String, required: true },
  // The stage is built for a projector at roughly 120x36; matching it here
  // means the recording is not reflowed into a shape the demo never ran in.
  cols:     { type: Number, default: 120 },
  rows:     { type: Number, default: 36 },
  speed:    { type: Number, default: 1 },
  autoplay: { type: Boolean, default: false },
  startAt:  { type: [String, Number], default: 0 },
  poster:   { type: String, default: 'npt:0:03' },
})

const host = ref(null)
let player = null

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

onMounted(async () => {
  try {
    await loadPlayer()
  } catch (e) {
    host.value.textContent = String(e.message)
    return
  }
  player = window.AsciinemaPlayer.create(props.src, host.value, {
    cols: props.cols,
    rows: props.rows,
    speed: props.speed,
    autoPlay: props.autoplay,
    startAt: props.startAt || undefined,
    poster: props.poster,
    fit: 'width',
    // The show is mostly waiting -- a node being bought, a rollout settling.
    // Capping dead air keeps a recorded run watchable without cutting anything:
    // the countdowns redraw every second, so they are not idle and stay intact.
    idleTimeLimit: 2,
    controls: true,
    theme: 'asciinema',
  })
})

onBeforeUnmount(() => player?.dispose?.())
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
</style>
