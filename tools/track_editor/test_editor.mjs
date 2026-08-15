// 编辑器交互逻辑集成测试(jsdom + mock canvas)
// 验证:工具切换 / 画布加点 / 删除 / 撤销 / 导出 JSON 结构 / 分支衔接警告
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const html = readFileSync(new URL("./index.html", import.meta.url), "utf8");

// mock canvas 2d context(空操作)
const ctxStub = new Proxy({}, {
  get: (t, k) => {
    if (k === "measureText") return () => ({ width: 10 });
    if (k === "createLinearGradient" || k === "createPattern") return () => ({});
    return typeof k === "string" ? (() => {}) : undefined;
  },
  set: () => true,
});

const dom = new JSDOM(html, {
  runScripts: "dangerously",
  url: "http://localhost/index.html",
  pretendToBeVisual: true,
  beforeParse(window) {
    window.HTMLCanvasElement.prototype.getContext = () => ctxStub;
    window.URL.createObjectURL = () => "blob:mock";
    window.URL.revokeObjectURL = () => {};
    // jsdom 画布无真实尺寸
    Object.defineProperty(window.HTMLCanvasElement.prototype, "getBoundingClientRect", {
      value() { return { left: 0, top: 0, width: 1600, height: 900 }; },
    });
  },
});

const { window } = dom;
const { document } = window;
await new Promise(r => setTimeout(r, 300));

let checks = 0, failures = 0;
const ok = (cond, label) => {
  checks++;
  if (cond) console.log("[ED] OK   | " + label);
  else { failures++; console.log("[ED] FAIL | " + label); }
};

const $ = id => document.getElementById(id);
const statsText = () => ($("stats").textContent || "").trim();

// ---- 1. 初始加载 ----
ok(statsText().includes("538"), "初始统计:总长 538m(" + statsText() + ")");
ok($("hint").textContent.includes("选择/拖动"), "默认 select 工具提示");

// ---- 2. 工具切换(点击按钮) ----
const addBtn = [...document.querySelectorAll("#topbar .tbtn[data-tool]")].find(b => b.dataset.tool === "add");
addBtn.dispatchEvent(new window.Event("click", { bubbles: true }));
ok($("hint").textContent.includes("追加到当前路由末尾"), "点击「添加点」按钮切换工具");

// ---- 3. 画布加点(模拟 mousedown) ----
const view = $("view");
Object.defineProperty(view, "clientWidth", { value: 1600, configurable: true });
Object.defineProperty(view, "clientHeight", { value: 900, configurable: true });
view.width = 1600 * (window.devicePixelRatio || 1);
view.height = 900 * (window.devicePixelRatio || 1);

const mainRoute = () => window.eval("S.routes[0]");
const beforePts = mainRoute().points.length;
const beforeLen = parseFloat(statsText().match(/总长 (\d+)m/)[1]);

view.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, clientX: 1400, clientY: 800, button: 0 }));
await new Promise(r => setTimeout(r, 600));  // 等 debounce 统计刷新
ok(mainRoute().points.length === beforePts + 1, "画布点击追加控制点(" + beforePts + " → " + mainRoute().points.length + ")");
const afterLen = parseFloat(statsText().match(/总长 (\d+)m/)[1]);
ok(afterLen > beforeLen + 20, "总长增加(" + beforeLen + " → " + afterLen + "m)");

// ---- 4. 键盘删除 ----
window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Delete", bubbles: true }));
await new Promise(r => setTimeout(r, 100));
ok(mainRoute().points.length === beforePts, "Delete 删除选中点(回到 " + mainRoute().points.length + ")");

// ---- 5. 撤销 ----
window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "z", ctrlKey: true, bubbles: true }));
await new Promise(r => setTimeout(r, 100));
ok(mainRoute().points.length === beforePts + 1, "Ctrl+Z 撤销删除(恢复 " + mainRoute().points.length + ")");

// ---- 6. 导出结构 ----
const exported = window.eval("buildExport()");
ok(exported.version === 1 && exported.meta.id === 1, "导出 meta/version");
ok(exported.routes.length === 2 && exported.routes[0].surface === "road" && exported.routes[1].surface === "dirt", "导出含主路+Dirt 分支");
const bm = exported.baked.main;
ok(Array.isArray(bm) && bm.length > 200, "烘焙主路采样点 " + bm.length + " 个");
ok(bm.every(p => Array.isArray(p) && p.length === 8), "采样点为 8 元素数组 [x,y,z,tx,ty,tz,width,s]");
ok(Math.abs(bm[bm.length - 1][7] - afterLen) < 1.5, "尾点 s ≈ 总长(" + bm[bm.length - 1][7].toFixed(1) + ")");
const bb = exported.baked.branch1;
ok(bb.some(p => p[1] > 3.0), "分支含飞坡高度(y max=" + Math.max(...bb.map(p => p[1])).toFixed(1) + "m)");

// ---- 7. 分支衔接警告消失 ----
const warn = ($("warnings").textContent || "").trim();
ok(!warn.includes("未衔接"), "分支端点衔接主路(无未衔接警告: '" + warn + "')");

// ---- 8. 数值输入联动(默认宽度) ----
const pw = $("pWidth");
pw.value = "30";
pw.dispatchEvent(new window.Event("input", { bubbles: true }));
await new Promise(r => setTimeout(r, 600));
ok(Math.abs(window.eval("S.width_default") - 30) < 0.01, "默认宽度输入联动");

// ---- 9. 完赛预估(速度剖面法) ----
const estInfo1 = ($("estInfo").textContent || "").trim();
ok(estInfo1.includes("预估完赛"), "预估信息显示: " + estInfo1.replace(/\s+/g, " ").slice(0, 80));
const est1 = window.eval("estimateFinish(baked['main'], carTable.find(c => c.id === 601))");
ok(est1 && est1.time > 8 && est1.time < 60, "601 号车预估时间合理(" + est1.time.toFixed(1) + "s,均速 " + (est1.avg * 3.6).toFixed(0) + "km/h)");
const est2 = window.eval("estimateFinish(baked['main'], carTable.find(c => c.id === 602))");
ok(est1.time < est2.time, "极速更高的 601 比 602 快(" + est1.time.toFixed(1) + "s < " + est2.time.toFixed(1) + "s)");
ok(est1.speeds.length === window.eval("baked['main'].samples.length"), "速度剖面与采样点对齐");
// 车辆切换
const carSel = $("pCar");
carSel.value = "603";
carSel.dispatchEvent(new window.Event("change", { bubbles: true }));
ok(( $("estInfo").textContent || "").includes("预估完赛"), "切换车辆后预估刷新");

// ---- 10. Car 配表解析(真实 car.gd 片段) ----
const carGdSample = `
var data = \\
{
601:{ "id":601,  "name":'Brute Power',  "drive":'RWD',  "top_speed":320,  "accel":7.5,  "handling":5.5,  "gear_ratios":[3.6, 2.2, 1.6], },
602:{ "id":602,  "name":'Agile Sprinter',  "drive":'FWD',  "top_speed":260,  "accel":7.0,  "handling":9.0, },
}
`;
const cars = window.eval("parseCarGd(" + JSON.stringify(carGdSample) + ")");
ok(cars.length === 2 && cars[0].id === 601 && cars[0].name === "Brute Power", "parseCarGd 解析条目(" + cars.length + " 辆)");
ok(cars[0].top_speed === 320 && typeof cars[0].gear_ratios === "string", "数值解析为数字、数组保持字符串");

console.log("========== %d checks, %d failures ==========", checks, failures);
process.exit(failures ? 1 : 0);
