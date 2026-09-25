//! `disk-mem`: sample this machine's memory once, write it, exit.
//!
//! launchd runs it every 5 minutes (com.asif.disk-mem). It replaces mem-guard:
//! the same pressure and swap checks, the same notification only on a change
//! of state, plus what mem-guard never kept — which owner held the memory,
//! sample by sample. See `mem.rs` for what is measured and why.
//!
//!   disk-mem [--dir DIR] [--notify]         take one sample
//!   disk-mem top [--dir DIR]                top memory owners now
//!   disk-mem owner NAME [--days N]          one owner over time
//!   disk-mem import-log FILE                mem-guard's log (once)
//!   disk-mem import-csv FILE                the interim sampler's CSV (once)

#[path = "../mem.rs"]
mod mem;
#[path = "../store.rs"]
mod store;

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use std::{env, fs};

use serde_json::Value;

const USAGE: &str = "usage: disk-mem [--dir DIR] [--notify]
       disk-mem top [--dir DIR]
       disk-mem owner NAME [--days N] [--dir DIR]
       disk-mem import-log FILE [--dir DIR]
       disk-mem import-csv FILE [--dir DIR]";

fn main() {
    let mut dir = store::default_dir();
    let mut notify = false;
    let mut days: i64 = 7;
    let mut words: Vec<String> = Vec::new();
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dir" => dir = args.next().map_or_else(|| usage(), PathBuf::from),
            "--days" => {
                days = args
                    .next()
                    .and_then(|d| d.parse().ok())
                    .unwrap_or_else(|| usage());
            }
            "--notify" => notify = true,
            "-h" | "--help" => usage(),
            _ => words.push(arg),
        }
    }
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let result = match words[..] {
        [] => take(&dir, notify),
        ["top"] => read(&dir, |db| mem::top(db).map(|v| print_top(&v))),
        ["owner", name] => read(&dir, |db| {
            mem::owner_series(db, name, now() - days * 86_400)
                .map(|v| print_owner(&v, days))
        }),
        ["import-log", file] => {
            import(&dir, file, |db, host, text| mem::import_log(db, host, text))
        }
        ["import-csv", file] => import(&dir, file, mem::import_csv),
        _ => usage(),
    };
    if let Err(error) = result {
        eprintln!("disk-mem: {error}");
        std::process::exit(1);
    }
}

fn usage() -> ! {
    eprintln!("{USAGE}");
    std::process::exit(2);
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

fn take(dir: &Path, notify: bool) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let sample = mem::sample(now())?;
    let mut db = mem::open(&mem::db_path(dir)).map_err(|e| e.to_string())?;
    mem::write(&mut db, &sample).map_err(|e| e.to_string())?;
    let s = &sample.system;
    let top: Vec<String> = sample
        .owners
        .iter()
        .take(3)
        .map(|o| format!("{} {:.0} MB", o.name, o.footprint_mb))
        .collect();
    println!(
        "pressure={} ({}) swap={} MB free={}% · {}",
        s.pressure_level,
        s.severity(),
        s.swap_used_mb,
        s.free_pct,
        top.join(", ")
    );
    if notify {
        alert_on_change(dir, s);
    }
    Ok(())
}

/// mem-guard's rule: notify only when the severity changes (into trouble, or
/// back to normal), so it never repeats itself.
fn alert_on_change(dir: &Path, s: &mem::System) {
    let state = dir.join("mem-state");
    let legacy = home().join(".local/share/mem-guard");
    let prev = fs::read_to_string(&state)
        .or_else(|_| fs::read_to_string(legacy.join("state")))
        .map_or_else(|_| "normal".to_string(), |t| t.trim().to_string());
    let sev = s.severity();
    if sev == prev {
        return;
    }
    let swap = s.swap_used_mb;
    match sev {
        "critical" => notify(
            dir,
            "🔴 Memory critical",
            &format!(
                "Kernel reports CRITICAL pressure. swap={swap}MB. Close something."
            ),
            "Basso",
        ),
        "warning" => notify(
            dir,
            "🟡 Memory pressure",
            &format!("Kernel reports memory WARNING. swap={swap}MB."),
            "Funk",
        ),
        _ => notify(
            dir,
            "🟢 Memory recovered",
            &format!("Pressure back to normal. swap={swap}MB."),
            "Glass",
        ),
    }
    if let Err(error) = fs::write(&state, format!("{sev}\n")) {
        eprintln!("disk-mem: {}: {error}", state.display());
    }
}

fn notify(dir: &Path, title: &str, message: &str, sound: &str) {
    let tn = Path::new("/opt/homebrew/bin/terminal-notifier");
    let icon = [
        dir.join("mem-icon.png"),
        home().join(".local/share/mem-guard/icon.png"),
    ]
    .into_iter()
    .find(|p| p.exists());
    let sent = if tn.exists() {
        let mut cmd = Command::new(tn);
        cmd.args([
            "-title",
            title,
            "-message",
            message,
            "-sound",
            sound,
            "-group",
            "mem-guard",
        ]);
        if let Some(icon) = &icon {
            cmd.arg("-appIcon").arg(icon);
        }
        cmd.output().is_ok_and(|o| o.status.success())
    } else {
        false
    };
    if !sent {
        let script = format!(
            "display notification {message:?} with title {title:?} sound name {sound:?}"
        );
        if let Err(error) = Command::new("/usr/bin/osascript")
            .args(["-e", &script])
            .output()
        {
            eprintln!("disk-mem: notify: {error}");
        }
    }
}

