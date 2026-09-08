---
name: ios-simulator-lock
description: Coordinate the iOS Simulator as a finite shared resource so at most one device is booted, owned by exactly one agent. Use BEFORE booting a simulator, running `xcodebuild` / `xcodebuild test`, launching an app on a simulator, or doing any iOS QA on a machine that may be running other agents — several agents booting devices at once, or one shutting down a device another is testing against, breaks their runs. Provides the `simlock` CLI (acquire / release / heartbeat / status / doctor / steal / with).
compatibility: macOS with Xcode (`xcrun simctl`) and python3. State lives in `~/.agents/state/ios-simulator`, shared by every agent on the host.
---

# iOS Simulator lock

## The one-simulator rule

One machine often runs several agents at once — coding-agent sessions in
different checkouts, plus other agent tools. The iOS Simulator is a finite,
heavy resource: one device at a time is what the machine can actually carry.
Two failures follow from sharing it without a protocol:

- Booting several simulator devices at once exhausts the machine.
- One agent frees CPU with `xcrun simctl shutdown all` or `killall Simulator`
  and kills the device another agent is actively testing against; a third
  agent's `xcodebuild` then keeps running against a device shut out from under
  it.

So the rule is: **at most one simulator device is booted at a
time, it is owned by exactly one agent, and no agent ever disturbs another
agent's device or process.** `simlock` enforces this. Run it through
`scripts/simlock` (put it on your `PATH` or call it by full path).

## Normal QA run — prefer `with`

Wrap the whole simulator session in one command. `simlock with` acquires the
lock, exports the device UDID as `SIMLOCK_DEVICE`, runs your command, and
releases the lock on exit — including on crash or kill, via a shell trap. This
is the form to reach for by default.

```sh
simlock with --purpose "QA: chat scroll bug" -- ./my-qa-script.sh
# inside the command, boot / build / drive $SIMLOCK_DEVICE
```

If you must drive the steps by hand, bracket them:

```sh
UDID=$(simlock acquire --device "iPhone 17 Pro" --purpose "QA: onboarding") || exit 1
# ... boot $UDID, build, install, drive ...
simlock release
```

`acquire` prints the device UDID on stdout. When you use bare `acquire`,
export a stable owner token first so a later `release`/`heartbeat` from a
different shell is recognised as yours:

```sh
export SIMLOCK_LABEL="onboarding-qa"
```

## When the lock is held

`acquire` fails fast and prints who holds it, what for, and for how long.

- To wait for it: `simlock acquire --wait 600 ...` (blocks up to 600s).
- Otherwise: tell the user the simulator is busy and pick non-simulator work
  (unit-testable logic, code review, docs).
- **Never boot a second device to get around a held lock. Never steal from a
  live owner.** If you genuinely need resources another agent holds, ask the
  user — do not force it.

## Prohibitions (unmissable)

- **Never** run `xcrun simctl shutdown all`.
- **Never** run `killall Simulator`.
- **Never** kill another agent's `xcodebuild` / `xctest` process.
- **Never** shut down a device you did not boot.

`simlock release` shuts down only the one UDID recorded in the lock. `steal`
never shuts anything down. If you need a device or a process another agent
holds, ask the user.

## Long runs

The claim is valid for `--ttl` seconds without a heartbeat (default 1800). For
a longer manual run, either raise it (`--ttl 5400`) or send a heartbeat:

```sh
simlock heartbeat   # refreshes the claim
```

A `with` run needs no heartbeat: it stays owned for exactly as long as the
command runs, because the supervising `simlock` process is the owner.

## Crash recovery

A lock is **stale** when its owner is provably gone: the supervising process is
dead, or (for a bare `acquire`) no heartbeat has arrived within the TTL. Only a
stale lock may be broken:

```sh
simlock steal --force
```

`steal` **refuses** to break a live owner's lock (exit 6) and appends every
break to `~/.agents/state/ios-simulator/steal.log` for audit. After a steal the
previous device may still be booted — `steal` does not shut it down, because
you did not boot it. Inspect it with `doctor` and decide deliberately.

## When the simulator behaves oddly, run `doctor` first

```sh
simlock doctor
```

`doctor` is read-only. It reports the lock, every booted device, any booted
device **not** covered by the lock (an uncoordinated agent), any running
`xcodebuild`/`xctest` and the worktree it belongs to, and whether the lock is
stale. It never kills anything. Read its output before you touch anything.

## Command reference

| command | purpose | key exit codes |
| --- | --- | --- |
| `acquire` | take the lock; prints device UDID | 3 held-live, 4 stale, 7 wait-timeout |
| `release [--force]` | shut down the recorded device, drop the lock (idempotent) | 5 not owner |
| `heartbeat` | refresh the claim | 5 not owner |
| `status [--json]` | who holds it, purpose, age, device, alive? | 0 free, 3 held |
| `doctor` | read-only reality vs lock | 0 |
| `steal --force` | break a provably-dead lock | 6 owner live |
| `with … -- cmd` | acquire, run, release on exit (preferred) | passes cmd's code |

## iOS QA hygiene that affects the shared device

Repo-agnostic, and all three are about not wasting the one device:

- **Reuse one long-lived device; do not `simctl create` per session.** Only one
  agent runs a device at a time, so a fresh device per session buys nothing and
  costs disk and orphans. Pass the device you standardise on with
  `--device "<name or UDID>"` and drive `$SIMLOCK_DEVICE`.
- **Boot first, then test, one suite per invocation.** A whole-app test run can
  flake at test-runner launch ("test runner exited with code 0 before
  establishing connection", "Mach error -308 - server died"). Boot
  `$SIMLOCK_DEVICE`, then pass a single `-only-testing:<Target>/<Suite>` per
  `xcodebuild` invocation, rather than letting `xcodebuild` boot a device for
  the entire suite.
- **A hung run is not a slow run.** If the build log stops advancing for
  several minutes — commonly right after package resolution — the run is
  wedged, not working. Kill your own `xcodebuild`, run `simlock doctor`, then
  retry. Never kill an `xcodebuild` that `doctor` attributes to another agent.

Anything else is your repo's business, not this skill's: keep build flags,
scheme names, signing requirements and QA runbooks in that repo's own docs.
