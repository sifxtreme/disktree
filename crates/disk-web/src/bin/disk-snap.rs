//! `disk-snap`: scan the home directory once, write one snapshot, exit.
//!
//! launchd runs it hourly. It is the only Guilty Spark process that should hold
//! Full Disk Access, which is why it is its own binary: no network, no
//! removal, no path arguments from anyone but its own plist. It writes one
//! SQLite file and a progress file beside it. The same shape as tccsnap —
//! the grant buys exactly "measure this tree", nothing else.
//!
//! Without the grant it still runs: the folders whose first touch raises a
//! consent dialog are listed but not opened, and the snapshot records that
//! it is partial. A dialog per folder, per hour, from a background agent, is
//! the failure this avoids.

#[path = "../store.rs"]
mod store;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, fs, thread};

use disktree_core::scan::{ScanHandle, ScanOptions};
use disktree_core::space::space_info;
use serde_json::json;

/// Opened on first touch, each of these asks the user. Relative to `$HOME`.
const CONSENT_FOLDERS: &[&str] = &[
    "Desktop",
    "Documents",
    "Downloads",
    "Pictures",
    "Movies",
    "Music",
    "Library/Mobile Documents",
    "Library/CloudStorage",
    "Library/Containers",
    "Library/Group Containers",
    "Library/Application Support/AddressBook",
    "Library/Calendars",
    "Library/Reminders",
];

/// Readable only with Full Disk Access, and denied silently without it (no
/// dialog), so they are safe to probe.
const FDA_PROBES: &[&str] = &["Library/Safari", "Library/Mail"];

fn main() {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let mut root = home.clone();
    let mut dir = store::default_dir();
    let mut args = env::args().skip(1);
    while let Some(flag) = args.next() {
        match (flag.as_str(), args.next()) {
            ("--root", Some(value)) => root = PathBuf::from(value),
            ("--dir", Some(value)) => dir = PathBuf::from(value),
            // Prints whether this process holds Full Disk Access, and
            // touches nothing that could raise a dialog.
            ("--probe", _) => {
                println!("full disk access: {}", full_disk_access(&home));
                return;
            }
            _ => {
                eprintln!("usage: disk-snap [--root DIR] [--dir STATE_DIR] | --probe");
                std::process::exit(2);
            }
        }
    }
    if let Err(error) = run(&root, &home, &dir) {
        eprintln!("disk-snap: {error}");
        std::process::exit(1);
    }
}

fn run(root: &Path, home: &Path, dir: &Path) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let root = root.canonicalize().map_err(|e| format!("{}: {e}", root.display()))?;
    let fda = full_disk_access(home);
    let excluded: Vec<PathBuf> = if fda {
        Vec::new()
    } else {
        CONSENT_FOLDERS.iter().map(|rel| home.join(rel)).collect()
    };
    let options = ScanOptions {
        exclude: excluded.clone(),
        // Snapshots never keep a file under ~1 MB by name (store.rs prunes far
        // above it), so the walk need not hold millions of them in memory.
        fold_below: Some(4 << 20),
        ..ScanOptions::default()
    };

    let started = Instant::now();
    let taken_at = now();
    let scan = ScanHandle::spawn(root.clone(), options);
    let progress_path = dir.join("snap.progress.json");
    let done = Arc::new(AtomicBool::new(false));
    // The web server shows a live count from this file, and reads a stale
    // one (no write for 10 s) as "not running", so a crash cannot leave
    // the UI claiming a scan forever.
    let reporter = {
        let progress = Arc::clone(&scan.progress);
        let done = Arc::clone(&done);
        let path = progress_path.clone();
        thread::spawn(move || {
            while !done.load(Ordering::Relaxed) {
                let p = progress.snapshot();
                let body = json!({
                    "startedAt": taken_at, "updatedAt": now(),
                    "files": p.files, "bytes": p.bytes, "dirs": p.dirs,
                });
                let tmp = path.with_extension("tmp");
                if fs::write(&tmp, body.to_string()).is_ok() {
                    let _ = fs::rename(&tmp, &path);
                }
                thread::sleep(Duration::from_secs(1));
            }
        })
    };
    let tree = loop {
        if let Some(outcome) = scan.poll() {
            break outcome;
        }
        thread::sleep(Duration::from_millis(200));
    };
    done.store(true, Ordering::Relaxed);
    let _ = reporter.join();
    let _ = fs::remove_file(&progress_path);
    let tree = tree.map_err(|e| format!("scan failed: {e}"))?;
    let errors = scan.progress.snapshot().errors;

    let space = space_info(&root).ok();
    let host = hostname();
    let mut db = store::open(&dir.join("disk.db"))
        .map_err(|e| format!("open db: {e}"))?;
    let id = store::write(
        &mut db,
        &store::Run {
            taken_at,
            host: &host,
            root: &root,
            tree: &tree,
            errors,
            scan_ms: started.elapsed().as_millis() as u64,
            vol_total: space.map(|s| s.total),
            vol_available: space.map(|s| s.available),
            full_disk_access: fda,
            excluded: &excluded,
        },
    )
    .map_err(|e| format!("write db: {e}"))?;
    eprintln!(
        "disk-snap: snapshot {id}: {} bytes, {} files, {:.1}s{}",
        tree.bytes,
        tree.files,
        started.elapsed().as_secs_f64(),
        if fda { "" } else { ", partial (no Full Disk Access)" }
    );
    Ok(())
}

fn full_disk_access(home: &Path) -> bool {
    FDA_PROBES
        .iter()
        .any(|rel| fs::read_dir(home.join(rel)).is_ok())
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|name| name.trim().to_string())
        .unwrap_or_default()
}
