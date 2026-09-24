//! `disk-web` (Guilty Spark): disktree-core snapshots behind a small HTTP server, with a
//! browser UI in Cortana's visual language.
//!
//! One server runs on each machine and shows that machine's snapshots,
//! which `disk-snap` writes hourly into a local SQLite file. The server
//! never scans: it holds no Full Disk Access and asks for none. A server started
//! with `--peer name=url` also proxies the named peer under
//! `/api/h/<name>/…`, so one browser tab shows every machine from a single
//! origin, and the peer's token never reaches the browser.

use std::collections::HashMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{env, fs, thread};

mod store;

use disktree_core::insights::{Finding, worth_a_look};
use disktree_core::removal::{
    self, RemovalEvent, RemovalHandle, RemovalMode, Target,
};
use disktree_core::space::space_info;
use disktree_core::tree::{Node, NodeKind};
use serde_json::{Value, json};
use tiny_http::{Header, Method, Request, Response, Server};

const INDEX_HTML: &str = include_str!("../web/index.html");
const APP_CSS: &str = include_str!("../web/app.css");
const APP_JS: &str = include_str!("../web/app.js");
const TOKENS_CSS: &str = include_str!("../web/tokens.css");

/// The "Worth a look" list is a shortlist, not an inventory.
const INSIGHT_LIMIT: usize = 12;
/// A node response never nests deeper than this: the treemap cannot draw
/// more than a few levels legibly, and each level multiplies the payload.
const MAX_DEPTH: usize = 5;
/// Children per directory in one response; the rest fold into one tile.
const MAX_CHILDREN: usize = 120;
/// Mutating requests carry this header, so a browser has to preflight them,
/// and nothing here answers a preflight: another site's page cannot post to
/// a loopback server.
const INTENT_HEADER: &str = "X-Disk";
const TOKEN_HEADER: &str = "X-Disk-Token";

#[derive(Debug)]
struct Config {
    bind: String,
    dir: PathBuf,
    label: String,
    token: Option<String>,
    peers: Vec<Peer>,
}

/// The launchd job that takes snapshots; "Snapshot now" kickstarts it.
const SNAP_JOB: &str = "com.asif.disk-snap";

#[derive(Debug, Clone)]
struct Peer {
    id: String,
    label: String,
    url: String,
    token: Option<String>,
}

#[derive(Debug, Default)]
struct RemovalJob {
    handle: Option<RemovalHandle>,
    mode: &'static str,
    total: usize,
    items: Vec<Value>,
    done: Option<Value>,
    available_before: u64,
}

#[derive(Debug)]
struct State {
    dir: PathBuf,
    meta: Option<store::Meta>,
    tree: Option<Arc<Node>>,
    db_error: Option<String>,
    kick_error: Option<String>,
    removal: Option<RemovalJob>,
}

type Shared = Arc<Mutex<State>>;

fn main() {
    let config = match parse_args() {
        Ok(config) => config,
        Err(message) => {
            eprintln!("disk-web: {message}\n\n{}", usage());
            std::process::exit(2);
        }
    };
    let server = match Server::http(&config.bind) {
        Ok(server) => server,
        Err(error) => {
            eprintln!("disk-web: cannot listen on {}: {error}", config.bind);
            std::process::exit(1);
        }
    };
    let state = Arc::new(Mutex::new(State {
        dir: config.dir.clone(),
        meta: None,
        tree: None,
        db_error: None,
        kick_error: None,
        removal: None,
    }));
    poll(&mut lock(&state));
    eprintln!(
        "disk-web: {} reading {} on http://{}",
        config.label,
        config.dir.display(),
        config.bind
    );

    let config = Arc::new(config);
    for request in server.incoming_requests() {
        let state = Arc::clone(&state);
        let config = Arc::clone(&config);
        // Proxied calls block on the network; one thread per request keeps a
        // slow peer from stalling the local machine's answers.
        thread::spawn(move || handle(request, &state, &config));
    }
}

fn usage() -> &'static str {
    "usage: disk-web [--bind ADDR:PORT] [--dir STATE_DIR] [--label NAME]
                    [--token-file FILE]
                    [--peer ID=URL[,LABEL][,TOKEN_FILE]]...

  --bind        where to listen (default 127.0.0.1:7321)
  --dir         where disk-snap writes disk.db
                (default ~/Library/Application Support/disk)
  --token-file  require this token on every /api request (for a server
                reachable beyond loopback)
  --peer        another machine's disk-web, shown and proxied here"
}

