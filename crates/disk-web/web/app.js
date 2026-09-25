// Guilty Spark web client (work name: disk). One page, every machine: the local server answers for
// this one and proxies its peers under /api/h/<id>/…. Read-only by design:
// Guilty Spark suggests what to delete and never deletes anything itself.
'use strict';

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
};

const S = {
  hosts: [],
  host: 'local',
  per: {},          // host id → HostState
  mode: 'kind',     // 'kind' | 'age'
  hover: null,      // path under the pointer
  pointerLast: false,
  tiles: new Map(), // path → tile info for the drawn view
};

function hostState(id) {
  if (!S.per[id]) {
    S.per[id] = {
      status: null, error: null, node: null, path: null, sel: null,
      insights: [], scannedAt: 0, loading: false,
    };
  }
  return S.per[id];
}
const cur = () => hostState(S.host);
const hostLabel = (id) => (S.hosts.find((h) => h.id === id) || {}).label || id;

// ---- formatting ----
function bytes(n) {
  if (n == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = Math.abs(n), i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  const s = v >= 100 || i === 0 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
  return (n < 0 ? '−' : '') + s + ' ' + units[i];
}
function count(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + 'M';
  if (n >= 1e4) return Math.round(n / 1e3) + 'k';
  return String(n);
}
function ago(unix) {
  if (!unix) return 'never';
  const s = Math.max(0, Date.now() / 1000 - unix);
  if (s < 60) return 'just now';
  if (s < 3600) return Math.round(s / 60) + ' min ago';
  if (s < 86400) return Math.round(s / 3600) + ' h ago';
  return Math.round(s / 86400) + ' d ago';
}
function age(days) {
  if (days < 0) return 'unknown';
  if (days === 0) return 'today';
  if (days < 31) return days + ' d ago';
  if (days < 365) return Math.round(days / 30) + ' mo ago';
  return (days / 365).toFixed(1) + ' yr ago';
}
const pct = (part, total) => total ? (100 * part / total).toFixed(part / total < 0.1 ? 1 : 0) + '%' : '—';
const parentOf = (path) => path.slice(0, path.lastIndexOf('/')) || '/';
const baseName = (path) => path.slice(path.lastIndexOf('/') + 1) || path;

const CATEGORY = {
  code: 'Code', agent: 'Agent scratch', toolchain: 'Toolchains', synced: 'Synced',
  git: 'Git', media: 'Media', documents: 'Documents', cache: 'Cache', other: 'Other',
};

// ---- network ----
async function api(host, action, { query, body } = {}) {
  const qs = query ? '?' + new URLSearchParams(query) : '';
  const init = body === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Disk': '1' },
    body: JSON.stringify(body),
  };
  const res = await fetch(`/api/h/${encodeURIComponent(host)}/${action}${qs}`, init);
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  if (!res.ok) {
    const err = new Error((data && data.error) || `HTTP ${res.status}`);
    err.status = res.status; err.data = data;
    throw err;
  }
  return data;
}

async function refreshStatus(id) {
  const h = hostState(id);
  try {
    h.status = await api(id, 'status');
    h.error = null;
  } catch (e) {
    h.error = e.message;
  }
  const fresh = h.status && h.status.scannedAt && h.status.scannedAt !== h.scannedAt;
  if (fresh) {
    h.scannedAt = h.status.scannedAt;
    if (id === S.host) await Promise.all([loadNode(h.path, h.sel), loadInsights(), loadHistory()]);
    else { h.node = null; h.insights = []; h.history = null; }
  }
  if (id === S.host) renderChrome();
  renderHosts();
}

async function loadNode(path, select) {
  const h = cur(), host = S.host;
  if (!h.status || !h.status.tree) return render();
  h.loading = true;
  try {
    const query = { depth: '3' };
    if (path) query.path = path; else query.at = '';
    const node = await api(host, 'node', { query });
    if (host !== S.host) return;
    h.node = node; h.path = node.path; h.error = null;
    h.sel = select && select.startsWith(node.path) ? select : node.path;
  } catch (e) {
    if (e.status === 404 && path) return loadNode(null, null); // gone after a rescan
    h.error = e.message;
  } finally { h.loading = false; }
  render();
}

