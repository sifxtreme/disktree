# Guilty Spark (work name: `disk`)

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
| core: `ScanOptions::exclude`, `TrashBackend::MacTrash` | `exclude` lists a directory without opening it. `MacTrash` uses `/usr/bin/trash`, so Put Back works in Finder. |

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
scp target/release/disk-{web,snap} packaging/macos/install.sh mac-server:/tmp/disk-install/
ssh mac-server 'DISK_LABEL=Forge sh /tmp/disk-install/install.sh remote <forge-tailscale-ip>:7321'
```

The UI is the Mac app: `apps/mac/build-app.sh` builds, signs and installs `~/Applications/Guilty Spark.app`. It is native SwiftUI over the same API, with a menu-bar readout of free space. The browser page at http://127.0.0.1:7321 still works (a phone, a machine without the app).

The app uses Cortana's `Theme` names and a verbatim copy of its generated tokens (`apps/mac/Sources/Tokens.swift`), so its views can move into Cortana's Mac client later.

## Safety

- The laptop server binds only to loopback. It refuses a `Host` header that is not loopback (DNS rebinding).
- Each POST must carry an `X-Disk` header, so another site's page cannot post to it without a CORS preflight, and nothing answers one.
- Forge binds only to its Tailscale IP and requires `X-Disk-Token` on every API call. The token file is 0600 on Forge, and a copy sits on the laptop.
- The core's guards decide what can be removed: nothing outside the root, not the root itself, not home, not mount points. Permanent delete needs a second confirmation. Trash is the default.