fn parse_args() -> Result<Config, String> {
    let mut config = Config {
        bind: "127.0.0.1:7321".into(),
        dir: store::default_dir(),
        label: hostname(),
        token: None,
        peers: Vec::new(),
    };
    let mut args = env::args().skip(1);
    while let Some(flag) = args.next() {
        let mut value = || {
            args.next().ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag.as_str() {
            "--bind" => config.bind = value()?,
            "--dir" => config.dir = PathBuf::from(value()?),
            "--label" => config.label = value()?,
            "--token-file" => config.token = Some(read_token(&value()?)?),
            "--peer" => config.peers.push(parse_peer(&value()?)?),
            "-h" | "--help" => {
                println!("{}", usage());
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(config)
}

fn parse_peer(spec: &str) -> Result<Peer, String> {
    let (id, rest) = spec
        .split_once('=')
        .ok_or("--peer wants ID=URL[,LABEL][,TOKEN_FILE]")?;
    let mut parts = rest.split(',');
    let url = parts.next().unwrap_or_default().trim_end_matches('/');
    let label = parts.next().unwrap_or(id).to_string();
    let token = parts.next().map(read_token).transpose()?;
    if id == "local" || id.is_empty() || url.is_empty() {
        return Err(format!("bad --peer {spec}"));
    }
    Ok(Peer {
        id: id.to_string(),
        label,
        url: url.to_string(),
        token,
    })
}

fn read_token(path: &str) -> Result<String, String> {
    let token = fs::read_to_string(path)
        .map_err(|error| format!("{path}: {error}"))?
        .trim()
        .to_string();
    if token.len() < 16 {
        return Err(format!("{path}: token is shorter than 16 characters"));
    }
    Ok(token)
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "this machine".into())
}

fn lock(state: &Shared) -> MutexGuard<'_, State> {
    state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

/// Ask launchd to take a snapshot now. `kickstart` without `-k` does
/// nothing when one is already running, which is the behaviour wanted.
fn kick_snapshot(state: &mut State) {
    let uid = std::process::Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|uid| uid.trim().to_string())
        .unwrap_or_default();
    let outcome = std::process::Command::new("launchctl")
        .args(["kickstart", &format!("gui/{uid}/{SNAP_JOB}")])
        .output();
    state.kick_error = match outcome {
        Ok(out) if out.status.success() => None,
        Ok(out) => Some(format!(
            "launchctl kickstart failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )),
        Err(error) => Some(format!("launchctl: {error}")),
    };
}

/// The snapper's progress file, when it was written in the last 10 s.
fn snap_progress(dir: &Path) -> Option<Value> {
    let text = fs::read_to_string(dir.join("snap.progress.json")).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let updated = value["updatedAt"].as_i64()?;
    (now() - updated <= 10).then_some(value)
}

fn root_of(state: &State) -> Option<PathBuf> {
    state.meta.as_ref().map(|meta| meta.root.clone())
}

/// Collect whatever finished since the last request: a scan, removal events.
fn poll(state: &mut State) {
    let db_path = state.dir.join("disk.db");
    if db_path.exists() {
        let loaded = store::open_read(&db_path).and_then(|db| {
            let Some(id) = store::latest_id(&db)? else {
                return Ok(None);
            };
            if state.meta.as_ref().is_some_and(|meta| meta.id == id) {
                return Ok(None);
            }
            store::load(&db, id)
        });
        match loaded {
            Ok(Some((meta, tree))) => {
                state.meta = Some(meta);
                state.tree = Some(Arc::new(tree));
                state.db_error = None;
            }
            Ok(None) => state.db_error = None,
            Err(error) => state.db_error = Some(error.to_string()),
        }
    }

    let root = root_of(state).unwrap_or_default();
    let mut finished = false;
    if let Some(job) = state.removal.as_mut()
        && let Some(handle) = job.handle.as_ref()
    {
        while let Some(event) = handle.poll() {
            match event {
                RemovalEvent::Start { total } => job.total = total,
                RemovalEvent::Item {
                    path,
                    bytes,
                    outcome,
                } => job.items.push(json!({
                    "path": path.display().to_string(),
                    "bytes": bytes,
                    "error": outcome.err(),
                })),
                RemovalEvent::Done {
                    removed,
                    bytes,
                    failed,
                } => {
                    // Measured, not projected: the saving is what statvfs
                    // says came back, so a hardlink or a snapshot that kept
                    // the blocks shows up as a smaller number.
                    let after = space_info(&root).map_or(0, |s| s.available);
                    job.done = Some(json!({
                        "removed": removed,
                        "bytes": bytes,
                        "failed": failed,
                        "gained": after as i64 - job.available_before as i64,
                    }));
                    finished = true;
                }
            }
        }
        if finished {
            job.handle = None;
        }
    }
    if finished {
        kick_snapshot(state);
    }
}

fn handle(request: Request, state: &Shared, config: &Config) {
    let url = request.url().to_string();
    let (path, query) = url.split_once('?').unwrap_or((&url, ""));
    let path = path.to_string();
    let query = parse_query(query);

    let response = match path.as_str() {
        "/" | "/index.html" => asset(INDEX_HTML, "text/html; charset=utf-8"),
        "/app.css" => asset(APP_CSS, "text/css; charset=utf-8"),
        "/tokens.css" => asset(TOKENS_CSS, "text/css; charset=utf-8"),
        "/app.js" => asset(APP_JS, "text/javascript; charset=utf-8"),
        _ if path.starts_with("/api/") => {
            return api(request, &path, &query, state, config);
        }
        _ => reply(404, &json!({"error": "not found"})),
    };
    let _ = request.respond(response);
}

fn api(
    mut request: Request,
    path: &str,
    query: &HashMap<String, String>,
    state: &Shared,
    config: &Config,
) {
    if let Some(expected) = &config.token
        && header(&request, TOKEN_HEADER).as_deref() != Some(expected)
    {
        let _ = request.respond(reply(401, &json!({"error": "token"})));
        return;
    }
    if *request.method() == Method::Post
        && header(&request, INTENT_HEADER).is_none()
    {
        let _ = request.respond(reply(403, &json!({"error": "intent"})));
        return;
    }
    if config.token.is_none() && !loopback_host(&request) {
        // Without a token this server trusts loopback alone; a Host that
        // is not loopback means DNS rebinding or a misconfigured bind.
        let _ = request.respond(reply(403, &json!({"error": "host"})));
        return;
    }

    let mut body = String::new();
    let _ = request.as_reader().take(1 << 20).read_to_string(&mut body);
    let body: Value = serde_json::from_str(&body).unwrap_or(Value::Null);

    if path == "/api/hosts" {
        let mut hosts =
            vec![json!({"id": "local", "label": config.label, "local": true})];
        hosts.extend(config.peers.iter().map(|peer| {
            json!({"id": peer.id, "label": peer.label, "local": false})
        }));
        let _ = request.respond(reply(200, &json!({"hosts": hosts})));
        return;
    }

    let Some(rest) = path.strip_prefix("/api/h/") else {
        let _ = request.respond(reply(404, &json!({"error": "not found"})));
        return;
    };
    let (host, action) = rest.split_once('/').unwrap_or((rest, ""));

    let response = if host == "local" {
        let (status, value) =
            local(request.method(), action, query, &body, state);
        reply(status, &value)
    } else if let Some(peer) = config.peers.iter().find(|p| p.id == host) {
        let raw_query = request.url().split_once('?').map(|(_, q)| q);
        proxy(peer, request.method(), action, raw_query, &body)
    } else {
        reply(404, &json!({"error": format!("no host {host}")}))
    };
    let _ = request.respond(response);
}

fn local(
    method: &Method,
    action: &str,
    query: &HashMap<String, String>,
    body: &Value,
    state: &Shared,
) -> (u16, Value) {
    let mut guard = lock(state);
    poll(&mut guard);
    match (method, action) {
        (Method::Get, "status") => (200, status(&guard)),
        (Method::Post, "scan") => {
            kick_snapshot(&mut guard);
            (200, status(&guard))
        }
        (Method::Get, "history") => {
            let days: i64 =
                query.get("days").and_then(|d| d.parse().ok()).unwrap_or(7);
            let dir = guard.dir.clone();
            drop(guard);
            db_read(&dir, |db| {
                store::history(db, now() - days * 86_400)
                    .map(|points| json!({"points": points}))
            })
        }
        (Method::Get, "growth") => {
            let hours: i64 =
                query.get("hours").and_then(|h| h.parse().ok()).unwrap_or(24);
            let dir = guard.dir.clone();
            drop(guard);
            db_read(&dir, |db| store::growth(db, hours, 12))
        }
        (Method::Get, "node") => {
            let Some(tree) = guard.tree.clone() else {
                return (409, json!({"error": "no scan yet"}));
            };
            let root = root_of(&guard).unwrap_or_default();
            drop(guard);
            node_response(&tree, &root, query)
        }
        (Method::Get, "insights") => {
            let Some(tree) = guard.tree.clone() else {
                return (409, json!({"error": "no scan yet"}));
            };
            let root = root_of(&guard).unwrap_or_default();
            let scanned_at = guard.meta.as_ref().map_or(0, |m| m.taken_at);
            drop(guard);
            (200, insights(&tree, &root, scanned_at))
        }
        (Method::Post, "plan" | "remove") => {
            let commit = action == "remove";
            remove(&mut guard, body, commit)
        }
        (Method::Get, "removal") => (200, removal_status(&guard)),
        _ => (404, json!({"error": "not found"})),
    }
}

fn status(state: &State) -> Value {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let root = root_of(state).unwrap_or(home);
    let space = space_info(&root).ok();
    let progress = snap_progress(&state.dir);
    let tree = state.tree.as_deref();
    let meta = state.meta.as_ref();
    json!({
        "root": root.display().to_string(),
        "scanning": progress.is_some(),
        "progress": progress,
        // Not an error: a machine that has never taken a snapshot.
        "noSnapshot": meta.is_none(),
        "scanError": state.db_error.as_ref().or(state.kick_error.as_ref()),
        "scannedAt": meta.map_or(0, |m| m.taken_at),
        "scanSeconds": meta.map(|m| m.scan_ms as f64 / 1000.0),
        "unreadable": meta.map(|m| m.errors),
        "fullDiskAccess": meta.map(|m| m.full_disk_access),
        "excluded": meta.map(|m| &m.excluded),
        "tree": tree.map(|t| json!({
            "bytes": t.bytes, "files": t.files, "dirs": t.dirs,
        })),
        "space": space.map(|s| json!({
            "total": s.total, "free": s.free, "available": s.available,
        })),
        "trash": removal::detect_trash_backend().label(),
        "trashAvailable": removal::detect_trash_backend().is_available(),
        "removing": state.removal.as_ref().is_some_and(|j| j.done.is_none()),
    })
}

fn db_read(
    dir: &Path,
    read: impl FnOnce(&rusqlite::Connection) -> rusqlite::Result<Value>,
) -> (u16, Value) {
    match store::open_read(&dir.join("disk.db")).and_then(|db| read(&db)) {
        Ok(value) => (200, value),
        Err(error) => (503, json!({"error": error.to_string()})),
    }
}

fn parse_crumbs(raw: Option<&String>) -> Option<Vec<usize>> {
    match raw.map(String::as_str) {
        None | Some("") => Some(Vec::new()),
        Some(text) => text.split('.').map(|part| part.parse().ok()).collect(),
    }
}

fn node_response(
    tree: &Node,
    root: &Path,
    query: &HashMap<String, String>,
) -> (u16, Value) {
    // A path survives a rescan; crumbs are tree positions and do not.
    let crumbs = match query.get("path") {
        Some(path) => locate(tree, root, Path::new(path)),
        None => parse_crumbs(query.get("at")),
    };
    let Some(crumbs) = crumbs else {
        return (404, json!({"error": "not in this scan"}));
    };
    let Some(node) = tree.resolve(&crumbs) else {
        return (404, json!({"error": "gone; rescan moved it"}));
    };
    let depth = query
        .get("depth")
        .and_then(|d| d.parse().ok())
        .unwrap_or(3_usize)
        .min(MAX_DEPTH);
    // A tile smaller than this share of the view is not drawable, so it is
    // not sent: this is what bounds the payload, not the depth.
    let min_share: f64 = query
        .get("min")
        .and_then(|m| m.parse().ok())
        .unwrap_or(0.0015);
    let floor = (node.bytes as f64 * min_share) as u64;

    let chain = tree.resolve_chain(&crumbs);
    let trail: Vec<Value> = chain
        .iter()
        .enumerate()
        .map(|(i, n)| {
            json!({"name": &*n.name, "crumbs": crumbs[..i].to_vec()})
        })
        .collect();
    let path = disktree_core::tree::path_of(root, tree, &crumbs);
    let mut out = to_json(node, &crumbs, depth, floor, now());
    out["path"] = json!(path.display().to_string());
    out["trail"] = json!(trail);
    out["share"] = json!(node.bytes as f64 / tree.bytes.max(1) as f64);
    (200, out)
}

fn to_json(
    node: &Node,
    crumbs: &[usize],
    depth: usize,
    floor: u64,
    now: i64,
) -> Value {
    let mut out = json!({
        "name": &*node.name,
        "crumbs": crumbs,
        "dir": node.kind.is_dir(),
        "link": node.kind == NodeKind::Symlink,
        "bytes": node.bytes,
        "files": node.files,
        "dirs": node.dirs,
        "modified": node.modified,
        "ageDays": if node.modified > 0 { (now - node.modified) / 86_400 } else { -1 },
        "category": store::category_id(node.category),
        "reclaim": node.reclaim.map(|r| r.label()),
        "readError": node.read_error,
        "hasChildren": !node.children.is_empty(),
    });
    if depth == 0 || node.children.is_empty() {
        return out;
    }
    let mut kids = Vec::new();
    let mut rest_bytes = 0_u64;
    let mut rest_count = 0_u64;
    let mut path = crumbs.to_vec();
    // Children arrive sorted largest first (tree::aggregate), so the cut
    // is a prefix.
    for (index, child) in node.children.iter().enumerate() {
        if kids.len() < MAX_CHILDREN && child.bytes >= floor.max(1) {
            path.push(index);
            kids.push(to_json(child, &path, depth - 1, floor, now));
            path.pop();
        } else {
            rest_bytes += child.bytes;
            rest_count += 1;
        }
    }
    out["children"] = json!(kids);
    // Snapshots prune small entries, so the listed children can sum to less
    // than the parent; that gap is drawn with the cut ones as one tile.
    let listed: u64 = node.children.iter().map(|c| c.bytes).sum();
    rest_bytes += node.bytes.saturating_sub(listed);
    if rest_bytes > 0 {
        out["rest"] = json!({"bytes": rest_bytes, "count": rest_count});
    }
    out
}

fn insights(tree: &Node, root: &Path, scanned_at: i64) -> Value {
    let found = worth_a_look(tree, scanned_at, INSIGHT_LIMIT);
    let items: Vec<Value> = found
        .iter()
        .map(|candidate| {
            let node = tree.resolve(&candidate.crumbs);
            let why = match &candidate.finding {
                Finding::Reclaimable(reason) => reason.label().to_string(),
                Finding::Worktrees { count, oldest_days } => format!(
                    "{count} worktrees, oldest {oldest_days} days"
                ),
                Finding::StaleExperiments { count } => {
                    format!("{count} experiments untouched for 30+ days")
                }
            };
            json!({
                "crumbs": candidate.crumbs,
                "path": disktree_core::tree::path_of(root, tree, &candidate.crumbs)
                    .display().to_string(),
                "name": node.map(|n| n.name.to_string()),
                "bytes": candidate.bytes,
                "why": why,
                // Only whole-directory findings can be marked as-is; a stale
                // subset would take its fresh siblings with it.
                "markable": matches!(candidate.finding, Finding::Reclaimable(_)),
            })
        })
        .collect();
    json!({"items": items})
}

/// Crumbs for an absolute path, walking names from the root.
fn locate(tree: &Node, root: &Path, path: &Path) -> Option<Vec<usize>> {
    let relative = path.strip_prefix(root).ok()?;
    let mut node = tree;
    let mut crumbs = Vec::new();
    for part in relative.components() {
        let name = part.as_os_str().to_str()?;
        let index = node.children.iter().position(|c| &*c.name == name)?;
        crumbs.push(index);
        node = &node.children[index];
    }
    Some(crumbs)
}

/// Find the node for an absolute path by walking names from the root.
fn lookup<'a>(tree: &'a Node, root: &Path, path: &Path) -> Option<&'a Node> {
    let relative = path.strip_prefix(root).ok()?;
    let mut node = tree;
    for part in relative.components() {
        node = node.child_named(part.as_os_str().to_str()?)?;
    }
    Some(node)
}

fn remove(state: &mut State, body: &Value, commit: bool) -> (u16, Value) {
    if state.removal.as_ref().is_some_and(|job| job.done.is_none()) {
        return (409, json!({"error": "a removal is already running"}));
    }
    let (Some(tree), Some(root)) = (state.tree.clone(), root_of(state)) else {
        return (409, json!({"error": "no snapshot yet"}));
    };
    let mode = match body["mode"].as_str() {
        Some("permanent") => RemovalMode::Permanent,
        _ => RemovalMode::Trash,
    };
    let paths: Vec<PathBuf> = body["paths"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(Value::as_str)
                .map(PathBuf::from)
                .collect()
        })
        .unwrap_or_default();
    let targets: Vec<Target> = paths
        .iter()
        .map(|path| {
            let node = lookup(&tree, &root, path);
            Target {
                path: path.clone(),
                bytes: node.map_or(0, |n| n.bytes),
                is_dir: node.is_some_and(|n| n.kind.is_dir()),
                hidden: path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with('.')),
            }
        })
        .collect();
    // The core's guards decide what may go: outside the root, the root,
    // home, mount points and symlink targets are refused there.
    let plan = removal::plan(&targets, &root);
    let described = json!({
        "mode": if mode == RemovalMode::Trash { "trash" } else { "permanent" },
        "bytes": plan.bytes(),
        "targets": plan.targets.iter().map(|t| json!({
            "path": t.path.display().to_string(), "bytes": t.bytes,
        })).collect::<Vec<_>>(),
        "covered": plan.covered.iter().map(|t| t.path.display().to_string())
            .collect::<Vec<_>>(),
        "blocked": plan.blocked.iter().map(|b| json!({
            "path": b.path.display().to_string(), "reason": b.reason,
        })).collect::<Vec<_>>(),
    });
    if !commit {
        return (200, described);
    }
    if plan.is_empty() {
        return (400, json!({"error": "nothing removable", "plan": described}));
    }
    if mode == RemovalMode::Permanent && body["confirm"] != json!("delete") {
        return (400, json!({"error": "permanent deletion needs confirm"}));
    }
    let available_before =
        space_info(&root).map_or(0, |space| space.available);
    state.removal = Some(RemovalJob {
        handle: Some(removal::spawn(plan, mode)),
        mode: if mode == RemovalMode::Trash { "trash" } else { "permanent" },
        total: 0,
        items: Vec::new(),
        done: None,
        available_before,
    });
    (200, described)
}