async function loadHistory() {
  const h = cur(), host = S.host;
  try {
    const [hist, growth] = await Promise.all([api(host, 'history', { query: { days: '7' } }), api(host, 'growth', { query: { hours: '24' } })]);
    if (host === S.host) h.history = { points: hist.points, growth };
  } catch { h.history = null; }
  renderHistory();
}

function sparkline(points) {
  const ns = 'http://www.w3.org/2000/svg';
  const vals = points.map((p) => p.available).filter((v) => v != null);
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 280 56');
  svg.setAttribute('class', 'spark');
  svg.setAttribute('role', 'img');
  if (vals.length < 2) return svg;
  const t0 = points[0].t, t1 = points[points.length - 1].t || t0 + 1;
  let lo = Math.min(...vals), hi = Math.max(...vals);
  const pad = Math.max((hi - lo) * 0.15, 1e8); lo -= pad; hi += pad;
  const xy = points.filter((p) => p.available != null).map((p) => [
    4 + 272 * (p.t - t0) / Math.max(1, t1 - t0),
    4 + 48 * (1 - (p.available - lo) / (hi - lo)),
  ]);
  const d = xy.map(([x, y], i) => (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1)).join(' ');
  const area = document.createElementNS(ns, 'path');
  area.setAttribute('d', d + ` L ${xy[xy.length - 1][0].toFixed(1)} 56 L ${xy[0][0].toFixed(1)} 56 Z`);
  area.setAttribute('class', 'spark-area');
  const line = document.createElementNS(ns, 'path');
  line.setAttribute('d', d);
  line.setAttribute('class', 'spark-line');
  const [lx, ly] = xy[xy.length - 1];
  const dot = document.createElementNS(ns, 'circle');
  dot.setAttribute('cx', lx); dot.setAttribute('cy', ly); dot.setAttribute('r', '3');
  dot.setAttribute('class', 'spark-dot');
  svg.append(area, line, dot);
  svg.setAttribute('aria-label', `Free space over ${points.length} snapshots, now ${bytes(vals[vals.length - 1])}`);
  return svg;
}

function renderHistory() {
  const card = $('#histcard'), h = cur(), st = h.status;
  card.replaceChildren();
  const top = el('div', 'top');
  top.append(el('h3', null, 'Free space · 7 days'), el('div', 'sp'));
  card.append(top);
  const hist = h.history;
  if (!hist || hist.points.length < 2) {
    card.append(el('div', 'muted', hist ? 'One snapshot so far. The trend starts with the next, within the hour.' : '—'));
    return;
  }
  const pts = hist.points, first = pts[0], last = pts[pts.length - 1];
  const delta = (last.available ?? 0) - (first.available ?? 0);
  const line = el('div', 'split');
  const a = el('span'); a.append(delta < 0 ? 'Down ' : 'Up ', el('b', null, bytes(Math.abs(delta))));
  line.append(a, el('span', null, `${pts.length} snapshots since ${ago(first.t)}`));
  card.append(sparkline(pts), line);
  const g = hist.growth;
  if (g && g.baseAt) {
    card.append(el('h3', 'subhead', `Changed since ${ago(g.baseAt)}`));
    if (!g.items.length) { card.append(el('div', 'muted', 'Nothing moved by 10 MB or more.')); return; }
    const list = el('div', 'list');
    const root = st && st.root ? st.root : '';
    for (const it of g.items.slice(0, 6)) {
      const li = el('div', 'li');
      const t = el('div', 't');
      const rel = it.path === root ? '~' : it.path.startsWith(root + '/') ? it.path.slice(root.length + 1) : it.path;
      t.append(el('b', null, baseName(it.path) || it.path), el('span', null, parentOf(rel) === rel ? '' : rel));
      const d = el('span', 's ' + (it.delta > 0 ? 'grew' : 'shrank'), (it.delta > 0 ? '+' : '−') + bytes(Math.abs(it.delta)));
      li.append(t, d, el('span'));
      li.onclick = () => loadNode(parentOf(it.path), it.path);
      list.append(li);
    }
    card.append(list);
  }
}

async function loadInsights() {
  const h = cur(), host = S.host;
  try {
    const data = await api(host, 'insights');
    if (host === S.host) h.insights = data.items;
  } catch { h.insights = []; }
  renderLook();
}

