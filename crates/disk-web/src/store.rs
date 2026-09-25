#![allow(
    dead_code,
    reason = "shared by disk-web and disk-snap; each uses part"
)]
//! The snapshot store: one SQLite file, written by `disk-snap`, read by
//! `disk-web`.
//!
//! Three tables, each for one question:
//!
//! * `snapshots` — one row per run, kept forever (a few hundred bytes each):
//!   "how has free space moved?"
//! * `dirs` — every directory above [`DIR_FLOOR`] or near the root, per run:
//!   "what grew?". Thinned to one run per day after [`HOURLY_DAYS`].
//! * `trees` — the pruned tree the treemap draws, latest [`TREES_KEPT`] only.
//!
//! The file lives in `~/Library/Application Support/disk/`, never in a
//! synced directory: two machines replicating one SQLite file lose writes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use disktree_core::classify::{Category, Reclaim};
use disktree_core::tree::{Node, NodeKind};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde_json::{Value, json};

/// A directory this large is recorded in every snapshot at any depth.
pub const DIR_FLOOR: u64 = 100 * 1000 * 1000;
/// Directories this shallow are recorded whatever their size.
pub const DIR_DEPTH: usize = 2;
/// Hourly `dirs` rows are kept this long, then one run per day.
pub const HOURLY_DAYS: i64 = 14;
pub const TREES_KEPT: i64 = 2;

/// SQLite integers are signed; sizes and counts are not. Saturate rather than wrap (no disk is
/// 9.2 EB, but a wrapped value would read as negative bytes).
fn sql(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

pub fn default_dir() -> PathBuf {
    let home =
        std::env::var_os("HOME").map_or_else(PathBuf::new, PathBuf::from);
    home.join("Library/Application Support/disk")
}

pub fn open(path: &Path) -> rusqlite::Result<Connection> {
    let db = Connection::open(path)?;
    // WAL: the web server reads while the snapper writes.
    db.pragma_update(None, "journal_mode", "WAL")?;
    db.busy_timeout(std::time::Duration::from_secs(10))?;
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY,
            taken_at INTEGER NOT NULL,
            host TEXT NOT NULL,
            root TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            files INTEGER NOT NULL,
            dirs INTEGER NOT NULL,
            errors INTEGER NOT NULL,
            scan_ms INTEGER NOT NULL,
            vol_total INTEGER,
            vol_available INTEGER,
            full_disk_access INTEGER NOT NULL,
            excluded TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS snapshots_taken ON snapshots(taken_at);
        CREATE TABLE IF NOT EXISTS dirs (
            snapshot_id INTEGER NOT NULL REFERENCES snapshots(id),
            path TEXT NOT NULL,
            depth INTEGER NOT NULL,
            bytes INTEGER NOT NULL,
            files INTEGER NOT NULL,
            category TEXT NOT NULL,
            reclaim TEXT,
            PRIMARY KEY (snapshot_id, path)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS trees (
            snapshot_id INTEGER PRIMARY KEY REFERENCES snapshots(id),
            tree TEXT NOT NULL
        );",
    )?;
    Ok(db)
}

pub fn open_read(path: &Path) -> rusqlite::Result<Connection> {
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(std::time::Duration::from_secs(5))?;
    Ok(db)
}

/// What one run measured, before it is written.
#[derive(Debug)]
pub struct Run<'a> {
    pub taken_at: i64,
    pub host: &'a str,
    pub root: &'a Path,
    pub tree: &'a Node,
    pub errors: u64,
    pub scan_ms: u64,
    pub vol_total: Option<u64>,
    pub vol_available: Option<u64>,
    pub full_disk_access: bool,
    pub excluded: &'a [PathBuf],
}

