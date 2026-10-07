"use strict";

const FIRST_LERP_MS = 1000;          // тривалість першого переїзду, поки інтервал між кроками невідомий
const FADE_MS = 1800;                // скільки тане дрон, що пішов на зарядку
const SMOOTH_MS = 600;               // наскільки м'яко дрон «наздоганяє» свою траєкторію
const canvas = document.getElementById("map");
const ctx = canvas.getContext("2d");

let snapshot = null;                 // останній знімок від сервера
const anim = new Map();              // id дрона -> {fromX, fromY, toX, toY, t0, dur}
const shown = new Map();             // id дрона -> {x, y}, де він реально намальований
let lastFrame = null;                // час попереднього кадру
const leaving = [];                  // дрони, що щойно пішли на зарядку: {color, x, y, t0}

// ---------- WebSocket ----------
function connect() {
  const status = document.getElementById("status");
  const ws = new WebSocket(`ws://${location.host}/ws`);
  ws.onopen = () => { status.textContent = "online"; status.className = "on"; };
  ws.onclose = () => {
    status.textContent = "offline, reconnecting…";
    status.className = "off";
    setTimeout(connect, 1000);       // сервер перезапустили — підключаємось знову
  };
  ws.onmessage = (e) => onSnapshot(JSON.parse(e.data));
}

function onSnapshot(s) {
  const now = performance.now();
  for (const d of s.drones) {
    if (!d.pos) {                                      // idle/charging — не на карті
      const a = anim.get(d.id);
      if (a && d.state === "charging") {               // щойно був на карті — пішов на зарядку
        const p = shown.get(d.id);
        const [x, y] = p ? [p.x, p.y] : currentPos(a, now);
        leaving.push({ color: droneColor(d.id), x, y, t0: now });
      }
      anim.delete(d.id);
      shown.delete(d.id);
      continue;
    }
    const [x, y] = d.pos;
    const a = anim.get(d.id);
    if (!a) {
      anim.set(d.id, { fromX: x, fromY: y, toX: x, toY: y, t0: now, dur: FIRST_LERP_MS });
    } else if (a.toX !== x || a.toY !== y) {
      const [cx, cy] = currentPos(a, now);              // їдемо з того місця, де дрон зараз
      const dur = Math.min(5000, Math.max(100, now - a.t0));   // скільки минуло з попереднього кроку
      anim.set(d.id, { fromX: cx, fromY: cy, toX: x, toY: y, t0: now, dur });
    }
  }
  const alive = new Set(s.drones.map((d) => d.id));
  for (const id of anim.keys()) if (!alive.has(id)) anim.delete(id);
  for (const id of shown.keys()) if (!alive.has(id)) shown.delete(id);
  assignColors(s);
  snapshot = s;
  renderPanel(s);
}

function currentPos(a, now) {
  const k = Math.min(1, (now - a.t0) / a.dur);
  return [a.fromX + (a.toX - a.fromX) * k, a.fromY + (a.toY - a.fromY) * k];
}

// ---------- кольори ----------
// Перемішуємо біти номера pid, щоб схожі номери не давали схожих кольорів.
function mix(n) {
  n = Math.imul(n ^ (n >>> 16), 0x45d9f3b);
  n = Math.imul(n ^ (n >>> 16), 0x45d9f3b);
  return (n ^ (n >>> 16)) >>> 0;
}

// Kelly's colors of maximum contrast (без сірого — сірий лише для вільних зон)
const PALETTE = [
  "#F3C300", "#875692", "#F38400", "#A1CAF1", "#BE0032", "#C2B280", "#008856",
  "#E68FAC", "#0067A5", "#F99379", "#604E97", "#F6A600", "#B3446C", "#DCD300",
  "#882D17", "#8DB600", "#654522", "#E25822", "#2B3D26"
];
let colorIdx = new Map();                              // id дрона -> індекс у PALETTE

const pidNum = (id) => parseInt(id.split(".")[1], 10); // "<0.473.0>" -> 473

// Колір за хешем pid; якщо його вже взяв інший дрон — беремо наступний.
// Старші дрони (менший pid) обирають першими, тож їхні кольори не змінюються.
function assignColors(s) {
  colorIdx = new Map();
  const used = new Set();
  const ids = s.drones.map((d) => d.id).sort((a, b) => pidNum(a) - pidNum(b));
  for (const id of ids) {
    let i = mix(pidNum(id)) % PALETTE.length;
    while (used.has(i) && used.size < PALETTE.length) i = (i + 1) % PALETTE.length;
    used.add(i);
    colorIdx.set(id, i);
  }
}

function droneColor(id, alpha = 1) {
  const a = Math.round(alpha * 255).toString(16).padStart(2, "0");  // 0.25 -> "40"
  return PALETTE[colorIdx.get(id) ?? 0] + a;                         // "#BE0032" + "40"
}

const hatch = (() => {                                 // штриховка для вільних зон
  const p = document.createElement("canvas");
  p.width = p.height = 8;
  const c = p.getContext("2d");
  c.fillStyle = "#eee";
  c.fillRect(0, 0, 8, 8);
  c.strokeStyle = "#bbb";
  c.beginPath(); c.moveTo(0, 8); c.lineTo(8, 0); c.stroke();
  return ctx.createPattern(p, "repeat");
})();

