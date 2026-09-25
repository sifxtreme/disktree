#![allow(dead_code, reason = "shared by disk-web and disk-mem; each uses part")]
//! Memory over time: one SQLite file, written by `disk-mem` every 5 minutes,
//! read by `disk-web` and the `disk-mem` CLI.
//!
//! The disk store answers "what is eating the disk, and since when?"; this
//! one answers the same for memory. Three tables:
//!
//! * `mem_samples` — one row per sample, kept forever: pressure, swap, free %,
//!   compressor, load. Also the history imported from mem-guard's log.
//! * `mem_owners` — per sample, memory summed by owner (below). Every sample
//!   for [`FINE_DAYS`], then the first sample of each hour.
//! * `mem_models` — Ollama models resident at the sample. Metal-wired model
//!   memory cannot be paged out, and it moves the most at once.
//!
//! Measurement: per-process memory is `top`'s MEM, which is `phys_footprint`
//! (what Activity Monitor shows), never `ps` RSS: RSS leaves out compressed
//! memory and undercounted Node services 5-10x. `top`'s CMPRS (compressed,
//! possibly swapped out) is kept beside it; a large footprint with most of it
//! compressed is a process the machine is paging.
//!
//! Owner: a process belongs to the first of these found walking up its
//! parents — a Claude Code session (`claude`), a pm2 app, a launchd job (an
//! app's job is named by its `.app`), or the direct child of launchd.
//!
//! The file lives beside disk.db in `~/Library/Application Support/disk/`,
//! never in a synced directory: two writers on one synced SQLite file lose
//! writes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde_json::{Value, json};

/// Owners smaller than this are summed into one `(other)` row.
pub const OWNER_FLOOR_MB: f64 = 16.0;
/// Every sample's owners are kept this long, then one sample per hour.
pub const FINE_DAYS: i64 = 14;
/// Swap above this escalates normal to warning (mem-guard's threshold).
pub const SWAP_ALERT_MB: i64 = 3072;
pub const SOURCE: &str = "disk-mem";

pub fn db_path(dir: &Path) -> PathBuf {
    dir.join("mem.db")
}

pub fn open(path: &Path) -> rusqlite::Result<Connection> {
    let db = Connection::open(path)?;
    db.pragma_update(None, "journal_mode", "WAL")?;
    db.busy_timeout(Duration::from_secs(10))?;
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS mem_samples (
            id INTEGER PRIMARY KEY,
            taken_at INTEGER NOT NULL,
            host TEXT NOT NULL,
            source TEXT NOT NULL,
            pressure_level INTEGER,
            severity TEXT,
            mem_total_mb INTEGER,
            free_pct INTEGER,
            swap_used_mb INTEGER,
            swap_total_mb INTEGER,
            compressor_mb INTEGER,
            wired_mb INTEGER,
            load1 REAL,
            UNIQUE (host, source, taken_at)
        );
        CREATE INDEX IF NOT EXISTS mem_samples_taken ON mem_samples(taken_at);
        CREATE TABLE IF NOT EXISTS mem_owners (
            sample_id INTEGER NOT NULL REFERENCES mem_samples(id),
            owner TEXT NOT NULL,
            kind TEXT NOT NULL,
            procs INTEGER NOT NULL,
            footprint_mb REAL NOT NULL,
            compressed_mb REAL NOT NULL,
            top_pid INTEGER,
            top_name TEXT,
            PRIMARY KEY (sample_id, owner)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS mem_owners_owner ON mem_owners(owner, sample_id);
        CREATE TABLE IF NOT EXISTS mem_models (
            sample_id INTEGER NOT NULL REFERENCES mem_samples(id),
            name TEXT NOT NULL,
            size_mb REAL NOT NULL,
            vram_mb REAL NOT NULL,
            expires_at TEXT,
            PRIMARY KEY (sample_id, name)
        ) WITHOUT ROWID;",
    )?;
    Ok(db)
}

pub fn open_read(path: &Path) -> rusqlite::Result<Connection> {
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(Duration::from_secs(5))?;
    Ok(db)
}

// MARK: - one sample

#[derive(Debug, Default, Clone, PartialEq)]
pub struct System {
    pub pressure_level: i64,
    pub mem_total_mb: i64,
    pub free_pct: i64,
    pub swap_used_mb: i64,
    pub swap_total_mb: i64,
    pub compressor_mb: i64,
    pub wired_mb: i64,
    pub load1: f64,
}