fn home() -> PathBuf {
    env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

fn read(
    dir: &Path,
    ask: impl FnOnce(&rusqlite::Connection) -> rusqlite::Result<String>,
) -> Result<(), String> {
    let db = mem::open_read(&mem::db_path(dir)).map_err(|e| e.to_string())?;
    print!("{}", ask(&db).map_err(|e| e.to_string())?);
    Ok(())
}

fn import(
    dir: &Path,
    file: &str,
    load: impl FnOnce(
        &mut rusqlite::Connection,
        &str,
        &str,
    ) -> rusqlite::Result<(usize, usize)>,
) -> Result<(), String> {
    let text = fs::read_to_string(file).map_err(|e| format!("{file}: {e}"))?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let mut db = mem::open(&mem::db_path(dir)).map_err(|e| e.to_string())?;
    let (read, added) =
        load(&mut db, &mem::hostname(), &text).map_err(|e| e.to_string())?;
    println!("{file}: {read} rows read, {added} added");
    Ok(())
}

fn mb(v: &Value) -> String {
    let mb = v.as_f64().unwrap_or(0.0);
    if mb >= 1024.0 {
        format!("{:.1} GB", mb / 1024.0)
    } else {
        format!("{mb:.0} MB")
    }
}

fn when(t: i64) -> String {
    Command::new("date")
        .args(["-r", &t.to_string(), "+%Y-%m-%d %H:%M"])
        .output()
        .map_or_else(
            |_| t.to_string(),
            |o| String::from_utf8_lossy(&o.stdout).trim().to_string(),
        )
}

/// Owners listed by `disk-mem top`; the rest are counted.
const SHOWN: usize = 30;

fn print_top(v: &Value) -> String {
    let mut out = String::new();
    let s = &v["system"];
    if s.is_null() {
        return "no samples yet\n".into();
    }
    let _ = writeln!(
        out,
        "{} at {}: pressure {} ({}), swap {} of {}, free {}%, compressor {}, load {}",
        s["host"].as_str().unwrap_or("?"),
        when(s["takenAt"].as_i64().unwrap_or(0)),
        s["pressureLevel"],
        s["severity"].as_str().unwrap_or("?"),
        mb(&s["swapUsedMb"]),
        mb(&s["swapTotalMb"]),
        s["freePct"],
        mb(&s["compressorMb"]),
        s["load1"],
    );
    let _ = writeln!(
        out,
        "\n{:<42} {:>6} {:>10} {:>11}  largest",
        "owner", "procs", "footprint", "compressed"
    );
    let owners: Vec<&Value> =
        v["owners"].as_array().into_iter().flatten().collect();
    for o in owners.iter().take(SHOWN) {
        let _ = writeln!(
            out,
            "{:<42} {:>6} {:>10} {:>11}  {} ({})",
            o["owner"].as_str().unwrap_or("?"),
            o["procs"],
            mb(&o["footprintMb"]),
            mb(&o["compressedMb"]),
            o["topName"].as_str().unwrap_or(""),
            o["topPid"],
        );
    }
    if owners.len() > SHOWN {
        let _ = writeln!(out, "… {} smaller owners", owners.len() - SHOWN);
    }
    let models = v["models"]
        .as_array()
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    if !models.is_empty() {
        let _ =
            writeln!(out, "\nollama models resident (wired, not pageable):");
        for m in models {
            let _ = writeln!(
                out,
                "  {:<32} {:>10}  until {}",
                m["name"].as_str().unwrap_or("?"),
                mb(&m["sizeMb"]),
                m["expiresAt"].as_str().unwrap_or("?"),
            );
        }
    }
    out
}

fn print_owner(v: &Value, days: i64) -> String {
    let mut out = String::new();
    let Some(owner) = v["owner"].as_str() else {
        let names: Vec<&str> = v["candidates"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        return if names.is_empty() {
            format!("no owner matches in the last {days} days\n")
        } else {
            format!(
                "several owners match; pick one:\n  {}\n",
                names.join("\n  ")
            )
        };
    };
    let points = v["points"].as_array().cloned().unwrap_or_default();
    let values: Vec<f64> = points
        .iter()
        .filter_map(|p| p["footprintMb"].as_f64())
        .collect();
    let (lo, hi) = values
        .iter()
        .fold((f64::MAX, 0.0_f64), |(lo, hi), &x| (lo.min(x), hi.max(x)));
    let _ = writeln!(
        out,
        "{owner}, last {days} days: {} samples, min {}, max {}",
        points.len(),
        mb(&Value::from(if values.is_empty() { 0.0 } else { lo })),
        mb(&Value::from(hi)),
    );
    // Every sample for a short series; past six hours of them, one line an
    // hour keeps a week readable.
    let hourly = points.len() > 72;
    let mut last_hour = i64::MIN;
    for p in &points {
        let t = p["t"].as_i64().unwrap_or(0);
        if hourly && t / 3600 == last_hour {
            continue;
        }
        last_hour = t / 3600;
        let _ = writeln!(
            out,
            "  {}  {:>10}  compressed {:>9}  procs {:>3}  {}",
            when(t),
            mb(&p["footprintMb"]),
            mb(&p["compressedMb"]),
            p["procs"],
            p["source"].as_str().unwrap_or(""),
        );
    }
    out
}