// ---- squarified treemap (Bruls, Huizing, van Wijk) ----
function squarify(items, rect) {
  const total = items.reduce((s, it) => s + it.value, 0);
  const out = [];
  if (!total || rect.w <= 0 || rect.h <= 0) return out;
  const scale = (rect.w * rect.h) / total;
  let { x, y, w, h } = rect;
  let row = [];
  const worst = (r, side) => {
    const s = r.reduce((a, it) => a + it.area, 0);
    let max = 0, min = Infinity;
    for (const it of r) { max = Math.max(max, it.area); min = Math.min(min, it.area); }
    return Math.max((side * side * max) / (s * s), (s * s) / (side * side * min));
  };
  const flush = () => {
    const s = row.reduce((a, it) => a + it.area, 0);
    if (w >= h) {
      const cw = s / h; let cy = y;
      for (const it of row) { const ih = it.area / cw; out.push({ item: it.item, x, y: cy, w: cw, h: ih }); cy += ih; }
      x += cw; w -= cw;
    } else {
      const rh = s / w; let cx = x;
      for (const it of row) { const iw = it.area / rh; out.push({ item: it.item, x: cx, y, w: iw, h: rh }); cx += iw; }
      y += rh; h -= rh;
    }
    row = [];
  };
  for (const item of items) {
    const next = { item, area: item.value * scale };
    const side = Math.min(w, h);
    if (row.length === 0 || worst([...row, next], side) <= worst(row, side)) row.push(next);
    else { flush(); row.push(next); }
  }
  if (row.length) flush();
  return out;
}

function tint(tile, node, depth) {
  if (S.mode === 'age') {
    const d = node.ageDays;
    const mix = d < 0 ? 6 : d <= 7 ? 72 : d <= 30 ? 52 : d <= 180 ? 34 : d <= 365 ? 20 : 9;
    tile.style.setProperty('--cat', 'var(--c-accent)');
    tile.style.setProperty('--mix', mix + '%');
  } else {
    tile.style.setProperty('--cat', `var(--cat-${node.category || 'other'})`);
    tile.style.setProperty('--mix', [44, 34, 27, 22, 18][Math.min(depth - 1, 4)] + '%');
  }
}

function drawMap() {
  const map = $('#map');
  const h = cur();
  map.replaceChildren();
  S.tiles.clear();
  const node = h.node;
  if (!node) return drawEmpty(map);
  const box = map.getBoundingClientRect();
  const W = box.width - 2, H = box.height - 2;
  S.tiles.set(node.path, { node, path: node.path });
  const frag = document.createDocumentFragment();

  const lay = (parent, parentPath, rect, depth) => {
    const items = (parent.children || []).filter((c) => c.bytes > 0).map((c) => ({ value: c.bytes, node: c }));
    if (parent.rest && parent.rest.bytes > 0) items.push({ value: parent.rest.bytes, rest: parent.rest });
    for (const r of squarify(items, rect)) {
      if (r.w < 2 || r.h < 2) continue;
      const tile = el('div', 'tile');
      tile.style.cssText = `left:${r.x}px;top:${r.y}px;width:${r.w}px;height:${r.h}px`;
      if (r.item.rest) {
        tile.classList.add('rest');
        if (r.w > 60 && r.h > 16) tile.append(el('div', 'lab', `${r.item.rest.count ? r.item.rest.count + ' more' : 'smaller items'} · ${bytes(r.item.rest.bytes)}`));
        frag.append(tile);
        continue;
      }
      const c = r.item.node;
      const path = parentPath + '/' + c.name;
      tile.dataset.path = path;
      tint(tile, c, depth);
      if (c.dir) tile.classList.add('dir');
      if (depth === 1) tile.classList.add('top');
      if (c.reclaim) tile.classList.add('reclaim');
      if (path === h.sel) tile.classList.add('sel');
      S.tiles.set(path, { node: c, path });

      const band = depth === 1 ? 21 : 16;
      const nested = c.children && c.children.length && r.w > 44 && r.h > band + 16;
      if (nested) {
        if (r.w > 40) {
          const lab = el('div', 'lab', c.name);
          if (r.w > 110) lab.append(el('span', 'sz', bytes(c.bytes)));
          tile.append(lab);
        }
        frag.append(tile);
        lay(c, path, { x: r.x + 2, y: r.y + band, w: r.w - 4, h: r.h - band - 2 }, depth + 1);
      } else {
        tile.classList.add('leaf');
        if (r.w > 46 && r.h > 18) {
          const lab = el('div', 'lab', c.name);
          if (r.h > 34 && r.w > 60) { lab.append(el('br')); lab.append(el('span', 'sz', bytes(c.bytes))); }
          tile.append(lab);
        }
        frag.append(tile);
      }
    }
  };
  lay(node, node.path, { x: 1, y: 1, w: W, h: H }, 1);
  map.append(frag);
}

