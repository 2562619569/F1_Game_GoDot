// 生成示例赛道 JSON(与 index.html 的 defaultState + bakeRoute + buildExport 同一算法)
// 用法:
//   node bake_sample.mjs                → 输出示例 ../../game/race/tracks/data/map_1.json
//   node bake_sample.mjs <map.json>...  → 按当前算法重烘焙指定地图(控制点不动,
//                                          重建 baked;发车引道/anchor_s 算法升级时用)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SAMPLE = {
  meta: { id: 1, name: "Lakeside Highway" },
  width_default: 24,
  grid: { count: 4, row_gap: 8, col_gap: 7, first_row_offset: 6 },
  options: { walls: true, wall_height: 1.2, sample_step: 2 },
  routes: [
    { id: "main", surface: "road", points: [
      {x:0,   y:0, z:0,    width:null},
      {x:0,   y:0, z:-90,  width:null},
      {x:34,  y:0, z:-175, width:20},
      {x:64,  y:0, z:-255, width:null},
      {x:42,  y:0, z:-335, width:null},
      {x:-12, y:0, z:-400, width:26},
      {x:-12, y:0, z:-500, width:null},
    ]},
    { id: "branch1", surface: "dirt", points: [
      {x:20,  y:0,  z:-122, width:10},
      {x:36,  y:0,  z:-150, width:null},
      {x:46,  y:1.6,z:-172, width:null},
      {x:48,  y:3.4,z:-184, width:null},
      {x:46,  y:1.2,z:-198, width:null},
      {x:72,  y:0,  z:-230, width:null},
      {x:70,  y:0,  z:-268, width:null},
      {x:58,  y:0,  z:-300, width:null},
    ]},
  ],
};

function crPoint(p0, p1, p2, p3, t){
  const t2 = t*t, t3 = t2*t;
  const f = (a,b,c,d) => 0.5*((2*b) + (-a+c)*t + (2*a-5*b+4*c-d)*t2 + (-a+3*b-3*c+d)*t3);
  return { x: f(p0.x,p1.x,p2.x,p3.x), y: f(p0.y,p1.y,p2.y,p3.y), z: f(p0.z,p1.z,p2.z,p3.z) };
}

// ---- 以下与 index.html 的 bakeRoute / gridLeadLen / prependLeadIn 保持同一算法 ----

function bakeRoute(S, route){
  const pts = route.points, step = Math.max(0.5, S.options.sample_step);
  const ptWidth = p => (p.width == null) ? S.width_default : p.width;
  const out = { samples: [], cpS: [] };
  if (pts.length < 2) return out;
  let prev = null;
  const push = (p, tInSeg, wA, wB) => {
    p.width = wA + (wB - wA) * tInSeg;
    p.s = prev ? prev.s + Math.hypot(p.x-prev.x, p.y-prev.y, p.z-prev.z) : 0;
    out.samples.push(p);
    prev = p;
  };
  push({x:pts[0].x, y:pts[0].y, z:pts[0].z}, 0, ptWidth(pts[0]), ptWidth(pts[0]));
  out.cpS[0] = 0;
  for (let i = 0; i < pts.length - 1; i++){
    const p0 = pts[Math.max(i-1,0)], p1 = pts[i], p2 = pts[i+1], p3 = pts[Math.min(i+2, pts.length-1)];
    const chord = Math.hypot(p2.x-p1.x, p2.y-p1.y, p2.z-p1.z);
    const nsteps = Math.max(3, Math.round(chord / step));
    const wA = ptWidth(p1), wB = ptWidth(p2);
    for (let k = 1; k <= nsteps; k++)
      push(crPoint(p0,p1,p2,p3, k/nsteps), k/nsteps, wA, wB);
    out.cpS[i+1] = out.samples[out.samples.length-1].s;
  }
  // 发车引道(仅主路):须在切线差分前插入,引道与起点截面切线自然连续
  if (route.surface === "road") prependLeadIn(S, out, step);
  const sm = out.samples;
  for (let i = 0; i < sm.length; i++){
    const a = sm[Math.max(i-1,0)], b = sm[Math.min(i+1, sm.length-1)];
    const dx=b.x-a.x, dy=b.y-a.y, dz=b.z-a.z, L=Math.hypot(dx,dy,dz)||1;
    sm[i].tx=dx/L; sm[i].ty=dy/L; sm[i].tz=dz/L;
  }
  return out;
}

