// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/qpbx"
import topbar from "../vendor/topbar"

// Idle warning: the server ends a session after data-idle-ms without activity. User input on
// the page counts as activity and is reported at most once a minute ("keepalive"), so the
// server and this timer agree. The warning shows two minutes before the end.
const IdleWarning = {
  mounted() {
    this.idleMs = parseInt(this.el.dataset.idleMs, 10)
    this.lastPing = Date.now()
    this.onActivity = () => {
      this.reset()
      if (Date.now() - this.lastPing > 60000) this.ping()
    }
    for (const ev of ["keydown", "pointerdown", "input"]) window.addEventListener(ev, this.onActivity, {passive: true})
    this.el.querySelector("[data-keepalive]").addEventListener("click", () => { this.ping(); this.reset() })
    this.reset()
  },
  ping() {
    this.lastPing = Date.now()
    this.pushEvent("keepalive", {})
  },
  reset() {
    this.el.classList.add("hidden")
    clearTimeout(this.warnTimer)
    this.warnTimer = setTimeout(() => this.el.classList.remove("hidden"), Math.max(this.idleMs - 120000, 0))
  },
  destroyed() {
    for (const ev of ["keydown", "pointerdown", "input"]) window.removeEventListener(ev, this.onActivity)
    clearTimeout(this.warnTimer)
  },
}

// Built-in proof of work (ALTCHA format) on the login and setup forms: on submit, find the
// number whose SHA-256 with the salt equals the server's challenge, then submit for real.
async function solvePow(c) {
  const enc = new TextEncoder()
  for (let n = 0; n <= c.maxnumber; n++) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(c.salt + n)))
    let hex = ""
    for (const b of digest) hex += b.toString(16).padStart(2, "0")
    if (hex === c.challenge) return n
  }
  return null
}

document.addEventListener("submit", async (e) => {
  const field = e.target.querySelector("input[data-pow-challenge]")
  if (!field || field.value) return
  e.preventDefault()
  const form = e.target
  form.querySelectorAll("button").forEach((b) => (b.disabled = true))
  const c = JSON.parse(field.dataset.powChallenge)
  const number = await solvePow(c)
  field.value = btoa(JSON.stringify({algorithm: c.algorithm, challenge: c.challenge, number, salt: c.salt, signature: c.signature}))
  form.submit()
}, true)

// Captcha.eu: its SDK adds the captcha_at_solution field and holds the submit until solved.
window.addEventListener("load", () => {
  document.querySelectorAll("[data-captcha-eu-key]").forEach((el) => {
    if (!window.KROT) return
    window.KROT.setup(el.dataset.captchaEuKey)
    window.KROT.interceptForm(document.getElementById(el.dataset.captchaEuForm))
  })
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, IdleWarning},
})

// Show progress bar on live navigation and form submits
// The sidebar link for the current page: the longest link the path starts with ("/app" and
// "/platform", the home pages, only on an exact match).
const markNav = () => {
  const path = location.pathname
  let best = null
  for (const a of document.querySelectorAll("#side-nav a")) {
    a.removeAttribute("aria-current")
    const href = a.getAttribute("href")
    const hit = a.hasAttribute("data-exact") ? path === href : path === href || path.startsWith(href + "/")
    if (hit && (!best || href.length > best.getAttribute("href").length)) best = a
  }
  if (best) best.setAttribute("aria-current", "page")
}

topbar.config({barColors: {0: "#3cc4ea", 1: "#f5a524"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => { topbar.hide(); markNav() })
document.addEventListener("DOMContentLoaded", markNav)

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