function drawEmpty(map) {
  const h = cur(), st = h.status;
  const box = el('div', 'empty');
  if (h.error && !st) {
    box.append(el('h2', null, `${hostLabel(S.host)} is not answering`), el('div', 'mono', h.error));
  } else if (!st || (st.scanning && !st.tree)) {
    const p = st && st.progress;
    box.append(el('div', 'spinner'), el('h2', null, 'Taking the first snapshot'),
      el('div', 'num', p ? `${count(p.files)} files · ${bytes(p.bytes)} so far` : 'Starting…'));
  } else if (st.noSnapshot) {
    box.append(el('h2', null, 'No snapshot yet'),
      el('div', null, st.scanError || 'The hourly snapper has not written one. Start it now.'));
    const b = el('button', 'btn primary', 'Snapshot now'); b.onclick = rescan; box.append(b);
  } else if (st.scanError) {
    box.append(el('h2', null, 'Could not read snapshots'), el('div', 'mono', st.scanError));
  } else {
    box.append(el('div', 'spinner'));
  }
  map.append(box);
}

// ---- chrome: hosts, verdict, trail, legend, cards ----
function renderHosts() {
  const wrap = $('#hosts');
  wrap.replaceChildren(...S.hosts.map((host, i) => {
    const h = hostState(host.id), st = h.status;
    const b = el('button');
    b.setAttribute('aria-current', host.id === S.host ? 'page' : 'false');
    b.title = `${host.label} (${i + 1})`;
    const dot = el('span', 'dot');
    let badge = null;
    if (h.error) { dot.classList.add('fail'); badge = el('span', 'badge bad', 'down'); }
    else if (st && st.space) {
      const free = st.space.available / st.space.total;
      dot.classList.add(free < 0.1 ? 'fail' : free < 0.2 ? 'warn' : 'ok');
      badge = el('span', 'badge' + (free < 0.1 ? ' bad' : free < 0.2 ? ' warn' : ''), bytes(st.space.available));
    }
    b.append(dot, el('span', 'lbl', host.label));
    if (badge) b.append(badge);
    b.onclick = () => switchHost(host.id);
    return b;
  }));
}

function renderChrome() {
  const h = cur(), st = h.status;
  // status box
  const box = $('#scanstatus');
  const dot = el('span', 'dot');
  let text;
  if (h.error) { dot.classList.add('fail'); text = `Unreachable: ${h.error}`; }
  else if (!st) text = 'Connecting…';
  else if (st.scanning) {
    dot.classList.add('warn');
    const p = st.progress;
    text = `Snapshotting · ${p ? count(p.files) + ' files, ' + bytes(p.bytes) : 'starting'}`;
  } else if (st.scanError) { dot.classList.add('fail'); text = st.scanError; }
  else if (st.noSnapshot) { dot.classList.add('warn'); text = 'No snapshot yet'; }
  else {
    // Hourly: older than 90 minutes means the snapper is not running.
    const stale = Date.now() / 1000 - st.scannedAt > 5400;
    dot.classList.add(stale ? 'warn' : st.fullDiskAccess === false ? 'warn' : 'ok');
    text = `Snapshot ${ago(st.scannedAt)}${stale ? ' (overdue; hourly)' : ' · hourly'}` +
      (st.scanSeconds ? ` · took ${Math.round(st.scanSeconds)} s` : '') +
      (st.tree ? ` · ${count(st.tree.files)} files` : '') +
      (st.unreadable ? ` · ${st.unreadable} unreadable` : '');
  }
  box.replaceChildren(dot, el('span', null, text));
  $('#rescan').disabled = !st || st.scanning || !!h.error;
  $('#rescan').title = st && st.scanning ? 'A snapshot is running' : 'Take a snapshot now (r)';

  // verdict: the forest first
  const v = $('#verdict');
  v.replaceChildren();
  if (h.error) {
    v.append(el('b', null, `${hostLabel(S.host)} is not answering.`), el('span', 'muted', 'Numbers below are the last ones seen, if any.'));
  } else if (st && st.space) {
    const look = h.insights.filter((i) => i.markable).reduce((s, i) => s + i.bytes, 0);
    v.append(el('b', null, `${bytes(st.space.available)} free`),
      el('span', null, `of ${bytes(st.space.total)} on ${hostLabel(S.host)}.`));
    if (look) v.append(el('span', null, `${bytes(look)} looks reclaimable.`));
    if (st.tree) v.append(el('span', 'muted', `${st.root} holds ${bytes(st.tree.bytes)}.`));
    if (st.fullDiskAccess === false) {
      const names = (st.excluded || []).map((p) => baseName(p)).join(', ');
      const b = el('div', 'banner warn partial');
      b.append(el('b', null, 'Partial snapshot. '), `No Full Disk Access, so these were skipped rather than trigger a dialog: ${names}. `,
        'Grant it to ', el('span', 'mono', '~/.local/bin/disk-snap'), ' in System Settings › Privacy & Security › Full Disk Access.');
      v.append(b);
    }
  }
  renderDisk();
}

