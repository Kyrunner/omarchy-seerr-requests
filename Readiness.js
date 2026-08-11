// Decides when to poll, and when a failure is worth showing.
//
// Pure on purpose: no timers, no I/O, time is passed in. Readiness.qml is a
// thin shell around this so the logic can be tested with node, the way
// taildrop's Model.js is.
//
// The rule is uniform -- there is NO startup special case. A fault is shown
// only after faultAfterSec of CONTINUOUS failure, whenever that happens. At
// boot that keeps the widget quiet while the network comes up; mid-session it
// means a brief blip keeps showing last-known data instead of flashing an
// error banner across the bar.

function initialState() {
  return { failingSince: null, faulted: false, nextDelayMs: 0 }
}

function decide(state, event, nowMs, config) {
  var steadyMs = Math.max(1, config.refreshIntervalSec) * 1000
  var retryMs = Math.max(1, config.retrySec) * 1000
  var faultAfterMs = Math.max(0, config.faultAfterSec) * 1000

  if (event === "success") {
    return { failingSince: null, faulted: false, nextDelayMs: steadyMs }
  }

  var prior = state ? state.failingSince : null
  var failingSince = (prior === null || prior === undefined) ? nowMs : prior
  var faulted = (nowMs - failingSince) >= faultAfterMs

  // Never retry slower than the steady cadence: nzbget and navidrome can be
  // configured down to 2-3s, which is below retrySec.
  return {
    failingSince: failingSince,
    faulted: faulted,
    nextDelayMs: faulted ? steadyMs : Math.min(retryMs, steadyMs)
  }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { initialState: initialState, decide: decide }
}