impl System {
    /// mem-guard's verdict: the kernel's pressure level, with swap over
    /// [`SWAP_ALERT_MB`] escalating normal to warning.
    pub const fn severity(&self) -> &'static str {
        match self.pressure_level {
            4 => "critical",
            2 => "warning",
            _ if self.swap_used_mb >= SWAP_ALERT_MB => "warning",
            _ => "normal",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Proc {
    pub pid: i64,
    pub ppid: i64,
    pub comm: String,
    pub mb: f64,
    pub cmprs_mb: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Owner {
    pub name: String,
    pub kind: &'static str,
    pub procs: i64,
    pub footprint_mb: f64,
    pub compressed_mb: f64,
    pub top_pid: i64,
    pub top_name: String,
    top_mb: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Model {
    pub name: String,
    pub size_mb: f64,
    pub vram_mb: f64,
    pub expires_at: Option<String>,
}

#[derive(Debug, Default)]
pub struct Sample {
    pub taken_at: i64,
    pub host: String,
    pub system: System,
    pub owners: Vec<Owner>,
    pub models: Vec<Model>,
}

fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{program} {}: {}", args.join(" "), out.status));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `4034M`, `7136K`, `0B`, `12G`, `1058M+` → megabytes.
pub fn parse_size(text: &str) -> Option<f64> {
    let text = text.trim_end_matches(['+', '-', '*']);
    let (number, unit) =
        text.split_at(text.find(|c: char| c.is_ascii_alphabetic())?);
    let value: f64 = number.parse().ok()?;
    Some(match unit {
        "B" => value / 1_048_576.0,
        "K" => value / 1024.0,
        "M" => value,
        "G" => value * 1024.0,
        "T" => value * 1_048_576.0,
        _ => return None,
    })
}

/// `top -l 1 -stats pid,mem,cmprs`: pid → (footprint, compressed), and the
/// `PhysMem:` line's wired and compressor sizes.
pub fn parse_top(text: &str) -> (HashMap<i64, (f64, f64)>, i64, i64) {
    let mut sizes = HashMap::new();
    let (mut wired, mut compressor) = (0, 0);
    let mut table = false;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("PhysMem:") {
            // "23G used (5073M wired, 8775M compressor), 136M unused."
            for part in rest.split([',', '(', ')']) {
                let mut words = part.split_whitespace();
                if let (Some(size), Some(what)) = (words.next(), words.next()) {
                    let mb = parse_size(size).unwrap_or(0.0) as i64;
                    match what {
                        "wired" => wired = mb,
                        "compressor" => compressor = mb,
                        _ => {}
                    }
                }
            }
        } else if line.trim_start().starts_with("PID") {
            table = true;
        } else if table {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if let [pid, mem, cmprs, ..] = cols[..]
                && let (Ok(pid), Some(mem), Some(cmprs)) =
                    (pid.parse(), parse_size(mem), parse_size(cmprs))
            {
                sizes.insert(pid, (mem, cmprs));
            }
        }
    }
    (sizes, wired, compressor)
}

/// `ps -axww -o pid=,ppid=,comm=` (comm last, so paths with spaces survive).
pub fn parse_ps(text: &str) -> Vec<(i64, i64, String)> {
    text.lines()
        .filter_map(|line| {
            let mut parts = line.trim_start().splitn(2, char::is_whitespace);
            let pid = parts.next()?.parse().ok()?;
            let rest = parts.next()?.trim_start();
            let mut parts = rest.splitn(2, char::is_whitespace);
            let ppid = parts.next()?.parse().ok()?;
            Some((pid, ppid, parts.next().unwrap_or("").trim().to_string()))
        })
        .collect()
}

/// `launchctl list`: running job pid → label.
pub fn parse_launchctl(text: &str) -> HashMap<i64, String> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let mut cols = line.split('\t');
            let pid = cols.next()?.parse().ok()?;
            let label = cols.nth(1)?;
            Some((pid, label.to_string()))
        })
        .collect()
}

/// `/Applications/Google Chrome.app/Contents/Frameworks/…/Helper.app/…` →
/// `Google Chrome` (the outermost bundle).
pub fn app_name(comm: &str) -> Option<String> {
    let end = comm
        .find(".app/")
        .or_else(|| comm.strip_suffix(".app").map(str::len))?;
    let start = comm[..end].rfind('/').map_or(0, |i| i + 1);
    Some(comm[start..end].to_string())
}

fn basename(comm: &str) -> &str {
    comm.rsplit('/').next().unwrap_or(comm)
}