function renderTrail() {
  const h = cur(), node = h.node, st = h.status;
  const t = $('#trail');
  t.replaceChildren();
  if (!node || !st) { t.append(el('button', null, hostLabel(S.host))); return; }
  const root = st.root;
  node.trail.forEach((step, i) => {
    if (i) t.append(el('span', 'sep', '›'));
    const path = i === 0 ? root : root + '/' + node.trail.slice(1, i + 1).map((s) => s.name).join('/');
    const b = el('button', null, i === 0 ? (/^\/Users\/[^/]+$/.test(root) ? '~' : baseName(root)) : step.name);
    b.title = path;
    b.onclick = () => loadNode(path, null);
    t.append(b);
  });
}

function renderLegend() {
  const l = $('#legend');
  l.replaceChildren();
  if (S.mode === 'age') {
    for (const [label, mix] of [['this week', 72], ['this month', 52], ['6 months', 34], ['a year', 20], ['older', 9]]) {
      const i = el('i'); i.style.setProperty('--cat', 'var(--c-accent)'); i.style.background = `color-mix(in srgb, var(--c-accent) ${mix}%, var(--surface))`;
      const s = el('span'); s.append(i, label); l.append(s);
    }
  } else {
    for (const [id, label] of Object.entries(CATEGORY)) {
      if (id === 'other') continue;
      const i = el('i'); i.style.setProperty('--cat', `var(--cat-${id})`);
      const s = el('span'); s.append(i, label); l.append(s);
    }
  }
  const hatch = el('span'); hatch.append(el('i', 'hatch'), 'reclaimable'); l.append(hatch);
}

function renderSelection() {
  const card = $('#selcard'), h = cur();
  card.replaceChildren();
  const info = h.sel && S.tiles.get(h.sel);
  if (!info) { card.append(el('h3', null, 'Selection'), el('div', 'muted', h.node ? 'Nothing selected.' : '—')); return; }
  const n = info.node, total = h.status && h.status.tree ? h.status.tree.bytes : 0;
  const isRoot = info.path === h.node.path;
  const top = el('div', 'top');
  top.append(el('h3', null, isRoot ? 'This folder' : n.dir ? 'Folder' : 'File'), el('div', 'sp'));
  card.append(top, el('p', 'name', n.name), el('div', 'path', info.path));
  const big = el('div', 'big', bytes(n.bytes));
  big.append(el('small', null, `${pct(n.bytes, total)} of scan`));
  card.append(big);
  const pills = el('div', 'pills');
  pills.append(el('span', 'pill accent', CATEGORY[n.category] || 'Other'));
  if (n.reclaim) pills.append(el('span', 'pill good', n.reclaim));
  if (n.readError) pills.append(el('span', 'pill warn', 'partly unreadable'));
  if (n.link) pills.append(el('span', 'pill muted', 'symlink'));
  card.append(pills);
  const kv = el('dl', 'kv');
  const row = (k, v) => kv.append(el('dt', null, k), el('dd', null, v));
  if (n.dir) row('Files', n.files.toLocaleString());
  row('Last write', age(n.ageDays));
  card.append(kv);
  const actions = el('div', 'row');
  if (n.dir && !isRoot) {
    const open = el('button', 'btn', 'Open'); open.onclick = () => loadNode(info.path, null); actions.append(open);
  }
  const copy = el('button', 'btn', 'Copy path');
  copy.onclick = async () => { try { await navigator.clipboard.writeText(info.path); toast('Path copied'); } catch { toast('Copy failed'); } };
  actions.append(copy);
  card.append(actions);
}