// 发车引道长度:起点线后最后排发车位 + 6m 余量(与 Godot grid 公式配套)
function gridLeadLen(S){
  const g = S.grid;
  const rows = Math.ceil((g.count || 4) / 2);
  return (g.first_row_offset || 6) + (g.row_gap || 8) * (rows - 1) + 6;
}

// 主路采样前插发车引道直段:发车网格在起点线后方 first_row_offset + row_gap×行数,
// 不补这段发车位就悬在赛道外(回合开始前车辆生成在半空)。直段沿首段切线反向,
// 宽度/高度同起点截面;起点线锚点记录在 out.anchorIdx / out.anchorS
function prependLeadIn(S, out, step){
  const sm = out.samples;
  const a = sm[0], b = sm[1];
  const dx = b.x - a.x, dz = b.z - a.z;
  const L = Math.hypot(dx, dz) || 1;
  const lead = gridLeadLen(S);
  const n = Math.max(2, Math.round(lead / step));
  const d = lead / n;
  const add = [];
  for (let k = n; k >= 1; k--)
    add.push({ x: a.x - dx/L * d * k, y: a.y, z: a.z - dz/L * d * k, width: a.width });
  out.samples = add.concat(sm);
  out.samples[0].s = 0;
  for (let i = 1; i < out.samples.length; i++){
    const p = out.samples[i-1], q = out.samples[i];
    q.s = p.s + Math.hypot(q.x-p.x, q.y-p.y, q.z-p.z);
  }
  for (let i = 0; i < out.cpS.length; i++) out.cpS[i] += lead;
  out.anchorIdx = add.length;
  out.anchorS = lead;
}

// ---- 导出(与 index.html buildExport 同结构;baked 4 元素/点,Godot 端重建切线弧长) ----

const r3 = v => Math.round(v*1000)/1000, r2 = v => Math.round(v*100)/100;

function bakeTrack(S){
  const bk = {}, anchors = {};
  for (const r of S.routes){
    const b = bakeRoute(S, r);
    bk[r.id] = b.samples.map(p => [r3(p.x), r3(p.y), r3(p.z), r2(p.width)]);
    if (b.anchorS != null) anchors[r.id] = { s: b.anchorS, idx: b.anchorIdx };
  }
  const a = anchors.main || { s: 0, idx: 0 };
  return {
    json: {
      version: 1,
      meta: { ...S.meta },
      width_default: S.width_default,
      grid: { ...S.grid, anchor_s: r2(a.s) },
      options: { ...S.options },
      routes: S.routes.map(r => ({ id: r.id, surface: r.surface, points: r.points.map(p => ({ x: r3(p.x), y: r3(p.y), z: r3(p.z), width: p.width })) })),
      baked: bk,
    },
    anchorIdx: a.idx,
  };
}

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "game", "race", "tracks", "data");
mkdirSync(dir, { recursive: true });

const args = process.argv.slice(2);
if (args.length === 0){
  const { json } = bakeTrack(SAMPLE);
  const file = join(dir, `map_${SAMPLE.meta.id}.json`);
  writeFileSync(file, JSON.stringify(json, null, 1));
  const L = json.baked.main.reduce((s, p, i, a) => s + (i ? Math.hypot(p[0]-a[i-1][0], p[1]-a[i-1][1], p[2]-a[i-1][2]) : 0), 0);
  console.log(`OK ${file}  主路 ${json.baked.main.length} 采样点 / ${L.toFixed(0)}m(含发车引道 anchor_s=${json.grid.anchor_s}), 分支 ${json.baked.branch1.length} 采样点`);
} else {
  for (const src of args){
    const S = JSON.parse(readFileSync(src, "utf8"));
    const { json, anchorIdx } = bakeTrack({
      meta: S.meta, width_default: S.width_default,
      grid: { count: 4, row_gap: 8, col_gap: 7, first_row_offset: 6, ...S.grid },
      options: { walls: true, wall_height: 1.2, sample_step: 2, ...S.options },
      routes: S.routes,
    });
    writeFileSync(src, JSON.stringify(json, null, 1));
    const p = json.baked.main[anchorIdx];
    console.log(`OK ${src}  主路 ${json.baked.main.length} 采样点, 起点线 anchor_s=${json.grid.anchor_s} @ (${p[0]}, ${p[2]})`);
  }
}