/// Which owner a process belongs to; see the module comment.
fn owner_of(
    pid: i64,
    procs: &HashMap<i64, &Proc>,
    jobs: &HashMap<i64, String>,
    pm2: &HashMap<i64, String>,
) -> (String, &'static str) {
    let mut at = pid;
    for _ in 0..64 {
        let Some(p) = procs.get(&at) else { break };
        if basename(&p.comm) == "claude" {
            return ("Claude Code".into(), "claude");
        }
        if let Some(name) = pm2.get(&at) {
            return (format!("pm2:{name}"), "pm2");
        }
        if let Some(label) = jobs.get(&at) {
            return match label.strip_prefix("application.") {
                Some(bundle) => (
                    app_name(&p.comm).unwrap_or_else(|| bundle.to_string()),
                    "app",
                ),
                None => (label.clone(), "job"),
            };
        }
        if p.ppid <= 1 {
            return match app_name(&p.comm) {
                Some(app) => (app, "app"),
                None => (basename(&p.comm).to_string(), "system"),
            };
        }
        at = p.ppid;
    }
    let comm = procs.get(&pid).map_or("?", |p| p.comm.as_str());
    (basename(comm).to_string(), "system")
}

/// Sums processes by owner, largest first; owners under [`OWNER_FLOOR_MB`]
/// fold into one `(other)` row so the total still adds up.
pub fn attribute(
    procs: &[Proc],
    jobs: &HashMap<i64, String>,
    pm2: &HashMap<i64, String>,
) -> Vec<Owner> {
    let by_pid: HashMap<i64, &Proc> =
        procs.iter().map(|p| (p.pid, p)).collect();
    let mut owners: HashMap<String, Owner> = HashMap::new();
    for p in procs {
        let (name, kind) = owner_of(p.pid, &by_pid, jobs, pm2);
        let owner = owners.entry(name.clone()).or_insert_with(|| Owner {
            name,
            kind,
            procs: 0,
            footprint_mb: 0.0,
            compressed_mb: 0.0,
            top_pid: p.pid,
            top_name: String::new(),
            top_mb: -1.0,
        });
        owner.procs += 1;
        owner.footprint_mb += p.mb;
        owner.compressed_mb += p.cmprs_mb;
        if p.mb > owner.top_mb {
            owner.top_mb = p.mb;
            owner.top_pid = p.pid;
            owner.top_name = basename(&p.comm).to_string();
        }
    }
    let mut kept: Vec<Owner> = Vec::new();
    let mut other = Owner {
        name: "(other)".into(),
        kind: "other",
        procs: 0,
        footprint_mb: 0.0,
        compressed_mb: 0.0,
        top_pid: 0,
        top_name: String::new(),
        top_mb: -1.0,
    };
    for owner in owners.into_values() {
        if owner.footprint_mb >= OWNER_FLOOR_MB {
            kept.push(owner);
        } else {
            other.procs += owner.procs;
            other.footprint_mb += owner.footprint_mb;
            other.compressed_mb += owner.compressed_mb;
        }
    }
    if other.procs > 0 {
        kept.push(other);
    }
    kept.sort_by(|a, b| b.footprint_mb.total_cmp(&a.footprint_mb));
    kept
}

fn system(wired_mb: i64, compressor_mb: i64) -> Result<System, String> {
    let text = run(
        "sysctl",
        &[
            "-n",
            "kern.memorystatus_vm_pressure_level",
            "kern.memorystatus_level",
            "hw.memsize",
            "vm.swapusage",
            "vm.loadavg",
        ],
    )?;
    let lines: Vec<&str> = text.lines().collect();
    let [level, free, total, swap, load, ..] = lines[..] else {
        return Err(format!("sysctl: unexpected output {text:?}"));
    };
    // "total = 6144.00M  used = 4663.81M  free = 1480.19M  (encrypted)"
    let swap_field = |key: &str| {
        swap.split("  ")
            .find_map(|part| part.trim().strip_prefix(key))
            .and_then(parse_size)
            .unwrap_or(0.0) as i64
    };
    Ok(System {
        pressure_level: level.trim().parse().unwrap_or(1),
        mem_total_mb: total.trim().parse::<i64>().unwrap_or(0) / 1_048_576,
        free_pct: free.trim().parse().unwrap_or(0),
        swap_used_mb: swap_field("used = "),
        swap_total_mb: swap_field("total = "),
        compressor_mb,
        wired_mb,
        // "{ 36.46 88.07 99.59 }"
        load1: load
            .split_whitespace()
            .nth(1)
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.0),
    })
}

/// pm2 is a Node script; under launchd neither it nor `node` is on PATH.
fn find_pm2() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let mut candidates = vec![
        PathBuf::from("/opt/homebrew/bin/pm2"),
        PathBuf::from("/usr/local/bin/pm2"),
    ];
    if let Ok(versions) = std::fs::read_dir(home.join(".nvm/versions/node")) {
        let mut found: Vec<PathBuf> = versions
            .flatten()
            .map(|v| v.path().join("bin/pm2"))
            .collect();
        found.sort();
        candidates.extend(found.into_iter().rev());
    }
    candidates.into_iter().find(|p| p.exists())
}