function renderDisk() {
  const card = $('#diskcard'), h = cur(), st = h.status;
  card.replaceChildren(el('h3', null, 'Disk'));
  if (!st || !st.space) { card.append(el('div', 'muted', h.error ? 'No answer.' : '—')); return; }
  const { total, available } = st.space;
  const used = total - available;
  const meter = el('div', 'meter');
  const freeShare = available / total;
  if (freeShare < 0.1) meter.classList.add('bad'); else if (freeShare < 0.2) meter.classList.add('warn');
  const u = el('i', 'used'); u.style.width = (100 * used / total) + '%';
  meter.append(u);
  const s1 = el('div', 'split');
  const a = el('span'); a.append('Free now ', el('b', null, bytes(available)));
  const b = el('span', null, `${bytes(total)} total`);
  s1.append(a, b);
  card.append(meter, s1);
}

function renderLook() {
  const card = $('#lookcard'), h = cur();
  card.replaceChildren();
  const top = el('div', 'top');
  top.append(el('h3', null, 'Worth a look'), el('div', 'sp'));
  card.append(top);
  if (!h.insights.length) {
    card.append(el('div', 'muted', h.status && h.status.tree ? 'Nothing over 64 MB stands out.' : '—'));
    return;
  }
  const expanded = card.dataset.all === '1';
  const list = el('div', 'list');
  for (const item of expanded ? h.insights : h.insights.slice(0, 5)) {
    const li = el('div', 'li');
    li.tabIndex = 0;
    const t = el('div', 't');
    t.append(el('b', null, item.name || baseName(item.path)), el('span', null, item.why));
    li.append(t, el('span', 's', bytes(item.bytes)));
    li.onclick = () => loadNode(parentOf(item.path), item.path);
    list.append(li);
  }
  card.append(list);
  if (h.insights.length > 5) {
    const more = el('button', 'linkbtn', expanded ? 'Show fewer' : `Show all ${h.insights.length}`);
    more.style.alignSelf = 'flex-start';
    more.onclick = () => { card.dataset.all = expanded ? '0' : '1'; renderLook(); };
    card.append(more);
  }
}

function render() {
  renderTrail();
  renderLegend();
  drawMap();
  renderSelection();
  renderChrome();
  renderLook();
  renderHistory();
  renderHosts();
}

// ---- actions ----
function select(path) {
  const h = cur();
  h.sel = path;
  for (const t of $('#map').querySelectorAll('.tile.sel')) t.classList.remove('sel');
  const tile = $('#map').querySelector(`.tile[data-path="${CSS.escape(path)}"]`);
  if (tile) tile.classList.add('sel');
  renderSelection();
}

async function switchHost(id) {
  if (id === S.host) return;
  S.host = id;
  S.hover = null;
  const h = cur();
  render();
  await refreshStatus(id);
  if (h.status && h.status.tree && !h.node) await Promise.all([loadNode(h.path, h.sel), loadInsights(), loadHistory()]);
  else render();
}

async function rescan() {
  try {
    cur().status = await api(S.host, 'scan', { body: {} });
    toast(cur().status.scanError ? cur().status.scanError : 'Snapshot started');
  } catch (e) { toast('Snapshot failed to start: ' + e.message); }
  renderChrome(); renderHosts();
}

function up() {
  const h = cur();
  if (!h.node || !h.status || h.node.path === h.status.root) return;
  loadNode(parentOf(h.node.path), h.node.path);
}

// ---- toast ----
let toastTimer;
function toast(text) {
  const t = $('#toast');
  t.textContent = text; t.classList.add('on');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('on'), 2200);
}

// ---- events ----
function tileAt(target) {
  const tile = target.closest && target.closest('.tile[data-path]');
  return tile ? S.tiles.get(tile.dataset.path) : null;
}

