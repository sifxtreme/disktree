# Guilty Spark (work name: `disk`)

> **Hard rule (Asif, 2026-09-24): Guilty Spark never deletes anything. It only suggests.** No
> endpoint, button, key or menu item may remove, trash or move a file. Suggestions offer Show in
> Finder and Copy Path; the delete happens outside the tool. The UI harness asks the server for
> `remove`, `plan`, `removal`, `delete` and `trash` and fails unless each is a 404.

This fork of [tobi/disktree](https://github.com/tobi/disktree) adds hourly disk snapshots on macOS and a
browser UI in Cortana's visual language. The UI shows every machine from one page. Today that is the
laptop and the Forge box (`mac-server`).

Upstream's crates (`disktree-core`, `disktree-app`) keep their names so upstream merges stay clean.
Our additions:

| Piece | What it does |
|---|---|
| `crates/disk-web/src/bin/disk-snap.rs` | Scans `$HOME` one time, writes one snapshot, then exits. launchd runs it every hour. It has no network and no delete. It is the **only** process that needs Full Disk Access. |
| `crates/disk-web/src/main.rs` | The UI and API. It reads the DB and never scans. It proxies peers under `/api/h/<id>/`, so the browser never sees a peer's token. |
| `crates/disk-web/src/store.rs` | The SQLite schema and the pruned-tree codec. |
| `apps/mac/` | The native Mac app (SwiftUI, Canvas treemap). It holds no grant. |
| `packaging/macos/{sign,install}.sh` | Signs both binaries, then installs the two agents. |
| core: `ScanOptions::exclude`, `ScanOptions::fold_below`, `classify::MARKER_FILES` | `exclude` lists a directory without opening it. `fold_below` sums small files and small directory subtrees into one leaf (snapper peak 923 MB → 146 MB, totals exact), never folding the files classification reads (`Cargo.toml`, `package.json`, `HEAD`). |

![The map: sections by kind of data, reclaimable space hatched, inspector with the selection, disk and 7 days of free space](assets/guilty-spark/map.png)

![Clean up: safe to clear, growing fast, big and untouched, came back; each row offers Show in Finder and Copy Path](assets/guilty-spark/cleanup.png)

## Using the app

- **Map:** click a folder to go in; Back/Forward (⌘[ ⌘], Esc), Enclosing Folder (⌘↑, ⌫), or any
  part of the path to come out. Right-click a tile for Open, Inspect, Show in Finder, Copy Path, and
  **Copy Delete Command**: a command for you to paste. It is the owner's cleanup for a known cache
  (`npm cache clean --force`, `uv cache clean`, …) and otherwise `trash '<path>'` (recoverable); `rm -rf`
  is a separate, labelled item. The app itself still never deletes.
  Colour by kind of data or by last write (Age). Hatching marks space that regenerates.
- **Clean up (⌘2):** four ranked lists, each item with the reason and size. Suggestions only.
- **Menu bar:** free space on every machine, and "Snapshot now".
- Launch arguments (for screenshots and tests, never keystrokes): `-page "Clean up"`,
  `-openPath <dir>`, `-appearance dark|light`, `-server <url>`.

## UI harness

`apps/mac/harness/run.sh` runs a second copy of the app that drives itself (`-harness YES`) through
launch, click in/back/forward/up, Age colours, Clean up, every peer machine, dark mode and window
sizes down to (and below) the minimum. It checks state after each step, asserts the server has no
delete endpoint, measures memory (budget 150 MB), and takes window-only screenshots. `DISK_APP=<binary>`
tests a build before installing. Bugs it found are listed in the commit history; the worst was an
intermittent crash on resize inside the system `.inspector` column, now a plain panel.

`apps/mac/build-app.sh` also installs `com.asif.disk-app`, a LaunchAgent that starts the app at login
and relaunches it after a crash (`KeepAlive` on unsuccessful exit, 10 s throttle), never after Quit.
Opened from the Dock, Spotlight or Finder, the app hands itself to that agent (`launchctl kickstart`) and exits,
so whichever way it starts, it comes back after a crash. Closing the window (⌘W) keeps it in the menu bar.
The menu panel counts crash reports from the last 7 days, so a relaunch loop stays visible.

## Verifying these claims

Every claim here has a command. A claim whose check has not been run reads UNVERIFIED, never ✅.

| Claim | Check | Last result |
|---|---|---|
| Nothing can delete | `cargo test -p disk-web no_route` (routes answer 404 for remove, plan, removal, delete, trash, move, cleanup; any method). The UI harness also asks the live server. | pass 2026-09-24. Shown to fail: with a fake `remove` route it failed ("POST remove answered 200"). |
| Totals are exact with folding | `cargo test -p disktree-core folding` | pass 2026-09-24, 3 tests |
| Folding keeps build output and `node_modules` recognisable | `cargo test -p disktree-core folding_keeps` | pass. Shown to fail without the fix. |
| Growing fast names the directory, not its parents; Came back finds refills only; history thins after 14 days | `cargo test -p disk-web store::` | pass 2026-09-24, 7 tests |
| The app works end to end, including resizing below the minimum | `apps/mac/harness/run.sh` (20+ checks, screenshots) | soak: 15/15 clean, no crash reports (2026-09-24); 18 in a row since the inspector fix, 9 of 9 crashed before it. 2026-09-25: 6/6 clean on the installed build, no new reports |
| The inspector change is what fixed the 2026-09-24 crash (`SplitViewChildController … didUpdateMinSize` → AppKit "more Update Constraints passes than views") | Harness against controls: `.inspector` restored; inspector and no `.windowResizability` clamp; the exact pre-fix commit b8ed325; b8ed325 during a live snapshot | UNVERIFIED. On 2026-09-25 **no build crashed**, including the pre-fix one (16 runs, 0 reports). Yesterday's crash depended on something not reproduced (load, swap at 7 GB, display setup). Both guards stay; relaunch-on-crash covers the rest |
| The app comes back after a crash, and stays quit after Quit | `kill -ABRT <pid>`, wait 40 s, `pgrep`; then Quit and wait 40 s | pass 2026-09-25: new pid after the abort (`runs = 2`); after Quit, `last exit code = 0` and no relaunch |
| Crashes are counted where you look | menu panel shows "Crashed N× in 7 days" from `~/Library/Logs/DiagnosticReports/GuiltySpark-*.ips` | code path run standalone 2026-09-25: 20, newest `…2026-09-25-121650.ips`. The panel itself: UNVERIFIED (not screenshotted) |
| The app stays under 150 MB | same harness | 76–79 MB in the soak. 2026-09-25: 3 of ~25 runs over budget (173–194 MB), all during or after a live snapshot |
| Snapper peak memory | `/usr/bin/time -l ~/.local/bin/disk-snap --dir /tmp/x` | 146 MB, 2.9M files, 19 s (2026-09-24) |
| Snapshots run hourly on both machines | `sqlite3 ~/Library/Application\ Support/disk/disk.db "select datetime(taken_at,'unixepoch','localtime') from snapshots"` | hourly since 16:32 (laptop) and 16:45 (Forge), 2026-09-24. One laptop run took 40 min at load 138; launchd skips an hour rather than overlap. |
| Full Disk Access survives rebuilds | `launchctl submit -l probe -- ~/.local/bin/disk-snap --probe` | true on both, after 4 rebuilds (2026-09-24) |
| Copy Delete Command addresses exactly the chosen path | harness step `delete command quoting` (a path with spaces, quotes, `$` and backticks round-trips through `/bin/sh`) | pass 2026-09-24 |
| Browser page works on desktop and phone, read-only | `PLAYWRIGHT=… node crates/disk-web/web-check.mjs` | 13/13 pass (2026-09-24) |
| Growing fast and Came back are useful on real data | the week check: `curl -s 127.0.0.1:7321/api/h/local/suggest` after 7 days of snapshots | UNVERIFIED (needs history until 2026-10-01) |
| Strict lints | `cargo clippy -p disk-web -p disktree-core --all-targets -- -D warnings` | 0 findings (2026-09-24). The upstream GPUI app was not built here (Linux only). |
| Clean up loads under heavy load | harness step `clean up` (suggestions within 45 s); `curl -w %{time_total} 127.0.0.1:7321/api/h/local/suggest` | FAILING 2026-09-25 at load 80–130: `/suggest` took 5–33 s, and the app's 30 s request timeout loses the slow ones. disk-web runs at Background priority. Open. |
| Memory owners are attributed right; imports are idempotent; thinning keeps one sample an hour | `cargo test -p disk-web mem::` | pass 2026-09-25, 8 tests |
| Memory is sampled on both machines | `disk-mem top` on each; `curl -s 127.0.0.1:7321/api/h/forge/mem` | 2026-09-25: laptop 100 owners (Claude Code 6.5 GB, Ollama 4.5 GB, Chrome 3.9 GB); Forge 71 owners, `pm2:forge-bot` 182 MB |
| mem-guard's history is in mem.db | `sqlite3 …/mem.db "select source,count(*) from mem_samples group by 1"` | 5,742 of 5,742 log lines imported; a re-import adds 0 (2026-09-25) |
| The Memory page loads and opens an owner's week | harness step `memory` (sample loads, ≥ 5 owners, largest first, the selected owner's series comes back) | pass 2026-09-25 (102 owners; Claude Code's series) |
| Alerts fire only on a change of severity | `disk-mem --dir <tmp> --notify` twice with `mem-state` = normal while the severity is warning | 2026-09-25: the first run moved the state to warning, and the second left it alone. The notification banner itself: UNVERIFIED (not seen) |

## Where the data is

`~/Library/Application Support/disk/disk.db` is on each machine. It is not synced (two writers on one
Syncthing file lose writes).

- `snapshots`: one row per run, kept forever. It holds volume free space, totals, the Full Disk Access state and what was skipped.
- `dirs`: each directory ≥ 100 MB, and every directory ≤ 2 levels deep, per run. Hourly rows stay for 14 days. After that, one run per day stays.
- `trees`: the pruned tree the treemap draws. Only the latest 2 are kept.

```
sqlite3 ~/Library/Application\ Support/disk/disk.db \
  "select datetime(taken_at,'unixepoch','localtime'), vol_available/1e9 from snapshots order by id desc limit 24"
```

## Memory (disk-mem, which replaced mem-guard)

`com.asif.disk-mem` runs `~/.local/bin/disk-mem` every 5 minutes on both machines and writes
`~/Library/Application Support/disk/mem.db`, which is not synced. It answers "what is eating memory,
and since when?" the way the snapshots do for disk. In the app it is the **Memory** page (⌘3):
severity, swap over 7 days, owners largest first (click one for its week) and resident Ollama models.

- **Per process: `phys_footprint`**, which is `top`'s MEM and what Activity Monitor shows. It is never
  `ps` RSS: RSS leaves out compressed memory and undercounted Node services 5–10x. `top`'s CMPRS is
  kept beside it. A large footprint that is mostly compressed belongs to a process the machine is paging.
- **Per owner.** A process belongs to the first match walking up its parents:
  1. a Claude Code session (`claude`);
  2. a pm2 app (`pm2:<name>`, on Forge);
  3. a launchd job (its label; an app's job is named by its `.app`);
  4. a direct child of launchd.
  Owners under 16 MB are summed into `(other)`, so the total still adds up.
- **Ollama models** are recorded from `127.0.0.1:11434/api/ps` each sample. They are Metal-wired and
  cannot be paged out.
- **System:** pressure level, severity, swap used/total, free %, compressor, wired and load, every sample.
- **Alerts (laptop only, `--notify`):** mem-guard's rule, unchanged. There is one notification per
  change of severity: kernel pressure 2 → warning, 4 → critical, and swap ≥ 3072 MB escalates normal to
  warning. The state is in `mem-state`. mem-guard's plist was moved to
  `~/.local/share/mem-guard/retired/`, and its log (from 2026-09-05) is imported as `source = 'mem-guard-log'`.
- Tables: `mem_samples` (kept forever), `mem_owners` and `mem_models` (every sample for 14 days, then
  one sample an hour).

```
disk-mem top                              # top memory owners now
disk-mem owner com.asif.hister --days 7   # one owner over time (a partial name works if it is unique)
curl -s 127.0.0.1:7321/api/h/local/mem    # same, as JSON; also /mem-owner?name=&days= and /mem-history?days=
curl -s 127.0.0.1:7321/api/h/forge/mem    # Forge, through the peer proxy
```

## Why a separate snapper (the tcc-snapshot pattern)

TCC gives a permission to the *responsible process*. A launchd agent is its own responsible process,
so it can hold its own grant. `tccsnap` itself cannot do this job: it copies a compiled-in list of
files. If it ran other binaries, its allowlist would stop meaning anything. So `disk-snap` copies the
pattern instead: its own agent, a narrow job, and one grant.

Both binaries are signed with the Apple Development identity. The designated requirement is then
"this identifier and this signer", so **a rebuild keeps the grant**. An ad-hoc signature is a hash,
so every build would lose the grant without any warning.

Without the grant, the snapper still runs. It lists Desktop, Documents, Downloads, Pictures, Movies,
Music, iCloud and app containers, but does not open them, and it records the snapshot as partial. The
UI then shows a banner that names the skipped folders. Opening one of those folders is what raises a
consent dialog, one per folder, every hour. The probe (`~/Library/Safari`, `~/Library/Mail`) is
denied silently, without a dialog.

## Grant Full Disk Access (one time, per machine)

System Settings → Privacy & Security → Full Disk Access → **+** → `~/.local/bin/disk-snap`.
On Forge, do this through Screen Sharing. To check the grant: `launchctl kickstart gui/$(id -u)/com.asif.disk-snap`,
then look at `~/Library/Logs/com.asif.disk-snap.log`. A run with the grant does **not** end in
"partial (no Full Disk Access)".

## Install / update

```
cargo build --release -p disk-web && sh packaging/macos/sign.sh
DISK_LABEL="This Mac" sh packaging/macos/install.sh local \
  "forge=http://<forge-tailscale-ip>:7321,Forge,$HOME/Library/Application Support/disk/forge.token"
scp target/release/disk-{web,snap,mem} packaging/macos/install.sh mac-server:/tmp/disk-install/
ssh mac-server 'DISK_LABEL=Forge sh /tmp/disk-install/install.sh remote <forge-tailscale-ip>:7321'
```

The UI is the Mac app: `apps/mac/build-app.sh` builds, signs and installs `~/Applications/Guilty Spark.app`. It is native SwiftUI over the same API, with a menu-bar readout of free space. The browser page at http://127.0.0.1:7321 still works (a phone, a machine without the app).

The app uses Cortana's `Theme` names and a verbatim copy of its generated tokens (`apps/mac/Sources/Tokens.swift`), so its views can move into Cortana's Mac client later.

## Safety

- The laptop server binds only to loopback. It refuses a `Host` header that is not loopback (DNS rebinding).
- Each POST must carry an `X-Disk` header, so another site's page cannot post to it without a CORS preflight, and nothing answers one.
- Forge binds only to its Tailscale IP and requires `X-Disk-Token` on every API call. The token file is 0600 on Forge, and a copy sits on the laptop.
- Nothing deletes. The server's only POST is `scan` (take a snapshot now); the harness fails if a delete endpoint appears.