/// pm2 app pid → name. Empty when pm2 is not installed or not running.
fn pm2_apps() -> HashMap<i64, String> {
    // Any pm2 command starts the pm2 daemon when none is running; a sampler
    // must not. The daemon writes this file while it is up.
    let running = std::env::var_os("HOME")
        .map(PathBuf::from)
        .is_some_and(|home| home.join(".pm2/pm2.pid").exists());
    let Some(pm2) = find_pm2().filter(|_| running) else {
        return HashMap::new();
    };
    let bin = pm2.parent().map(Path::to_path_buf).unwrap_or_default();
    let path = format!(
        "{}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        bin.display()
    );
    let Ok(out) = Command::new(&pm2).arg("jlist").env("PATH", path).output()
    else {
        return HashMap::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    // pm2 may print a banner before the JSON.
    let json = text.find('[').map_or("[]", |i| &text[i..]);
    serde_json::from_str::<Vec<Value>>(json)
        .unwrap_or_default()
        .iter()
        .filter_map(|app| {
            let pid = app.get("pid")?.as_i64().filter(|&p| p > 0)?;
            Some((pid, app.get("name")?.as_str()?.to_string()))
        })
        .collect()
}

/// Models Ollama holds right now. Empty when Ollama is not running.
fn ollama_models() -> Vec<Model> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(3))
        .build();
    let Ok(response) = agent.get("http://127.0.0.1:11434/api/ps").call() else {
        return Vec::new();
    };
    let Ok(body) =
        response
            .into_string()
            .map_err(|e| e.to_string())
            .and_then(|text| {
                serde_json::from_str::<Value>(&text).map_err(|e| e.to_string())
            })
    else {
        return Vec::new();
    };
    let mb = |v: Option<&Value>| {
        v.and_then(Value::as_f64).unwrap_or(0.0) / 1_048_576.0
    };
    body.get("models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter_map(|m| {
                    Some(Model {
                        name: m.get("name")?.as_str()?.to_string(),
                        size_mb: mb(m.get("size")),
                        vram_mb: mb(m.get("size_vram")),
                        expires_at: m
                            .get("expires_at")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn hostname() -> String {
    run("hostname", &["-s"])
        .map_or_else(|_| "unknown".into(), |h| h.trim().to_string())
}

/// Takes one sample of this machine.
pub fn sample(taken_at: i64) -> Result<Sample, String> {
    let top = run("top", &["-l", "1", "-stats", "pid,mem,cmprs"])?;
    let (sizes, wired, compressor) = parse_top(&top);
    if sizes.is_empty() {
        return Err("top: no process rows".into());
    }
    let procs: Vec<Proc> =
        parse_ps(&run("ps", &["-axww", "-o", "pid=,ppid=,comm="])?)
            .into_iter()
            .map(|(pid, ppid, comm)| {
                let (mb, cmprs_mb) =
                    sizes.get(&pid).copied().unwrap_or_default();
                Proc {
                    pid,
                    ppid,
                    comm,
                    mb,
                    cmprs_mb,
                }
            })
            .collect();
    let jobs =
        parse_launchctl(&run("launchctl", &["list"]).unwrap_or_default());
    Ok(Sample {
        taken_at,
        host: hostname(),
        system: system(wired, compressor)?,
        owners: attribute(&procs, &jobs, &pm2_apps()),
        models: ollama_models(),
    })
}

pub fn write(db: &mut Connection, sample: &Sample) -> rusqlite::Result<i64> {
    let s = &sample.system;
    let tx = db.transaction()?;
    tx.execute(
        "INSERT INTO mem_samples (taken_at, host, source, pressure_level,
            severity, mem_total_mb, free_pct, swap_used_mb, swap_total_mb,
            compressor_mb, wired_mb, load1)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            sample.taken_at,
            sample.host,
            SOURCE,
            s.pressure_level,
            s.severity(),
            s.mem_total_mb,
            s.free_pct,
            s.swap_used_mb,
            s.swap_total_mb,
            s.compressor_mb,
            s.wired_mb,
            s.load1,
        ],
    )?;
    let id = tx.last_insert_rowid();
    {
        let mut owner = tx.prepare(
            "INSERT INTO mem_owners (sample_id, owner, kind, procs,
                footprint_mb, compressed_mb, top_pid, top_name)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        )?;
        for o in &sample.owners {
            owner.execute(params![
                id,
                o.name,
                o.kind,
                o.procs,
                o.footprint_mb,
                o.compressed_mb,
                o.top_pid,
                o.top_name
            ])?;
        }
        let mut model = tx.prepare(
            "INSERT OR REPLACE INTO mem_models (sample_id, name, size_mb, vram_mb, expires_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
        )?;
        for m in &sample.models {
            model.execute(params![
                id,
                m.name,
                m.size_mb,
                m.vram_mb,
                m.expires_at
            ])?;
        }
    }
    thin(&tx, sample.taken_at)?;
    tx.commit()?;
    Ok(id)
}