pub fn write(db: &mut Connection, run: &Run<'_>) -> rusqlite::Result<i64> {
    let excluded: Vec<String> = run
        .excluded
        .iter()
        .map(|p| p.display().to_string())
        .collect();
    let tx = db.transaction()?;
    tx.execute(
        "INSERT INTO snapshots (taken_at, host, root, bytes, files, dirs,
            errors, scan_ms, vol_total, vol_available, full_disk_access,
            excluded)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            run.taken_at,
            run.host,
            run.root.display().to_string(),
            sql(run.tree.bytes),
            sql(run.tree.files),
            sql(run.tree.dirs),
            sql(run.errors),
            sql(run.scan_ms),
            run.vol_total.map(sql),
            run.vol_available.map(sql),
            run.full_disk_access,
            serde_json::to_string(&excluded).unwrap_or_default(),
        ],
    )?;
    let id = tx.last_insert_rowid();
    {
        let mut insert = tx.prepare(
            "INSERT INTO dirs (snapshot_id, path, depth, bytes, files,
                category, reclaim) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )?;
        let mut stack = vec![(run.tree, run.root.to_path_buf(), 0_usize)];
        while let Some((node, path, depth)) = stack.pop() {
            insert.execute(params![
                id,
                path.display().to_string(),
                sql(depth as u64),
                sql(node.bytes),
                sql(node.files),
                category_id(node.category),
                node.reclaim.map(Reclaim::label),
            ])?;
            for child in &node.children {
                if child.kind.is_dir()
                    && (child.bytes >= DIR_FLOOR || depth < DIR_DEPTH)
                {
                    stack.push((child, path.join(&*child.name), depth + 1));
                }
            }
        }
    }
    let floor = (run.tree.bytes / 50_000).max(1 << 20);
    tx.execute(
        "INSERT INTO trees (snapshot_id, tree) VALUES (?1, ?2)",
        params![id, encode(run.tree, floor).to_string()],
    )?;
    tx.execute(
        "DELETE FROM trees WHERE snapshot_id NOT IN
            (SELECT id FROM snapshots ORDER BY id DESC LIMIT ?1)",
        params![TREES_KEPT],
    )?;
    // Hourly detail for two weeks, then the last run of each local day.
    tx.execute(
        "DELETE FROM dirs WHERE snapshot_id IN (
            SELECT id FROM snapshots WHERE taken_at < ?1
            AND id NOT IN (SELECT max(id) FROM snapshots
                GROUP BY date(taken_at, 'unixepoch', 'localtime')))",
        params![run.taken_at - HOURLY_DAYS * 86_400],
    )?;
    tx.commit()?;
    Ok(id)
}

/// The newest snapshot's id, cheap enough to ask on every request.
pub fn latest_id(db: &Connection) -> rusqlite::Result<Option<i64>> {
    db.query_row("SELECT max(id) FROM snapshots", [], |row| row.get(0))
}

#[derive(Debug, Clone)]
pub struct Meta {
    pub id: i64,
    pub taken_at: i64,
    pub root: PathBuf,
    pub errors: u64,
    pub scan_ms: u64,
    pub full_disk_access: bool,
    pub excluded: Vec<String>,
}

pub fn load(
    db: &Connection,
    id: i64,
) -> rusqlite::Result<Option<(Meta, Node)>> {
    let row = db
        .query_row(
            "SELECT s.taken_at, s.root, s.errors, s.scan_ms,
                s.full_disk_access, s.excluded, t.tree
             FROM snapshots s JOIN trees t ON t.snapshot_id = s.id
             WHERE s.id = ?1",
            params![id],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, bool>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                ))
            },
        )
        .optional()?;
    Ok(row.and_then(
        |(taken_at, root, errors, scan_ms, fda, excluded, tree)| {
            let tree: Value = serde_json::from_str(&tree).ok()?;
            Some((
                Meta {
                    id,
                    taken_at,
                    root: PathBuf::from(root),
                    errors: errors as u64,
                    scan_ms: scan_ms as u64,
                    full_disk_access: fda,
                    excluded: serde_json::from_str(&excluded)
                        .unwrap_or_default(),
                },
                decode(&tree)?,
            ))
        },
    ))
}

/// Free space and scanned total over time, oldest first.
pub fn history(db: &Connection, since: i64) -> rusqlite::Result<Vec<Value>> {
    let mut query = db.prepare(
        "SELECT taken_at, vol_total, vol_available, bytes FROM snapshots
         WHERE taken_at >= ?1 ORDER BY taken_at",
    )?;
    let rows = query.query_map(params![since], |row| {
        Ok(json!({
            "t": row.get::<_, i64>(0)?,
            "total": row.get::<_, Option<i64>>(1)?,
            "available": row.get::<_, Option<i64>>(2)?,
            "bytes": row.get::<_, i64>(3)?,
        }))
    })?;
    rows.collect()
}

