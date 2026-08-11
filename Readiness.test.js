const assert = require("node:assert/strict")
const R = require("./Readiness.js")

const cfg = { refreshIntervalSec: 60, retrySec: 5, faultAfterSec: 45 }

// Cold start, continuously failing: quiet inside the grace window, faulted at 45s.
let s = R.decide(R.initialState(), "failure", 0, cfg)
assert.equal(s.faulted, false)
assert.equal(s.nextDelayMs, 5000)          // retry cadence while in grace
s = R.decide(s, "failure", 44000, cfg)
assert.equal(s.faulted, false)
s = R.decide(s, "failure", 45000, cfg)
assert.equal(s.faulted, true)
assert.equal(s.nextDelayMs, 60000)         // steady cadence once faulted

// A success inside the window means it never faults, and resets the clock.
s = R.decide(R.initialState(), "failure", 0, cfg)
s = R.decide(s, "success", 15000, cfg)
assert.equal(s.faulted, false)
assert.equal(s.failingSince, null)
assert.equal(s.nextDelayMs, 60000)

// After a success, a new failure run gets a fresh 45s -- not an instant fault.
s = R.decide(s, "failure", 20000, cfg)
assert.equal(s.faulted, false)
s = R.decide(s, "failure", 64000, cfg)     // 44s of failing
assert.equal(s.faulted, false)
s = R.decide(s, "failure", 65000, cfg)     // 45s of failing
assert.equal(s.faulted, true)

// A success clears a fault.
s = R.decide(s, "success", 70000, cfg)
assert.equal(s.faulted, false)

// Never retry SLOWER than the steady cadence. nzbget polls every 2s while
// active, which is below retrySec.
const fast = { refreshIntervalSec: 2, retrySec: 5, faultAfterSec: 45 }
const f = R.decide(R.initialState(), "failure", 0, fast)
assert.equal(f.nextDelayMs, 2000)
assert.equal(f.faulted, false)

console.log("Readiness: all assertions passed")