/// Past [`FINE_DAYS`], keep owners and models for the first sample of each
/// hour only. Sample rows (a few dozen bytes) are kept forever.
fn thin(db: &Connection, now: i64) -> rusqlite::Result<()> {
    let cut = now - FINE_DAYS * 86_400;
    for table in ["mem_owners", "mem_models"] {
        db.execute(
            &format!(
                "DELETE FROM {table} WHERE sample_id IN (
                    SELECT id FROM mem_samples WHERE taken_at < ?1
                    AND id NOT IN (SELECT MIN(id) FROM mem_samples
                        WHERE taken_at < ?1 GROUP BY host, source, taken_at / 3600))"
            ),
            params![cut],
        )?;
    }
    Ok(())
}

// MARK: - imports

/// mem-guard's log: `2026-09-25 11:27:55 | pressure_level=1 (warning) | swap_used=3449MB`
/// (local time). Returns (lines read, rows added); re-importing adds nothing.
pub fn import_log(
    db: &Connection,
    host: &str,
    text: &str,
) -> rusqlite::Result<(usize, usize)> {
    let mut insert = db.prepare(
        "INSERT OR IGNORE INTO mem_samples (taken_at, host, source, pressure_level, severity, swap_used_mb)
         VALUES (CAST(strftime('%s', ?1, 'utc') AS INTEGER), ?2, 'mem-guard-log', ?3, ?4, ?5)",
    )?;
    let (mut read, mut added) = (0, 0);
    for line in text.lines() {
        let parts: Vec<&str> = line.split(" | ").collect();
        let [ts, pressure, swap] = parts[..] else {
            continue;
        };
        let Some(pressure) = pressure.strip_prefix("pressure_level=") else {
            continue;
        };
        let (level, severity) =
            pressure.split_once(' ').unwrap_or((pressure, ""));
        let severity = severity.trim_matches(['(', ')']);
        let Some(swap) = swap
            .strip_prefix("swap_used=")
            .and_then(|s| s.trim().strip_suffix("MB"))
            .and_then(|s| s.parse::<i64>().ok())
        else {
            continue;
        };
        read += 1;
        added += insert.execute(params![
            ts,
            host,
            level.parse::<i64>().ok(),
            severity,
            swap
        ])?;
    }
    Ok((read, added))
}

/// The interim sampler's CSV (2026-09-25):
/// `ts_iso,owner,pid,phys_footprint_mb,compressed_mb,swap_used_mb,pressure_level`.
pub fn import_csv(
    db: &mut Connection,
    host: &str,
    text: &str,
) -> rusqlite::Result<(usize, usize)> {
    let tx = db.transaction()?;
    let (mut read, mut added) = (0, 0);
    for line in text.lines().skip(1) {
        let cols: Vec<&str> = line.split(',').collect();
        let [ts, owner, pid, footprint, compressed, swap, level] = cols[..]
        else {
            continue;
        };
        let (Ok(footprint), Ok(compressed)) =
            (footprint.parse::<f64>(), compressed.parse::<f64>())
        else {
            continue;
        };
        read += 1;
        tx.execute(
            "INSERT OR IGNORE INTO mem_samples (taken_at, host, source, pressure_level, swap_used_mb)
             VALUES (CAST(strftime('%s', ?1) AS INTEGER), ?2, 'interim-csv', ?3, ?4)",
            params![ts, host, level.parse::<i64>().ok(), swap.parse::<i64>().ok()],
        )?;
        let id: i64 = tx.query_row(
            "SELECT id FROM mem_samples WHERE host = ?1 AND source = 'interim-csv'
             AND taken_at = CAST(strftime('%s', ?2) AS INTEGER)",
            params![host, ts],
            |r| r.get(0),
        )?;
        added += tx.execute(
            "INSERT OR IGNORE INTO mem_owners (sample_id, owner, kind, procs, footprint_mb, compressed_mb, top_pid)
             VALUES (?1, ?2, 'interim', 1, ?3, ?4, ?5)",
            params![id, owner, footprint, compressed, pid.parse::<i64>().ok()],
        )?;
    }
    tx.commit()?;
    Ok((read, added))
}

// MARK: - questions