/// What changed between the newest run and the newest run at least `hours`
/// older, as the deepest directories that explain each change.
pub fn growth(
    db: &Connection,
    hours: i64,
    limit: usize,
) -> rusqlite::Result<Value> {
    let Some(latest) = latest_id(db)? else {
        return Ok(json!({"items": []}));
    };
    let latest_at: i64 = db.query_row(
        "SELECT taken_at FROM snapshots WHERE id = ?1",
        params![latest],
        |row| row.get(0),
    )?;
    // Only a run whose dirs rows survived thinning can be compared.
    let base: Option<(i64, i64)> = db
        .query_row(
            "SELECT id, taken_at FROM snapshots
             WHERE taken_at <= ?1
               AND EXISTS (SELECT 1 FROM dirs WHERE snapshot_id = snapshots.id)
             ORDER BY taken_at DESC LIMIT 1",
            params![latest_at - hours * 3600],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((base, base_at)) = base else {
        return Ok(json!({"items": [], "baseAt": null}));
    };
    // A directory missing on one side counts as zero there: new, or gone.
    let mut query = db.prepare(
        "WITH a AS (SELECT path, depth, bytes FROM dirs WHERE snapshot_id = ?1),
              b AS (SELECT path, depth, bytes FROM dirs WHERE snapshot_id = ?2)
         SELECT path, depth, SUM(nb) - SUM(ob) AS delta, SUM(nb) AS now
         FROM (SELECT path, depth, 0 AS ob, bytes AS nb FROM b
               UNION ALL SELECT path, depth, bytes, 0 FROM a)
         GROUP BY path HAVING ABS(delta) >= 10000000
         ORDER BY ABS(delta) DESC LIMIT 400",
    )?;
    let rows: Vec<(String, i64, i64, i64)> = query
        .query_map(params![base, latest], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?
        .collect::<rusqlite::Result<_>>()?;
    // Keep a path only when no child row explains most of its change, so
    // `~`, `~/code`, `~/code/x` do not all report the same 5 GB.
    let items: Vec<Value> = rows
        .iter()
        .filter(|(path, _, delta, _)| {
            let prefix = format!("{path}/");
            !rows.iter().any(|(other, _, d, _)| {
                other.starts_with(&prefix)
                    && d.signum() == delta.signum()
                    && d.abs() * 10 >= delta.abs() * 7
            })
        })
        .take(limit)
        .map(|(path, depth, delta, now)| {
            json!({"path": path, "depth": depth, "delta": delta, "bytes": now})
        })
        .collect();
    Ok(json!({"items": items, "baseAt": base_at}))
}

/// Directories that shrank sharply and then refilled, from snapshot history: a cache that clears
/// itself (or was cleared) and comes back. Whoever cleared it, deleting it again by hand is not
/// worth it; a setting is. A path missing from a snapshot was under the `dirs` floor there, so it
/// counts as empty.
/// One "came back" finding: the peak, the low after it (and when), and the size now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CameBack {
    pub path: String,
    pub peak: i64,
    pub trough: i64,
    pub trough_at: i64,
    pub now: i64,
}

pub fn came_back(
    db: &Connection,
    days: i64,
) -> rusqlite::Result<Vec<CameBack>> {
    let Some(latest) = latest_id(db)? else {
        return Ok(Vec::new());
    };
    let latest_at: i64 = db.query_row(
        "SELECT taken_at FROM snapshots WHERE id = ?1",
        params![latest],
        |r| r.get(0),
    )?;
    let since = latest_at - days * 86_400;
    let mut q = db.prepare(
        "SELECT id, taken_at FROM snapshots WHERE taken_at >= ?1
           AND EXISTS (SELECT 1 FROM dirs WHERE snapshot_id = snapshots.id) ORDER BY taken_at",
    )?;
    let runs: Vec<(i64, i64)> = q
        .query_map(params![since], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    if runs.len() < 3 {
        return Ok(Vec::new());
    }
    let mut q = db.prepare(
        "SELECT d.path, d.snapshot_id, d.bytes FROM dirs d JOIN snapshots s ON s.id = d.snapshot_id
         WHERE s.taken_at >= ?1 AND d.depth >= 1 AND d.path IN
           (SELECT path FROM dirs WHERE snapshot_id = ?2 AND bytes >= 200000000)",
    )?;
    // path -> snapshot id -> bytes
    let mut series: HashMap<String, HashMap<i64, i64>> = HashMap::new();
    for row in q.query_map(params![since, latest], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
        ))
    })? {
        let (path, id, bytes) = row?;
        series.entry(path).or_default().insert(id, bytes);
    }
    let mut out = Vec::new();
    for (path, by_run) in series {
        let now = by_run.get(&latest).copied().unwrap_or(0);
        let (mut peak, mut trough, mut trough_at, mut best) =
            (0_i64, i64::MAX, 0_i64, None);
        let mut seen = false;
        for (id, at) in &runs {
            let v = by_run.get(id).copied();
            if v.is_some() {
                seen = true;
            }
            if !seen {
                continue;
            }
            let v = v.unwrap_or(0);
            if v > peak {
                peak = v;
                trough = i64::MAX;
            }
            if v < trough {
                trough = v;
                trough_at = *at;
            }
            if peak - trough >= 200_000_000 && trough * 2 <= peak {
                best = Some((peak, trough, trough_at));
            }
        }
        if let Some((peak, trough, at)) = best
            && now * 10 >= peak * 8
        {
            out.push(CameBack {
                path,
                peak,
                trough,
                trough_at: at,
                now,
            });
        }
    }
    out.sort_by_key(|c| std::cmp::Reverse(c.now));
    Ok(out)
}