fn removal_status(state: &State) -> Value {
    state.removal.as_ref().map_or(Value::Null, |job| {
        json!({
            "mode": job.mode,
            "total": job.total,
            "items": job.items,
            "done": job.done,
        })
    })
}

fn proxy(
    peer: &Peer,
    method: &Method,
    action: &str,
    query: Option<&str>,
    body: &Value,
) -> Response<std::io::Cursor<Vec<u8>>> {
    let mut url = format!("{}/api/h/local/{action}", peer.url);
    if let Some(query) = query {
        url.push('?');
        url.push_str(query);
    }
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(3))
        .timeout(Duration::from_secs(30))
        .build();
    let mut call = match method {
        Method::Post => agent.post(&url).set(INTENT_HEADER, "1"),
        _ => agent.get(&url),
    };
    if let Some(token) = &peer.token {
        call = call.set(TOKEN_HEADER, token);
    }
    let result = if *method == Method::Post {
        call.set("Content-Type", "application/json")
            .send_string(&body.to_string())
    } else {
        call.call()
    };
    match result {
        Ok(response) | Err(ureq::Error::Status(_, response)) => {
            let status = response.status();
            let text = response.into_string().unwrap_or_default();
            Response::from_data(text.into_bytes())
                .with_status_code(status)
                .with_header(content_type("application/json"))
        }
        Err(error) => reply(
            502,
            &json!({"error": format!("{} unreachable: {error}", peer.label)}),
        ),
    }
}

