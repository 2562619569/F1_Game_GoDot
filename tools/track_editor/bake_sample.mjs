// 生成示例赛道 JSON(与 index.html 的 defaultState + bakeRoute + buildExport 同一算法)
// 用法: node bake_sample.mjs  → 输出 ../../game/race/tracks/data/map_1.json
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const S = {
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
const ptWidth = p => (p.width == null) ? S.width_default : p.width;

function bakeRoute(route){
  const pts = route.points, step = Math.max(0.5, S.options.sample_step);
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
  const sm = out.samples;
  for (let i = 0; i < sm.length; i++){
    const a = sm[Math.max(i-1,0)], b = sm[Math.min(i+1, sm.length-1)];
    const dx=b.x-a.x, dy=b.y-a.y, dz=b.z-a.z, L=Math.hypot(dx,dy,dz)||1;
    sm[i].tx=dx/L; sm[i].ty=dy/L; sm[i].tz=dz/L;
  }
  return out;
}

const r3 = v => Math.round(v*1000)/1000, r2 = v => Math.round(v*100)/100;
const bk = {};
for (const r of S.routes)
  bk[r.id] = bakeRoute(r).samples.map(p => [r3(p.x), r3(p.y), r3(p.z), r3(p.tx), r3(p.ty), r3(p.tz), r2(p.width), r2(p.s)]);

const out = {
  version: 1,
  meta: { ...S.meta },
  width_default: S.width_default,
  grid: { ...S.grid },
  options: { ...S.options },
  routes: S.routes.map(r => ({ id: r.id, surface: r.surface, points: r.points.map(p => ({ x: r3(p.x), y: r3(p.y), z: r3(p.z), width: p.width })) })),
  baked: bk,
};

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "game", "race", "tracks", "data");
mkdirSync(dir, { recursive: true });
const file = join(dir, `map_${S.meta.id}.json`);
writeFileSync(file, JSON.stringify(out, null, 1));
const L = bk.main[bk.main.length-1][7];
console.log(`OK ${file}  主路 ${bk.main.length} 采样点 / ${L.toFixed(0)}m, 分支 ${bk.branch1.length} 采样点`);