// ---- the tree codec: compact arrays, children pruned below a floor ----
//
// [name, kind, bytes, files, dirs, modified, category, reclaim, unreadable,
//  [children…]]. A parent's `bytes` stays exact, so what was pruned shows up
// as the gap between it and its listed children.

fn encode(node: &Node, floor: u64) -> Value {
    let children: Vec<Value> = node
        .children
        .iter()
        .filter(|child| child.bytes >= floor)
        .take(400)
        .map(|child| encode(child, floor))
        .collect();
    json!([
        &*node.name,
        match node.kind {
            NodeKind::Directory => 0,
            NodeKind::File => 1,
            NodeKind::Symlink => 2,
            NodeKind::Other => 3,
        },
        node.bytes,
        node.files,
        node.dirs,
        node.modified,
        category_id(node.category),
        node.reclaim.map(Reclaim::label),
        u8::from(node.read_error),
        children,
    ])
}

fn decode(value: &Value) -> Option<Node> {
    let a = value.as_array()?;
    let kind = match a.get(1)?.as_u64()? {
        0 => NodeKind::Directory,
        1 => NodeKind::File,
        2 => NodeKind::Symlink,
        _ => NodeKind::Other,
    };
    let mut node = Node::entry(a.first()?.as_str()?, kind, a.get(2)?.as_u64()?);
    node.files = a.get(3)?.as_u64()?;
    node.dirs = a.get(4)?.as_u64()?;
    node.modified = a.get(5)?.as_i64()?;
    node.category = category_from(a.get(6)?.as_str()?);
    node.reclaim = a.get(7)?.as_str().and_then(reclaim_from);
    node.read_error = a.get(8)?.as_u64()? == 1;
    node.children = a.get(9)?.as_array()?.iter().filter_map(decode).collect();
    Some(node)
}

pub const fn category_id(category: Category) -> &'static str {
    match category {
        Category::Code => "code",
        Category::AgentScratch => "agent",
        Category::Toolchain => "toolchain",
        Category::Synced => "synced",
        Category::Git => "git",
        Category::Media => "media",
        Category::Documents => "documents",
        Category::Cache => "cache",
        Category::Other => "other",
    }
}

fn category_from(id: &str) -> Category {
    Category::LEGEND
        .into_iter()
        .find(|c| category_id(*c) == id)
        .unwrap_or_default()
}

