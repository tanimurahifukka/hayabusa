// KajibaFlowHTML.swift — Auto-generated
struct KajibaFlowHTML {
    static let content = """
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>KAJIBA Flow</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  background: #08080c;
  color: #ccc;
  font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif;
  overflow: hidden;
  height: 100vh;
}

#canvas { position: relative; width: 100%; height: 100vh; }
svg#lines { position: absolute; top: 0; left: 0; width: 100%; height: 100%; pointer-events: none; z-index: 1; }

/* ── Nodes ── */
.node {
  position: absolute;
  border-radius: 14px;
  padding: 14px 20px;
  text-align: center;
  z-index: 10;
  min-width: 140px;
  transition: transform 0.2s ease;
  cursor: default;
}
.node .name { font-size: 14px; font-weight: 600; margin-bottom: 3px; }
.node .detail { font-size: 10px; opacity: 0.5; }
.node .indicator {
  width: 8px; height: 8px;
  border-radius: 50%;
  display: inline-block;
  margin-right: 6px;
  vertical-align: middle;
  background: #333;
  transition: background 0.3s, box-shadow 0.3s;
}

/* ── 点灯アニメーション（稼働中のAI） ── */
@keyframes breathe {
  0%, 100% { box-shadow: 0 0 8px var(--glow), inset 0 0 4px var(--glow-inner); }
  50% { box-shadow: 0 0 22px var(--glow), inset 0 0 8px var(--glow-inner); }
}

.node.alive {
  animation: breathe 2.5s ease-in-out infinite;
}

.node.alive .indicator {
  animation: dot-pulse 2s ease-in-out infinite;
}
@keyframes dot-pulse {
  0%, 100% { box-shadow: 0 0 3px var(--dot-color); }
  50% { box-shadow: 0 0 10px var(--dot-color), 0 0 20px var(--dot-color); }
}

/* パルスが通過した瞬間のフラッシュ */
.node.flash {
  transform: scale(1.08);
}

/* 非表示（まだ一度も呼ばれていない） */
.node.dormant { opacity: 0; transform: scale(0.6); pointer-events: none; transition: all 0.8s ease; }

/* 待機中（呼ばれたことはあるが今は処理していない） */
.node.idle {
  opacity: 0.4;
  transform: scale(1);
  transition: all 0.8s ease;
  animation: none !important;
  border-color: #333 !important;
  box-shadow: none !important;
}
.node.idle .indicator { background: #333 !important; animation: none !important; box-shadow: none !important; }
.node.idle .name { color: #555 !important; }
.node.idle .detail { opacity: 0.3; }

/* 処理中（点灯） */
.node.alive { transition: all 0.4s ease; }

/* ── Claude ── */
.node-claude {
  background: #12121f;
  border: 1.5px solid #c0392b;
  --glow: rgba(192, 57, 43, 0.25); --glow-inner: rgba(192, 57, 43, 0.08);
  --dot-color: #e74c3c;
}
.node-claude .name { color: #e74c3c; }
.node-claude .indicator { background: #e74c3c; }

/* ── Classify ── */
.node-classify {
  background: #17140e;
  border: 1.5px solid #e67e22;
  --glow: rgba(230, 126, 34, 0.2); --glow-inner: rgba(230, 126, 34, 0.06);
  --dot-color: #f39c12;
}
.node-classify .name { color: #f39c12; }
.node-classify .indicator { background: #f39c12; }

/* ── Generalist ── */
.node-generalist {
  background: #0c1520;
  border: 1.5px solid #3498db;
  --glow: rgba(52, 152, 219, 0.25); --glow-inner: rgba(52, 152, 219, 0.08);
  --dot-color: #3498db;
}
.node-generalist .name { color: #5dade2; }
.node-generalist .indicator { background: #3498db; }

/* ── Specialist ── */
.node-specialist {
  background: #0c1a10;
  border: 1.5px solid #27ae60;
  --glow: rgba(39, 174, 96, 0.2); --glow-inner: rgba(39, 174, 96, 0.06);
  --dot-color: #2ecc71;
}
.node-specialist .name { color: #2ecc71; font-size: 13px; }
.node-specialist .indicator { background: #2ecc71; }

/* ── Lines ── */
.conn-line { stroke: #1a1a22; stroke-width: 1.5; fill: none; transition: all 0.4s ease; }
.conn-line.dormant { opacity: 0; }
.conn-line.lit { stroke-width: 2.5; }

/* ── Info Bar ── */
#info {
  position: fixed; bottom: 0; left: 0; right: 0;
  background: #0c0c12; border-top: 1px solid #1a1a22;
  padding: 10px 24px;
  display: flex; gap: 32px; align-items: center;
  font-size: 11px; z-index: 100;
}
#info .stat .value { font-size: 20px; font-weight: 700; }
#info .stat .label { font-size: 9px; opacity: 0.4; margin-top: 1px; }

/* ── Log ── */
#log {
  position: fixed; top: 16px; right: 16px; width: 300px; max-height: 280px;
  overflow-y: auto; background: #0a0a10ee; border: 1px solid #1a1a22;
  border-radius: 10px; padding: 10px; font-size: 10px; z-index: 100;
}
.entry { padding: 3px 0; border-bottom: 1px solid #111; animation: fadeIn 0.3s; }
@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
.entry .time { color: #444; }
.entry .route { color: #3498db; }
.entry .local { color: #2ecc71; }
.entry .escalate { color: #e74c3c; }

#title { position: fixed; top: 16px; left: 20px; z-index: 100; }
#title h1 { font-size: 15px; color: #5dade2; letter-spacing: 3px; font-weight: 300; }
#title .sub { font-size: 10px; color: #444; }
</style>
</head>
<body>

<div id="title">
  <h1>KAJIBA FLOW</h1>
  <div class="sub">Real-time Orchestration</div>
</div>

<div id="canvas"><svg id="lines"></svg></div>

<div id="log"><div style="color:#333;margin-bottom:4px;font-size:9px;">ACTIVITY</div></div>

<div id="info">
  <div class="stat"><div class="value" id="s-req" style="color:#5dade2">0</div><div class="label">Requests</div></div>
  <div class="stat"><div class="value" id="s-local" style="color:#2ecc71">0</div><div class="label">Local ($0)</div></div>
  <div class="stat"><div class="value" id="s-esc" style="color:#e74c3c">0</div><div class="label">Escalated</div></div>
  <div class="stat"><div class="value" id="s-tok" style="color:#2ecc71">0</div><div class="label">Tokens Saved</div></div>
  <div class="stat"><div class="value" id="s-cost" style="color:#f39c12">$0.00</div><div class="label">Cost Saved</div></div>
</div>

<script>
// ── Layout: 左→右のきれいなウォーターフォール ──
// x: 左端0.05 → 右端0.75
// y: 縦の中心を軸に均等配置
const NODES = [
  // Col 0 — Cloud
  { id: 'claude',    name: 'Claude Code',     detail: 'Cloud — Opus 4.6',    type: 'claude',     x: 0.05, y: 0.42 },
  // Col 1 — Classify
  { id: 'classify',  name: 'Classify',        detail: '0.6B — Router',       type: 'classify',   x: 0.25, y: 0.42 },
  // Col 2 — Generalists（上下に配置）
  { id: 'qwen',      name: 'Qwen3.5-9B',     detail: 'FIX / UI / API',      type: 'generalist', x: 0.45, y: 0.25 },
  { id: 'gemma',     name: 'Gemma 4 E4B',    detail: 'ALGO / TEST',         type: 'generalist', x: 0.45, y: 0.60 },
  // Col 3 — Specialists
  { id: 'stripe',    name: 'kajiba-stripe',   detail: 'Payment 1.7B',        type: 'specialist', x: 0.68, y: 0.10 },
  { id: 'supabase',  name: 'kajiba-supabase', detail: 'DB / RLS 1.7B',      type: 'specialist', x: 0.68, y: 0.26 },
  { id: 'orca',      name: 'kajiba-orca',     detail: 'Clinical 0.6B',       type: 'specialist', x: 0.68, y: 0.42 },
  { id: 'swift',     name: 'kajiba-swift',    detail: 'Swift/MLX 1.7B',      type: 'specialist', x: 0.68, y: 0.58 },
  { id: 'dawn',      name: 'kajiba-dawn',     detail: 'DAWN 1.7B',           type: 'specialist', x: 0.68, y: 0.74 },
];

const CONNECTIONS = [
  { from: 'claude',   to: 'classify', color: '#e67e22' },
  { from: 'classify', to: 'qwen',     color: '#3498db' },
  { from: 'classify', to: 'gemma',    color: '#3498db' },
  { from: 'qwen',     to: 'stripe',   color: '#27ae60' },
  { from: 'qwen',     to: 'supabase', color: '#27ae60' },
  { from: 'qwen',     to: 'orca',     color: '#27ae60' },
  { from: 'gemma',    to: 'swift',    color: '#27ae60' },
  { from: 'gemma',    to: 'dawn',     color: '#27ae60' },
];

let stats = { requests: 0, local: 0, escalated: 0, tokensSaved: 0, costSaved: 0 };
let nodeEls = {};
// 常時表示: Claude + Classify のみ。他は呼ばれるまで非表示。
const coreNodes = new Set(['claude', 'classify']);

// ── Render ──
function render() {
  const W = window.innerWidth, H = window.innerHeight - 50;
  const canvas = document.getElementById('canvas');
  const svg = document.getElementById('lines');

  // Nodes
  NODES.forEach(n => {
    const el = document.createElement('div');
    const dormant = !coreNodes.has(n.id);
    el.className = `node node-${n.type}${dormant ? ' dormant' : ' alive'}`;
    el.id = `node-${n.id}`;
    el.innerHTML = `<div><span class="indicator"></span><span class="name">${n.name}</span></div><div class="detail">${n.detail}</div>`;
    el.style.left = `${n.x * W - 70}px`;
    el.style.top = `${n.y * H - 25}px`;
    canvas.appendChild(el);
    nodeEls[n.id] = el;
  });

  // Lines (curved)
  CONNECTIONS.forEach(c => {
    const f = NODES.find(n => n.id === c.from), t = NODES.find(n => n.id === c.to);
    if (!f || !t) return;
    const x1 = f.x * W, y1 = f.y * H, x2 = t.x * W, y2 = t.y * H;
    const mx = (x1 + x2) / 2;

    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`);
    path.setAttribute('class', 'conn-line');
    path.setAttribute('data-from', c.from);
    path.setAttribute('data-to', c.to);
    path.style.stroke = c.color + '18';
    if (!coreNodes.has(c.to)) path.classList.add('dormant');
    svg.appendChild(path);
  });
}

// ── Pulse ──
function pulse(fromId, toId, color, dur = 700) {
  const svg = document.getElementById('lines');
  const W = window.innerWidth, H = window.innerHeight - 50;
  const f = NODES.find(n => n.id === fromId), t = NODES.find(n => n.id === toId);
  if (!f || !t) return;

  // Awaken & activate nodes
  [fromId, toId].forEach(id => {
    const el = nodeEls[id];
    if (!el) return;

    // 非表示だったら出現させる
    if (el.classList.contains('dormant')) {
      el.classList.remove('dormant');
      document.querySelectorAll(`path[data-from="${id}"], path[data-to="${id}"]`).forEach(p => p.classList.remove('dormant'));
    }

    // idle/awakened → alive（点灯）
    el.classList.remove('idle', 'awakened');
    el.classList.add('alive');

    // タイマーリセット: 3秒後にidle（灰色）に戻す（coreNodes以外）
    if (!coreNodes.has(id)) {
      clearTimeout(el._idleTimer);
      el._idleTimer = setTimeout(() => {
        el.classList.remove('alive');
        el.classList.add('idle');
      }, 3000);
    }
  });

  // Light up line
  const line = svg.querySelector(`path[data-from="${fromId}"][data-to="${toId}"]`) ||
               svg.querySelector(`path[data-from="${toId}"][data-to="${fromId}"]`);
  if (line) { line.style.stroke = color + '66'; line.classList.add('lit'); }

  // Dot
  const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
  dot.setAttribute('r', '5');
  dot.setAttribute('fill', color);
  dot.style.filter = `drop-shadow(0 0 10px ${color})`;

  const x1 = f.x * W, y1 = f.y * H, x2 = t.x * W, y2 = t.y * H;
  const ax = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
  ax.setAttribute('attributeName', 'cx');
  ax.setAttribute('from', x1); ax.setAttribute('to', x2);
  ax.setAttribute('dur', `${dur}ms`); ax.setAttribute('fill', 'freeze');

  const ay = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
  ay.setAttribute('attributeName', 'cy');
  ay.setAttribute('from', y1); ay.setAttribute('to', y2);
  ay.setAttribute('dur', `${dur}ms`); ay.setAttribute('fill', 'freeze');

  const ar = document.createElementNS('http://www.w3.org/2000/svg', 'animate');
  ar.setAttribute('attributeName', 'r'); ar.setAttribute('values', '4;7;4');
  ar.setAttribute('dur', `${dur}ms`);

  dot.appendChild(ax); dot.appendChild(ay); dot.appendChild(ar);
  svg.appendChild(dot);

  // Flash target node
  nodeEls[toId]?.classList.add('flash');

  setTimeout(() => {
    dot.remove();
    nodeEls[toId]?.classList.remove('flash');
    if (line) { line.style.stroke = (line.style.stroke || '').replace('66', '18'); line.classList.remove('lit'); }
  }, dur + 100);
}

// ── Log ──
function log(msg, type) {
  const el = document.getElementById('log');
  const t = new Date().toLocaleTimeString('ja-JP');
  const e = document.createElement('div');
  e.className = 'entry';
  e.innerHTML = `<span class="time">${t}</span> <span class="${type}">${msg}</span>`;
  el.appendChild(e);
  el.scrollTop = el.scrollHeight;
  if (el.children.length > 40) el.children[1].remove();
}

function updateStats() {
  document.getElementById('s-req').textContent = stats.requests;
  document.getElementById('s-local').textContent = stats.local;
  document.getElementById('s-esc').textContent = stats.escalated;
  document.getElementById('s-tok').textContent = stats.tokensSaved.toLocaleString();
  document.getElementById('s-cost').textContent = `$${stats.costSaved.toFixed(4)}`;
}

// ── SSE: リアルタイムイベント受信 ──
let pending = {};

function handleEvent(ev) {
  if (ev.type === 'request') {
    pending[ev.id] = ev;
    stats.requests++;
    stats.local++;
    const p = (ev.prompt || '').substring(0, 45);
    log(`→ ${p}...`, 'route');

    // リクエスト到着パルス（即座に表示）
    pulse('claude', 'classify', '#e67e22', 400);
    setTimeout(() => pulse('classify', 'qwen', '#3498db', 350), 450);
  }

  if (ev.type === 'completion') {
    const tok = ev.total_tokens || 0;
    stats.tokensSaved += tok;
    stats.costSaved += tok * 0.000075;
    log(`✓ ${tok} tok`, 'local');

    // 結果返却パルス（即座に表示）
    pulse('qwen', 'classify', '#2ecc71', 300);
    setTimeout(() => pulse('classify', 'claude', '#2ecc71', 350), 350);
    delete pending[ev.id];
  }
  updateStats();
}

function connectSSE() {
  const es = new EventSource('/flow/stream');

  es.onmessage = (e) => {
    try {
      const ev = JSON.parse(e.data);
      handleEvent(ev);
    } catch {}
  };

  es.onerror = () => {
    // 接続切れたら3秒後にリトライ
    es.close();
    log('⚠ SSE disconnected, retrying...', 'escalate');
    setTimeout(connectSSE, 3000);
  };

  log('🔌 Connected (SSE real-time)', 'route');
}

// ── Init ──
window.addEventListener('load', () => { render(); updateStats(); connectSSE(); });
window.addEventListener('resize', () => {
  document.getElementById('lines').innerHTML = '';
  document.querySelectorAll('.node').forEach(n => n.remove());
  nodeEls = {}; render();
});
</script>
</body>
</html>

"""
}