// ---------- малювання ----------
function fitCanvas() {
  const r = canvas.getBoundingClientRect();
  const w = Math.round(r.width), h = Math.round(r.height);
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
}

function draw(now) {
  requestAnimationFrame(draw);
  const dt = lastFrame === null ? 0 : now - lastFrame;
  lastFrame = now;
  const follow = 1 - Math.exp(-dt / SMOOTH_MS);        // частка відстані, яку проходимо за цей кадр
  if (!snapshot) return;
  fitCanvas();
  const [gw, gl] = snapshot.grid;
  const [bw, bl] = snapshot.block;
  const pad = 20;
  const scale = Math.min((canvas.width - 2 * pad) / (gw * bw), (canvas.height - 2 * pad) / (gl * bl));
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.save();
  ctx.translate(pad, pad);

  // 1. зони: колір власника або штриховка
  const owner = new Map();
  for (const d of snapshot.drones) for (const [a, b] of d.zones) owner.set(`${a},${b}`, d.id);
  for (let a = 0; a < gw; a++) {
    for (let b = 0; b < gl; b++) {
      const id = owner.get(`${a},${b}`);
      const x = a * bw * scale, y = b * bl * scale, w = bw * scale, h = bl * scale;
      ctx.fillStyle = id ? droneColor(id, 0.25) : hatch;
      ctx.fillRect(x, y, w, h);
      ctx.strokeStyle = "#999";
      ctx.strokeRect(x, y, w, h);
    }
  }

  // 2. активні дрони
  const r = Math.max(4, scale * 0.6);
  for (const d of snapshot.drones) {
    const a = anim.get(d.id);
    if (!a) continue;
    const [tx, ty] = currentPos(a, now);                 // де дрон має бути на траєкторії
    let p = shown.get(d.id);
    if (!p) { p = { x: tx, y: ty }; shown.set(d.id, p); }
    p.x += (tx - p.x) * follow;                         // плавно підтягуємось до траєкторії
    p.y += (ty - p.y) * follow;
    const [x, y] = [p.x, p.y];
    ctx.beginPath();
    ctx.arc((x + 0.5) * scale, (y + 0.5) * scale, r, 0, 2 * Math.PI);
    ctx.fillStyle = droneColor(d.id);
    ctx.fill();
  }

  // 2а. дрони, що пішли на зарядку: тануть і показують ⚡
  for (let i = leaving.length - 1; i >= 0; i--) {
    const l = leaving[i];
    const k = (now - l.t0) / FADE_MS;                  // 0 → 1 за FADE_MS
    if (k >= 1) { leaving.splice(i, 1); continue; }
    const cx = (l.x + 0.5) * scale, cy = (l.y + 0.5) * scale;
    const fade = (1 - k) ** 3;                        // ease-out: швидко на початку, м'яко в кінці
    const rr = r * (0.6 + 0.4 * fade);                 // плавно зменшується до 60% розміру
    ctx.globalAlpha = fade;
    ctx.beginPath();
    ctx.arc(cx, cy, rr, 0, 2 * Math.PI);
    ctx.fillStyle = l.color;
    ctx.fill();
    ctx.font = `${Math.round(rr * 4)}px sans-serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText("⚡", cx, cy);
    ctx.globalAlpha = 1;
  }

  // 3. загиблі: червоний хрестик, блимає 4 рази на секунду
  if (Math.floor(now / 250) % 2 === 0) {
    ctx.strokeStyle = "#c0392b";
    ctx.lineWidth = 3;
    for (const d of snapshot.dead) {
      if (!d.pos) continue;
      const cx = (d.pos[0] + 0.5) * scale, cy = (d.pos[1] + 0.5) * scale;
      ctx.beginPath();
      ctx.moveTo(cx - r, cy - r); ctx.lineTo(cx + r, cy + r);
      ctx.moveTo(cx + r, cy - r); ctx.lineTo(cx - r, cy + r);
      ctx.stroke();
    }
    ctx.lineWidth = 1;
  }
  ctx.restore();
}

// ---------- бічна панель ----------
function renderPanel(s) {
  const byState = (st) => s.drones.filter((d) => d.state === st);
  const owned = new Set(s.drones.flatMap((d) => d.zones.map((z) => z.join(","))));
  const free = s.grid[0] * s.grid[1] - owned.size;
  document.getElementById("counts").textContent =
    `active ${byState("active").length} · charging ${byState("charging").length} · ` +
    `idle ${byState("idle").length} · free zones ${free}`;
  fillList("charging", byState("charging"));
  fillList("idle", byState("idle"));
}

function fillList(elId, drones) {
  const items = drones.map((d) => {
    const li = document.createElement("li");
    li.textContent = d.id;
    li.style.color = droneColor(d.id);
    return li;
  });
  document.getElementById(elId).replaceChildren(...items);
}

connect();
requestAnimationFrame(draw);