fn parse_query(query: &str) -> HashMap<String, String> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .map(|(key, value)| (decode(key), decode(value)))
        .collect()
}

/// `application/x-www-form-urlencoded` decoding, enough for paths.
fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
                match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    Some(byte) => {
                        out.push(byte);
                        i += 2;
                    }
                    None => out.push(b'%'),
                }
            }
            byte => out.push(byte),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn header(request: &Request, name: &str) -> Option<String> {
    request
        .headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str().to_string())
}

fn loopback_host(request: &Request) -> bool {
    let Some(host) = header(request, "Host") else {
        return false;
    };
    let name = host.rsplit_once(':').map_or(host.as_str(), |(h, _)| h);
    matches!(name, "127.0.0.1" | "localhost" | "[::1]")
}

fn content_type(value: &str) -> Header {
    Header::from_bytes("Content-Type", value).expect("static header")
}

fn asset(body: &str, kind: &str) -> Response<std::io::Cursor<Vec<u8>>> {
    Response::from_data(body.as_bytes().to_vec())
        .with_header(content_type(kind))
        .with_header(
            Header::from_bytes("Cache-Control", "no-cache").expect("static"),
        )
}

fn reply(status: u16, value: &Value) -> Response<std::io::Cursor<Vec<u8>>> {
    Response::from_data(value.to_string().into_bytes())
        .with_status_code(status)
        .with_header(content_type("application/json"))
}