/// "Top memory owners now": the latest sample, its owners and models.
pub fn top(db: &Connection) -> rusqlite::Result<Value> {
    let latest = db
        .query_row(
            "SELECT id, taken_at, host, pressure_level, severity, mem_total_mb,
                free_pct, swap_used_mb, swap_total_mb, compressor_mb, wired_mb, load1
             FROM mem_samples WHERE source = ?1 ORDER BY taken_at DESC LIMIT 1",
            params![SOURCE],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    json!({
                        "takenAt": r.get::<_, i64>(1)?,
                        "host": r.get::<_, String>(2)?,
                        "pressureLevel": r.get::<_, Option<i64>>(3)?,
                        "severity": r.get::<_, Option<String>>(4)?,
                        "memTotalMb": r.get::<_, Option<i64>>(5)?,
                        "freePct": r.get::<_, Option<i64>>(6)?,
                        "swapUsedMb": r.get::<_, Option<i64>>(7)?,
                        "swapTotalMb": r.get::<_, Option<i64>>(8)?,
                        "compressorMb": r.get::<_, Option<i64>>(9)?,
                        "wiredMb": r.get::<_, Option<i64>>(10)?,
                        "load1": r.get::<_, Option<f64>>(11)?,
                    }),
                ))
            },
        )
        .optional()?;
    let Some((id, system)) = latest else {
        return Ok(json!({"system": null, "owners": [], "models": []}));
    };
    let mut stmt = db.prepare(
        "SELECT owner, kind, procs, footprint_mb, compressed_mb, top_pid, top_name
         FROM mem_owners WHERE sample_id = ?1 ORDER BY footprint_mb DESC",
    )?;
    let owners = stmt
        .query_map(params![id], |r| {
            Ok(json!({
                "owner": r.get::<_, String>(0)?,
                "kind": r.get::<_, String>(1)?,
                "procs": r.get::<_, i64>(2)?,
                "footprintMb": r.get::<_, f64>(3)?,
                "compressedMb": r.get::<_, f64>(4)?,
                "topPid": r.get::<_, Option<i64>>(5)?,
                "topName": r.get::<_, Option<String>>(6)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut stmt = db.prepare(
        "SELECT name, size_mb, vram_mb, expires_at FROM mem_models
         WHERE sample_id = ?1 ORDER BY size_mb DESC",
    )?;
    let models = stmt
        .query_map(params![id], |r| {
            Ok(json!({
                "name": r.get::<_, String>(0)?,
                "sizeMb": r.get::<_, f64>(1)?,
                "vramMb": r.get::<_, f64>(2)?,
                "expiresAt": r.get::<_, Option<String>>(3)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"system": system, "owners": owners, "models": models}))
}

/// "Memory for owner X over the last N days". `name` matches an owner
/// exactly, or else a single owner containing it (case-insensitive); several
/// matches come back as `candidates` instead of a series.
pub fn owner_series(
    db: &Connection,
    name: &str,
    since: i64,
) -> rusqlite::Result<Value> {
    let mut stmt = db.prepare(
        "SELECT DISTINCT o.owner FROM mem_owners o JOIN mem_samples s ON s.id = o.sample_id
         WHERE s.taken_at >= ?1 AND (o.owner = ?2 OR o.owner LIKE '%' || ?2 || '%')",
    )?;
    let names = stmt
        .query_map(params![since, name], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let owner = if names.iter().any(|n| n == name) {
        name.to_string()
    } else if let [only] = &names[..] {
        only.clone()
    } else {
        return Ok(json!({"owner": null, "candidates": names, "points": []}));
    };
    let mut stmt = db.prepare(
        "SELECT s.taken_at, s.source, o.procs, o.footprint_mb, o.compressed_mb, o.top_pid
         FROM mem_owners o JOIN mem_samples s ON s.id = o.sample_id
         WHERE o.owner = ?1 AND s.taken_at >= ?2 ORDER BY s.taken_at",
    )?;
    let points = stmt
        .query_map(params![owner, since], |r| {
            Ok(json!({
                "t": r.get::<_, i64>(0)?,
                "source": r.get::<_, String>(1)?,
                "procs": r.get::<_, i64>(2)?,
                "footprintMb": r.get::<_, f64>(3)?,
                "compressedMb": r.get::<_, f64>(4)?,
                "topPid": r.get::<_, Option<i64>>(5)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"owner": owner, "candidates": names, "points": points}))
}

/// Pressure and swap over time, including the imported mem-guard history.
pub fn system_series(db: &Connection, since: i64) -> rusqlite::Result<Value> {
    let mut stmt = db.prepare(
        "SELECT taken_at, source, pressure_level, severity, swap_used_mb, free_pct, compressor_mb, load1
         FROM mem_samples WHERE taken_at >= ?1 AND source != 'interim-csv' ORDER BY taken_at",
    )?;
    let points = stmt
        .query_map(params![since], |r| {
            Ok(json!({
                "t": r.get::<_, i64>(0)?,
                "source": r.get::<_, String>(1)?,
                "pressureLevel": r.get::<_, Option<i64>>(2)?,
                "severity": r.get::<_, Option<String>>(3)?,
                "swapUsedMb": r.get::<_, Option<i64>>(4)?,
                "freePct": r.get::<_, Option<i64>>(5)?,
                "compressorMb": r.get::<_, Option<i64>>(6)?,
                "load1": r.get::<_, Option<f64>>(7)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"points": points}))
}

#[cfg(test)]
#[allow(
    clippy::float_cmp,
    reason = "the sums compared are of exact small values"
)]
mod tests {
    use super::*;

    fn proc(pid: i64, ppid: i64, comm: &str, mb: f64) -> Proc {
        Proc {
            pid,
            ppid,
            comm: comm.into(),
            mb,
            cmprs_mb: mb / 2.0,
        }
    }

    #[test]
    fn sizes_parse_in_every_unit() {
        assert_eq!(parse_size("4034M"), Some(4034.0));
        assert_eq!(parse_size("1058M+"), Some(1058.0));
        assert_eq!(parse_size("2G"), Some(2048.0));
        assert_eq!(parse_size("512K"), Some(0.5));
        assert_eq!(parse_size("0B"), Some(0.0));
        assert_eq!(parse_size("n/a"), None);
    }

    #[test]
    fn top_rows_and_physmem() {
        let text = "Processes: 715 total\n\
            PhysMem: 23G used (5073M wired, 8775M compressor), 136M unused.\n\
            \n\
            PID    MEM   CMPRS\n\
            46716  4034M 4034M\n\
            0      489M  0B\n";
        let (sizes, wired, compressor) = parse_top(text);
        assert_eq!(sizes[&46716], (4034.0, 4034.0));
        assert_eq!(sizes[&0], (489.0, 0.0));
        assert_eq!((wired, compressor), (5073, 8775));
    }

    #[test]
    fn ps_keeps_paths_with_spaces() {
        let rows = parse_ps(
            "  86723     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n",
        );
        assert_eq!(
            rows,
            vec![(
                86723,
                1,
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                    .into()
            )]
        );
    }

    #[test]
    fn owners_follow_the_parent_chain() {
        let procs = vec![
            proc(1, 0, "/sbin/launchd", 20.0),
            // Chrome and a helper: the app's launchd job names the owner.
            proc(
                100,
                1,
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                400.0,
            ),
            proc(
                101,
                100,
                "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
                300.0,
            ),
            // A Claude session under iTerm: claude wins over iTerm, and takes its node child.
            proc(
                200,
                1,
                "/Applications/iTerm.app/Contents/MacOS/iTerm2",
                700.0,
            ),
            proc(201, 200, "/bin/zsh", 5.0),
            proc(202, 201, "claude", 1000.0),
            proc(203, 202, "node", 100.0),
            // A launchd job and its child.
            proc(300, 1, "/Users/a/.local/bin/hister", 800.0),
            proc(301, 300, "/usr/bin/git", 30.0),
            // pm2 children are named by pm2.
            proc(400, 1, "node", 50.0),
            proc(401, 400, "node", 200.0),
            // A daemon launchd started that is not in the user's job list.
            proc(500, 1, "/System/Library/WindowServer", 800.0),
            proc(600, 1, "tiny", 1.0),
        ];
        let jobs = HashMap::from([
            (100, "application.com.google.Chrome.1.2".to_string()),
            (200, "application.com.googlecode.iterm2.3.4".to_string()),
            (300, "com.asif.hister".to_string()),
        ]);
        let pm2 = HashMap::from([(401, "forge-bot".to_string())]);
        let owners = attribute(&procs, &jobs, &pm2);
        let get = |name: &str| {
            owners
                .iter()
                .find(|o| o.name == name)
                .unwrap_or_else(|| panic!("{name} in {owners:?}"))
        };

        assert_eq!(get("Google Chrome").footprint_mb, 700.0);
        assert_eq!(get("Google Chrome").procs, 2);
        assert_eq!(get("Claude Code").footprint_mb, 1100.0);
        assert_eq!(get("Claude Code").kind, "claude");
        assert_eq!(get("iTerm").footprint_mb, 705.0);
        assert_eq!(get("com.asif.hister").footprint_mb, 830.0);
        assert_eq!(get("com.asif.hister").top_name, "hister");
        assert_eq!(get("pm2:forge-bot").footprint_mb, 200.0);
        assert_eq!(get("WindowServer").kind, "system");
        // Small owners fold into (other), so the total still adds up.
        assert!(owners.iter().all(|o| o.name != "tiny"));
        let total: f64 = owners.iter().map(|o| o.footprint_mb).sum();
        assert_eq!(total, procs.iter().map(|p| p.mb).sum::<f64>());
        assert_eq!(owners[0].name, "Claude Code");
    }

    #[test]
    fn severity_matches_mem_guard() {
        let mut s = System {
            pressure_level: 1,
            ..System::default()
        };
        assert_eq!(s.severity(), "normal");
        s.swap_used_mb = SWAP_ALERT_MB;
        assert_eq!(s.severity(), "warning");
        s.pressure_level = 4;
        assert_eq!(s.severity(), "critical");
        s = System {
            pressure_level: 2,
            ..System::default()
        };
        assert_eq!(s.severity(), "warning");
    }

    fn sample_at(t: i64, owners: &[(&str, f64)]) -> Sample {
        Sample {
            taken_at: t,
            host: "test".into(),
            system: System {
                pressure_level: 1,
                swap_used_mb: 100,
                ..System::default()
            },
            owners: owners
                .iter()
                .map(|(n, mb)| Owner {
                    name: (*n).into(),
                    kind: "job",
                    procs: 1,
                    footprint_mb: *mb,
                    compressed_mb: 0.0,
                    top_pid: 1,
                    top_name: (*n).into(),
                    top_mb: *mb,
                })
                .collect(),
            models: vec![Model {
                name: "gemma3:4b".into(),
                size_mb: 3992.0,
                vram_mb: 3992.0,
                expires_at: None,
            }],
        }
    }

    #[test]
    fn write_then_ask() {
        let mut db = open(Path::new(":memory:")).unwrap();
        write(
            &mut db,
            &sample_at(
                1000,
                &[("com.asif.hister", 800.0), ("Google Chrome", 900.0)],
            ),
        )
        .unwrap();
        write(&mut db, &sample_at(1300, &[("com.asif.hister", 66.0)])).unwrap();

        let now = top(&db).unwrap();
        assert_eq!(now["owners"][0]["owner"], "com.asif.hister");
        assert_eq!(now["models"][0]["name"], "gemma3:4b");

        let series = owner_series(&db, "hister", 0).unwrap();
        assert_eq!(series["owner"], "com.asif.hister");
        let mb: Vec<f64> = series["points"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p["footprintMb"].as_f64().unwrap())
            .collect();
        assert_eq!(mb, vec![800.0, 66.0]);

        // Two owners contain "o": no guess, the candidates come back.
        let both = owner_series(&db, "o", 0).unwrap();
        assert!(both["owner"].is_null());
        assert_eq!(both["candidates"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn thinning_keeps_one_sample_an_hour() {
        let mut db = open(Path::new(":memory:")).unwrap();
        for i in 0..12 {
            write(&mut db, &sample_at(3600 * 10 + i * 300, &[("a", 100.0)]))
                .unwrap();
        }
        let owners = |db: &Connection| {
            db.query_row("SELECT COUNT(*) FROM mem_owners", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap()
        };
        assert_eq!(owners(&db), 12);
        write(
            &mut db,
            &sample_at(3600 * 10 + FINE_DAYS * 86_400 + 7200, &[("a", 100.0)]),
        )
        .unwrap();
        // The old hour keeps its first sample; the new one is untouched.
        assert_eq!(owners(&db), 2);
        let samples = db
            .query_row("SELECT COUNT(*) FROM mem_samples", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap();
        assert_eq!(samples, 13);
    }

    #[test]
    fn imports_are_idempotent() {
        let mut db = open(Path::new(":memory:")).unwrap();
        let log = "2026-09-25 11:27:55 | pressure_level=1 (warning) | swap_used=3449MB\n\
                   garbage\n\
                   2026-09-25 11:32:55 | pressure_level=1 (normal) | swap_used=0MB\n";
        assert_eq!(import_log(&db, "h", log).unwrap(), (2, 2));
        assert_eq!(import_log(&db, "h", log).unwrap(), (2, 0));
        let csv = "ts_iso,owner,pid,phys_footprint_mb,compressed_mb,swap_used_mb,pressure_level\n\
                   2026-09-25T11:42:21-07:00,com.asif.hister,45271,433.0,432.0,5042,1\n\
                   2026-09-25T11:42:21-07:00,ollama,46716,4067.0,4059.0,5042,1\n";
        assert_eq!(import_csv(&mut db, "h", csv).unwrap(), (2, 2));
        assert_eq!(import_csv(&mut db, "h", csv).unwrap(), (2, 0));
        // 11:42:21 PDT is 18:42:21 UTC.
        let t: i64 = db
            .query_row(
                "SELECT taken_at FROM mem_samples WHERE source='interim-csv'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(t, 1_790_361_741);
        let series = owner_series(&db, "com.asif.hister", 0).unwrap();
        assert_eq!(series["points"][0]["footprintMb"], 433.0);
    }
}