function wire() {
  const map = $('#map'), tip = $('#tip');
  map.addEventListener('mousemove', (e) => {
    S.pointerLast = true;
    const info = tileAt(e.target);
    const prev = map.querySelector('.tile.hover');
    if (prev && (!info || prev.dataset.path !== info.path)) prev.classList.remove('hover');
    if (!info) { S.hover = null; tip.hidden = true; return; }
    S.hover = info.path;
    e.target.closest('.tile').classList.add('hover');
    const n = info.node, view = cur().node;
    tip.replaceChildren(el('b', null, n.name),
      el('div', 'num', `${bytes(n.bytes)} · ${pct(n.bytes, view.bytes)} of this view`),
      el('div', 'muted', [CATEGORY[n.category], n.reclaim, S.mode === 'age' ? 'written ' + age(n.ageDays) : null].filter(Boolean).join(' · ')));
    tip.hidden = false;
    const wrap = map.getBoundingClientRect();
    const x = e.clientX - wrap.left, y = e.clientY - wrap.top;
    const tw = tip.offsetWidth, th = tip.offsetHeight;
    tip.style.left = Math.min(x + 14, wrap.width - tw - 6) + 'px';
    tip.style.top = (y + 18 + th > wrap.height ? y - th - 12 : y + 18) + 'px';
  });
  map.addEventListener('mouseleave', () => { tip.hidden = true; S.hover = null; const p = map.querySelector('.tile.hover'); if (p) p.classList.remove('hover'); });
  map.addEventListener('click', (e) => {
    const info = tileAt(e.target);
    if (!info) return;
    // A second tap on the selected folder opens it: the phone's double-click.
    if (info.path === cur().sel && info.node.dir && info.node.hasChildren && e.detail === 1 && matchMedia('(hover: none)').matches) return loadNode(info.path, null);
    select(info.path);
  });
  map.addEventListener('dblclick', (e) => {
    const info = tileAt(e.target);
    if (info && info.node.dir) loadNode(info.path, null);
  });

  for (const b of document.querySelectorAll('.segbtn')) {
    b.onclick = () => {
      S.mode = b.dataset.mode;
      for (const x of document.querySelectorAll('.segbtn')) x.setAttribute('aria-pressed', String(x === b));
      renderLegend(); drawMap();
    };
  }
  $('#rescan').onclick = rescan;

  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target.matches && e.target.matches('input, textarea')) return;
    const h = cur();
    const target = S.pointerLast && S.hover ? S.hover : h.sel;
    const info = target && S.tiles.get(target);
    if (e.key === 'Backspace' || e.key === 'Escape') { e.preventDefault(); up(); }
    else if (e.key === 'Enter' && info && info.node.dir && info.path !== h.node.path) loadNode(info.path, null);
    else if (e.key === 'r') rescan();
    else if (/^[1-9]$/.test(e.key) && S.hosts[+e.key - 1]) switchHost(S.hosts[+e.key - 1].id);
  });
  document.addEventListener('keydown', () => { S.pointerLast = false; }, true);

  let resizeFrame;
  new ResizeObserver(() => { cancelAnimationFrame(resizeFrame); resizeFrame = requestAnimationFrame(drawMap); }).observe(map);
}

async function main() {
  wire();
  renderLegend();
  try {
    S.hosts = (await (await fetch('/api/hosts')).json()).hosts;
  } catch { S.hosts = [{ id: 'local', label: 'This machine', local: true }]; }
  try { const saved = localStorage.getItem('disk.host'); if (saved && S.hosts.some((h) => h.id === saved)) S.host = saved; } catch { /* no storage */ }
  addEventListener('beforeunload', () => { try { localStorage.setItem('disk.host', S.host); } catch { /* no storage */ } });
  render();
  await Promise.all(S.hosts.map((h) => refreshStatus(h.id)));
  // Poll quickly while the shown machine is scanning, slowly otherwise.
  let lastOthers = Date.now();
  const loop = async () => {
    const st = cur().status;
    await refreshStatus(S.host);
    if (Date.now() - lastOthers > 30000) {
      lastOthers = Date.now();
      await Promise.all(S.hosts.filter((h) => h.id !== S.host).map((h) => refreshStatus(h.id)));
    }
    if (cur().status && cur().status.scanning && !cur().node) drawMap();
    setTimeout(loop, st && st.scanning ? 1500 : 10000);
  };
  setTimeout(loop, 1500);
}
main();