fn reclaim_from(label: &str) -> Option<Reclaim> {
    [
        Reclaim::Regenerable,
        Reclaim::SyncHistory,
        Reclaim::PackageStore,
        Reclaim::BuildOutput,
        Reclaim::Reinstallable,
        Reclaim::SandboxLayers,
        Reclaim::Snapshots,
        Reclaim::Trash,
        Reclaim::Temporary,
    ]
    .into_iter()
    .find(|r| r.label() == label)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str, bytes: u64, children: Vec<Node>) -> Node {
        let mut n = Node::directory(name);
        n.bytes = bytes;
        n.files = 1;
        n.children = children;
        n
    }

    /// home/{.cache/pip, Movies, Documents}; sizes in MB.
    fn home(pip: u64, movies: u64) -> Node {
        let mb = 1_000_000;
        let total = (pip + movies + 50) * mb;
        let cache = dir(".cache", pip * mb, vec![dir("pip", pip * mb, vec![])]);
        let docs = dir("Documents", 50 * mb, vec![]);
        let film = dir("Movies", movies * mb, vec![]);
        dir("home", total, vec![cache, film, docs])
    }

    fn snap(db: &mut Connection, at: i64, tree: &Node) -> i64 {
        write(
            db,
            &Run {
                taken_at: at,
                host: "test",
                root: Path::new("/home"),
                tree,
                errors: 0,
                scan_ms: 1,
                vol_total: Some(500_000_000_000),
                vol_available: Some(100_000_000_000),
                full_disk_access: true,
                excluded: &[],
            },
        )
        .expect("write")
    }

    fn db() -> (tempfile::TempDir, Connection) {
        let temp = tempfile::tempdir().expect("tempdir");
        let db = open(&temp.path().join("disk.db")).expect("open");
        (temp, db)
    }

    const DAY: i64 = 86_400;

    #[test]
    fn growth_names_the_directory_that_grew_not_its_parents() {
        let (_t, mut db) = db();
        snap(&mut db, 0, &home(250, 100));
        snap(&mut db, 8 * DAY, &home(250, 400));
        let g = growth(&db, 24 * 7, 10).expect("growth");
        let items = g["items"].as_array().expect("items");
        assert_eq!(items.len(), 1, "{items:?}");
        assert_eq!(items[0]["path"], "/home/Movies");
        assert_eq!(items[0]["delta"], 300_000_000);
    }

    #[test]
    fn growth_needs_a_run_old_enough_to_compare() {
        let (_t, mut db) = db();
        snap(&mut db, 0, &home(250, 100));
        snap(&mut db, DAY, &home(250, 400));
        let g = growth(&db, 24 * 7, 10).expect("growth");
        assert!(
            g["baseAt"].is_null(),
            "no 7-day-old run, so nothing to compare: {g}"
        );
    }

    #[test]
    fn came_back_finds_a_cache_that_was_cleared_and_refilled() {
        let (_t, mut db) = db();
        snap(&mut db, 0, &home(250, 100));
        snap(&mut db, DAY, &home(5, 100));
        snap(&mut db, 2 * DAY, &home(240, 100));
        let found = came_back(&db, 30).expect("came_back");
        let pip = found
            .iter()
            .find(|c| c.path == "/home/.cache/pip")
            .expect("pip found");
        assert_eq!(pip.peak, 250_000_000);
        assert_eq!(pip.trough, 5_000_000);
        assert_eq!(pip.trough_at, DAY);
        assert!(
            !found.iter().any(|c| c.path == "/home/Movies"),
            "steady is not came-back"
        );
    }

    #[test]
    fn came_back_ignores_a_cache_that_stayed_small() {
        let (_t, mut db) = db();
        snap(&mut db, 0, &home(250, 100));
        snap(&mut db, DAY, &home(5, 100));
        snap(&mut db, 2 * DAY, &home(6, 100));
        assert!(came_back(&db, 30).expect("came_back").is_empty());
    }

    #[test]
    fn history_is_kept_and_detail_thinned_after_two_weeks() {
        let (_t, mut db) = db();
        // Two runs on one old day, one recent: the old day's first run loses its dirs rows.
        let first = snap(&mut db, 0, &home(250, 100));
        let second = snap(&mut db, 3600, &home(250, 100));
        let recent = snap(&mut db, 30 * DAY, &home(250, 100));
        let rows = |id: i64| -> i64 {
            db.query_row(
                "SELECT count(*) FROM dirs WHERE snapshot_id = ?1",
                params![id],
                |r| r.get(0),
            )
            .expect("count")
        };
        assert_eq!(rows(first), 0, "thinned");
        assert!(rows(second) > 0, "last run of that day kept");
        assert!(rows(recent) > 0);
        let snapshots: i64 = db
            .query_row("SELECT count(*) FROM snapshots", [], |r| r.get(0))
            .expect("n");
        assert_eq!(snapshots, 3, "snapshot rows are never thinned");
        let trees: i64 = db
            .query_row("SELECT count(*) FROM trees", [], |r| r.get(0))
            .expect("n");
        assert_eq!(trees, TREES_KEPT);
    }

    #[test]
    fn sql_saturates_instead_of_wrapping() {
        assert_eq!(sql(u64::MAX), i64::MAX);
        assert_eq!(sql(42), 42);
    }

    #[test]
    fn codec_round_trips_and_prunes() {
        let mut root = Node::directory("home");
        let mut code = Node::directory("code");
        code.category = Category::Code;
        code.reclaim = Some(Reclaim::BuildOutput);
        code.children = vec![
            Node::entry("big", NodeKind::File, 5 << 20),
            Node::entry("tiny", NodeKind::File, 10),
        ];
        code.bytes = (5 << 20) + 10;
        root.bytes = code.bytes;
        root.children = vec![code];
        let back = decode(&encode(&root, 1 << 20)).expect("decodes");
        let code = &back.children[0];
        assert_eq!(code.category, Category::Code);
        assert_eq!(code.reclaim, Some(Reclaim::BuildOutput));
        assert_eq!(code.children.len(), 1, "tiny is pruned");
        assert_eq!(code.bytes, (5 << 20) + 10, "the parent total stays exact");
    }
}
