/* ModRacer 美术资源编辑器
 * 车壳（cars/<id>/body.json：前/后轴 yz + 车体半宽 body_width）与轮毂（wheels/<id>/wheel.json，中心点）的
 * 可视化定义工具。写回依赖 File System Access API；不支持时降级为「读取目录 + 下载 JSON」。
 * 坐标约定与 docs/美术资源与车辆结构.md 一致：GLB 场景根空间、米、Y-up、车头朝 -Z。
 */
(function () {
'use strict';

// ---------------- 常量与状态 ----------------
var AXLES = ['front', 'rear'];
var AXLE_LABEL = { front: '前轴', rear: '后轴' };
var AXLE_COLOR = { front: 0x37c8ff, rear: 0xffd23e };
var AXLE_DEFAULT = { front: { y: 0.35, z: -1.2 }, rear: { y: 0.35, z: 1.2 } };
var DEFAULT_BODY_WIDTH = 0.9;
var DEFAULT_WHEEL_WIDTH = 0.2;          // wheel.json 缺 width 时齐边推导用
var WHEEL_SLOT_KEYS = ['front_left', 'front_right', 'rear_left', 'rear_right'];
var WIDTH_COLOR = 0xb48cff;             // 车宽手柄（紫）
var MIN_BODY_WIDTH = 0.1;
var DEFAULT_TOOL = 'axle';
// 材质语义槽位：写入 body.json 的 materials 字段（值 = GLB 内材质名）
var MAT_SLOTS = [
  { key: 'headlight', label: '大灯', color: 0xffd23e },
  { key: 'brake_light', label: '刹车灯', color: 0xff5252 },
  { key: 'body', label: '车身', color: 0x4f8cff }
];
// 「按名称自动识别」规则：材质名匹配正则 → 槽位
var MAT_AUTORULES = [
  ['brake_light', /brake|tail|stop|刹车/i],
  ['headlight', /head|lamp|大灯/i],
  ['body', /hull|body|paint|chassis|车身|车体/i]
];
// 预设材质球（引擎效果，body.json 的 material_presets 字段）：
// 标记类型 + 暴露参数；引擎端同构定义见 game/car/material_presets.gd（社区 CC0 shader）。
var PRESET_SLOTS = [
  { key: 'paint', label: '车漆', color: 0xe0524a,
    params: [
      { key: 'color', label: '颜色', type: 'color' },
      { key: 'glancing', label: '掠射色', type: 'color' },
      { key: 'clearcoat', label: '清漆', type: 'range' }
    ] },
  { key: 'headlight_lens', label: '大灯罩', color: 0x8fd8ff,
    params: [
      { key: 'color', label: '颜色', type: 'color' },
      { key: 'alpha', label: '透明度', type: 'range' }
    ] },
  { key: 'glass', label: '车玻璃', color: 0x39404d,
    params: [
      { key: 'color', label: '颜色', type: 'color' },
      { key: 'alpha', label: '不透明度', type: 'range' }
    ] }
];
var PRESET_DEFAULT_PARAMS = {
  paint: { color: '#c23a2f', glancing: '#2a0d0b', clearcoat: 1.0 },
  headlight_lens: { color: '#ffffff', alpha: 0.35 },
  glass: { color: '#05060a', alpha: 1.0 }
};
var PRESET_AUTORULES = [
  ['paint', /paint|车漆|漆|hull|body/i],
  ['headlight_lens', /lens|灯罩|罩|cover/i],
  ['glass', /glass|玻璃/i]
];

function wheelX(bodyWidth, width) { return bodyWidth - width / 2; }
function axleOf(k) { return S.json[k + '_axle']; }

var S = {
  rootHandle: null,      // FileSystemDirectoryHandle（art/ 根）
  files: null,           // Map<相对路径, File>（降级模式）
  writable: false,
  cars: [], wheels: [],
  mode: null,            // 'body' | 'wheel'
  assetId: null,
  json: null,            // 当前资产元数据（编辑中）
  selected: null,        // 选中的标记 key
  tool: null,            // 'axle' | 'width' | null
  snap: 0.01,
  steerDeg: 0,
  modelBBox: null,
  wheelCache: {},        // 轮毂 id -> {json, scene}
  matList: [],           // 当前模型的材质条目（按首次出现排序）
  matById: {},           // 材质 uuid -> 条目
  matSel: null           // 选中的材质 uuid（视口高亮其所有引用网格）
};

function matSlotDef(key) {
  for (var i = 0; i < MAT_SLOTS.length; i++) if (MAT_SLOTS[i].key === key) return MAT_SLOTS[i];
  return null;
}
function matSlotColor(key) { var d = matSlotDef(key); return d ? d.color : 0xffffff; }
function matSlotCss(key) { return '#' + matSlotColor(key).toString(16).padStart(6, '0'); }
function presetSlotDef(key) {
  for (var i = 0; i < PRESET_SLOTS.length; i++) if (PRESET_SLOTS[i].key === key) return PRESET_SLOTS[i];
  return null;
}
function presetSlotCss(key) { var d = presetSlotDef(key); return '#' + (d ? d.color : 0xffffff).toString(16).padStart(6, '0'); }

var $ = function (id) { return document.getElementById(id); };
var statusEl = $('status');
function setStatus(msg, cls) { statusEl.textContent = msg; statusEl.className = cls || ''; }

function r4(v) { return Math.round(v * 10000) / 10000; }
function fmt(v) { return (Math.round(v * 1000) / 1000).toString(); }

// ---------------- three.js 场景 ----------------
var wrap = $('viewportWrap');
var scene = new THREE.Scene();
scene.background = new THREE.Color(0x14161a);
scene.fog = new THREE.Fog(0x14161a, 30, 80);

var camera = new THREE.PerspectiveCamera(50, 1, 0.01, 500);
camera.position.set(3.2, 2.2, 4.2);

var renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
wrap.appendChild(renderer.domElement);

var labelRenderer = new THREE.CSS2DRenderer();
labelRenderer.domElement.style.position = 'absolute';
labelRenderer.domElement.style.inset = '0';
labelRenderer.domElement.style.pointerEvents = 'none';
wrap.appendChild(labelRenderer.domElement);

var controls = new THREE.OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.maxPolarAngle = Math.PI * 0.52;

scene.add(new THREE.HemisphereLight(0xdfe8ff, 0x3a3a44, 0.95));
var sun = new THREE.DirectionalLight(0xffffff, 0.9); sun.position.set(4, 7, 5); scene.add(sun);
var fill = new THREE.DirectionalLight(0xaab6ff, 0.35); fill.position.set(-5, 3, -4); scene.add(fill);

var grid = new THREE.GridHelper(20, 100, 0x5a6070, 0x2b2f38); scene.add(grid);
var axes = new THREE.AxesHelper(1.2); axes.position.y = 0.001; scene.add(axes);
var frontArrow = new THREE.ArrowHelper(new THREE.Vector3(0, 0, -1), new THREE.Vector3(0, 0.002, 0), 1.6, 0x4f8cff, 0.18, 0.1);
scene.add(frontArrow);

var modelGroup = new THREE.Group(); scene.add(modelGroup);          // 当前编辑的 GLB
var markerGroup = new THREE.Group(); scene.add(markerGroup);        // 标记点
var previewGroup = new THREE.Group(); scene.add(previewGroup);      // 车壳模式的轮毂装配预览
var semiGroup = new THREE.Group(); scene.add(semiGroup); semiGroup.visible = false;   // 半透明轮胎可视化
var semiTires = {};
var semiMat = new THREE.MeshBasicMaterial({ color: 0x1c2126, transparent: true, opacity: 0.3, depthWrite: false, side: THREE.DoubleSide });
WHEEL_SLOT_KEYS.forEach(function (k) {
  var m = new THREE.Mesh(new THREE.CylinderGeometry(0.3, 0.3, 0.2, 24), semiMat);
  m.rotation.z = Math.PI / 2;   // 圆柱轴转成 X（轮胎滚动轴）
  m.renderOrder = 1;
  semiTires[k] = m; semiGroup.add(m);
});
var spinPivot = null;                                               // 轮毂模式自转预览

var markers = {};   // key -> {group, hit, sphere, label}

function resize() {
  var w = wrap.clientWidth, h = wrap.clientHeight;
  camera.aspect = w / h; camera.updateProjectionMatrix();
  renderer.setSize(w, h); labelRenderer.setSize(w, h);
}
new ResizeObserver(resize).observe(wrap);
resize();

// ---------------- 标记点 ----------------
function removeMarker(key) {
  var mk = markers[key];
  if (!mk) return;
  // r147 CSS2DRenderer 不随对象移除清理 DOM，需手动摘除标签元素
  mk.group.traverse(function (o) {
    if (o.isCSS2DObject && o.element && o.element.parentNode) {
      o.element.parentNode.removeChild(o.element);
    }
  });
  markerGroup.remove(mk.group);
  delete markers[key];
}

function clearMarkers() {
  Object.keys(markers).forEach(removeMarker);
  markers = {}; S.selected = null;
}

function markerScale() {
  if (S.modelBBox) {
    var size = new THREE.Vector3(); S.modelBBox.getSize(size);
    var d = Math.max(size.x, size.y, size.z, 0.3);
    return Math.max(d * 0.035, 0.02);
  }
  return 0.04;
}

function makeMarker(key, label, color) {
  var g = new THREE.Group();
  var s = 1; // 实际尺寸在 refreshMarkerScale 里统一放缩

  var sphere = new THREE.Mesh(
    new THREE.SphereGeometry(1, 20, 14),
    new THREE.MeshBasicMaterial({ color: color, depthTest: false })
  );
  sphere.scale.setScalar(0.28 * s);
  sphere.renderOrder = 10;   // 置顶：不被车壳/轮毂模型遮挡
  g.add(sphere);

  var axesLen = 0.9;
  [[1, 0, 0, 0xff5555], [0, 1, 0, 0x55ff55], [0, 0, 1, 0x5588ff]].forEach(function (a) {
    var dir = new THREE.Vector3(a[0], a[1], a[2]);
    var line = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints([dir.clone().multiplyScalar(-axesLen), dir.clone().multiplyScalar(axesLen)]),
      new THREE.LineBasicMaterial({ color: a[3], transparent: true, opacity: 0.9 })
    );
    g.add(line);
  });

  var hit = new THREE.Mesh(
    new THREE.SphereGeometry(1.6, 8, 6),
    new THREE.MeshBasicMaterial({ visible: false })
  );
  g.add(hit);

  var labelDiv = document.createElement('div');
  labelDiv.className = 'marker-label';
  labelDiv.textContent = label;
  labelDiv.style.background = '#' + color.toString(16).padStart(6, '0');
  var labelObj = new THREE.CSS2DObject(labelDiv);
  labelObj.position.set(0, 1.1, 0);
  g.add(labelObj);

  g.userData.markerKey = key;
  hit.userData.markerKey = key;
  markerGroup.add(g);
  markers[key] = { group: g, hit: hit, sphere: sphere, label: labelObj };
  return markers[key];
}

function refreshMarkerScale() {
  var k = markerScale();
  Object.keys(markers).forEach(function (key) {
    markers[key].group.scale.setScalar(k);
  });
}

function setMarkerVisual(key, pos) {
  if (!markers[key]) return;
  markers[key].group.position.copy(pos);
}

function selectMarker(key) {
  S.selected = key;
  Object.keys(markers).forEach(function (k) {
    var on = k === key;
    var base = S.mode === 'wheel' ? 0x3ecf8e : (k.indexOf('width') === 0 ? WIDTH_COLOR : AXLE_COLOR[k]);
    markers[k].sphere.material.color.setHex(on ? 0xffffff : base);
    markers[k].group.scale.setScalar(markerScale() * (on ? 1.35 : 1));
  });
  renderPanel();
}

// ---------------- 拖拽交互 ----------------
var raycaster = new THREE.Raycaster();
var dragPlane = new THREE.Plane();
var dragging = null;
var downPos = null;
var dragStart = null;   // 车宽手柄拖拽基线：{key, x, bw}

function pointerNDC(e) {
  var r = renderer.domElement.getBoundingClientRect();
  return new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
}

function pickMarker(e) {
  raycaster.setFromCamera(pointerNDC(e), camera);
  var objs = [];
  Object.keys(markers).forEach(function (k) { objs.push(markers[k].hit); });
  var hits = raycaster.intersectObjects(objs, false);
  return hits.length ? hits[0].object.userData.markerKey : null;
}

renderer.domElement.addEventListener('pointerdown', function (e) {
  if (e.button !== 0) return;
  downPos = [e.clientX, e.clientY];
  var key = pickMarker(e);
  if (key) {
    // 拖拽门控：工具未激活时只选中不可拖
    var dragAllowed = S.mode === 'wheel' || (S.tool === (key.indexOf('width') === 0 ? 'width' : 'axle'));
    selectMarker(key);
    if (!dragAllowed) return;
    dragging = key;
    controls.enabled = false;
    var p = markers[key].group.position.clone();
    var n = new THREE.Vector3(); camera.getWorldDirection(n);
    dragPlane.setFromNormalAndCoplanarPoint(n, p);
    if (key.indexOf('width') === 0) {
      // 记录车宽拖拽基线：世界 x 增量 → body_width
      var rr = new THREE.Raycaster().setFromCamera(pointerNDC(e), camera);
      var vv = new THREE.Vector3();
      dragStart = rr.ray.intersectPlane(dragPlane, vv) ? { key: key, x: vv.x, bw: S.json.body_width } : null;
    }
    renderer.domElement.style.cursor = 'grabbing';
    e.preventDefault();
  }
});

window.addEventListener('pointermove', function (e) {
  if (dragging) {
    raycaster.setFromCamera(pointerNDC(e), camera);
    var p = new THREE.Vector3();
    if (raycaster.ray.intersectPlane(dragPlane, p)) {
      p.x = Math.round(p.x / S.snap) * S.snap;
      p.y = Math.round(p.y / S.snap) * S.snap;
      p.z = Math.round(p.z / S.snap) * S.snap;
      setMarkerPos(dragging, p, { silent: true });
      refreshPanelValues();
    }
  } else if (mode_ready()) {
    renderer.domElement.style.cursor = pickMarker(e) ? 'grab' : '';
  }
});

window.addEventListener('pointerup', function (e) {
  if (dragging) {
    dragging = null;
    dragStart = null;
    controls.enabled = true;
    renderer.domElement.style.cursor = '';
    return;
  }
  // 视为点击（非旋转视角）：空白处取消选中
  if (downPos && Math.hypot(e.clientX - downPos[0], e.clientY - downPos[1]) < 4
      && e.target === renderer.domElement && !pickMarker(e)) {
    selectMarker(null);
  }
  downPos = null;
});

function mode_ready() { return S.mode && markerGroup.children.length > 0; }

// ---------------- 数据写入（轴 / JSON / 预览联动） ----------------
function setMarkerPos(key, pos, opts) {
  opts = opts || {};
  var p = new THREE.Vector3(r4(pos.x), r4(pos.y), r4(pos.z));
  setMarkerVisual(key, p);

  if (S.mode === 'wheel') {
    S.json.center = [p.x, p.y, p.z];
    if (spinPivot) { spinPivot.position.copy(p); }
  } else if (key.indexOf('width') === 0 && markers[key]) {
    // 车宽手柄：用基线做横向 delta（任意视角拖 x 只改宽）；无基线时取 |x| 兜底
    var base = (dragStart && dragStart.key === key) ? dragStart.bw + (p.x - dragStart.x) : Math.abs(p.x);
    setWidthFromX(base);
  } else if (key === 'front' || key === 'rear') {
    // 轴标记：x 恒 0；前后轴共用同一高度 y（拖任一，两轴 y 同步）
    var p2 = new THREE.Vector3(0, p.y, p.z);
    setMarkerVisual(key, p2);
    var ax = axleOf(key);
    ax.y = p2.y; ax.z = p2.z;
    var other = key === 'front' ? 'rear' : 'front';
    var ax2 = axleOf(other);
    ax2.y = p2.y;   // 高度强制一致
    var m2 = markers[other];
    if (m2) m2.group.position.y = p2.y;
    updateWheelPreview();
  }
  if (!opts.silent) renderPanel(false);
  scheduleSave();   // 数据变更 → 防抖自动保存
}

// ---------------- 工具模式（编辑前后轴 / 编辑车宽） ----------------
function setWidthFromX(rawX) {
  var bw = Math.max(MIN_BODY_WIDTH, r4(rawX));
  S.json.body_width = bw;
  updateWidthMarkers();
  updateWheelPreview();
  scheduleSave();
}

function updateWidthMarkers() {
  if (!markers.width_left) return;
  var y = S.json.front_axle.y;
  markers.width_left.group.position.set(-S.json.body_width, y, 0);
  markers.width_right.group.position.set(S.json.body_width, y, 0);
}

function syncWidthMarkers() {
  if (S.tool === 'width' && S.mode === 'body' && !markers.width_left) {
    makeMarker('width_left', '左宽', WIDTH_COLOR);
    makeMarker('width_right', '右宽', WIDTH_COLOR);
    refreshMarkerScale();
    updateWidthMarkers();
  } else if (S.tool !== 'width') {
    if (S.selected === 'width_left' || S.selected === 'width_right') S.selected = null;
    removeMarker('width_left');
    removeMarker('width_right');
  }
}

function setTool(tool) {
  if (S.mode !== 'body') tool = null;   // 轮毂模式恒 null
  if (tool === S.tool) tool = null;     // 点当前按钮 → 关闭
  S.tool = tool;
  syncWidthMarkers();
  syncSemiTires();
  syncToolUI();
  if (S.selected) selectMarker(S.selected);
}

function syncToolUI() {
  var bodyOn = S.mode === 'body';
  $('btnToolAxle').disabled = !bodyOn;
  $('btnToolWidth').disabled = !bodyOn;
  $('btnToolAxle').classList.toggle('active', S.tool === 'axle');
  $('btnToolWidth').classList.toggle('active', S.tool === 'width');
}

$('btnToolAxle').addEventListener('click', function () { setTool('axle'); });
$('btnToolWidth').addEventListener('click', function () { setTool('width'); });

// ---------------- 文件访问（FS API / 降级） ----------------
function relPath(parts) { return parts.join('/'); }

async function fsDirHandle(parts, create) {
  var dir = S.rootHandle;
  for (var i = 0; i < parts.length; i++) dir = await dir.getDirectoryHandle(parts[i], { create: !!create });
  return dir;
}

async function readFileText(path) {
  if (S.rootHandle) {
    var parts = path.split('/'); var name = parts.pop();
    try {
      var dir = await fsDirHandle(parts, false);
      var fh = await dir.getFileHandle(name);
      return await (await fh.getFile()).text();
    } catch (e) { return null; }
  }
  if (S.files) {
    var f = S.files.get(path);
    return f ? await f.text() : null;
  }
  return null;
}

async function readFileBuffer(path) {
  if (S.rootHandle) {
    var parts = path.split('/'); var name = parts.pop();
    try {
      var dir = await fsDirHandle(parts, false);
      var fh = await dir.getFileHandle(name);
      return await (await fh.getFile()).arrayBuffer();
    } catch (e) { return null; }
  }
  if (S.files) {
    var f = S.files.get(path);
    return f ? await f.arrayBuffer() : null;
  }
  return null;
}

async function listDir(kind) {
  // 返回 [{id, hasJson, hasModel}]
  var out = [];
  if (S.rootHandle) {
    try {
      var dir = await S.rootHandle.getDirectoryHandle(kind);
      for await (var entry of dir.values()) {
        if (entry.kind !== 'directory') continue;
        var hasModel = false, hasJson = false;
        for await (var f of entry.values()) {
          if (f.name.match(/\.glb$/i) || f.name.match(/\.gltf$/i)) hasModel = true;
          if (f.name === (kind === 'cars' ? 'body.json' : 'wheel.json')) hasJson = true;
        }
        out.push({ id: entry.name, hasJson: hasJson, hasModel: hasModel });
      }
    } catch (e) { /* 目录不存在 */ }
  } else if (S.files) {
    var seen = {};
    S.files.forEach(function (f, p) {
      var m = p.match(new RegExp('^' + kind + '/([^/]+)/(.+)$'));
      if (!m) return;
      var id = m[1];
      if (!seen[id]) { seen[id] = { id: id, hasJson: false, hasModel: false }; out.push(seen[id]); }
      if (m[2].match(/\.glb$/i) || m[2].match(/\.gltf$/i)) seen[id].hasModel = true;
      if (m[2] === (kind === 'cars' ? 'body.json' : 'wheel.json')) seen[id].hasJson = true;
    });
  }
  out.sort(function (a, b) { return a.id < b.id ? -1 : 1; });
  return out;
}

// 从配表读车辆清单（server.py 的 /api/cars）。车辆以配表为准，art/cars/ 只存资产；
// 读不到配表（直接 file:// 打开、无服务等）时返回 null，由调用方降级为目录扫描。
async function fetchConfigCars() {
  try {
    var r = await fetch('/api/cars');
    if (!r.ok) return null;
    var j = await r.json();
    if (!j || !Array.isArray(j.cars)) return null;
    return j.cars.map(function (c) {
      return { id: String(c.id), name: c.name || '' };
    });
  } catch (e) { return null; }
}

async function firstModelName(kind, id) {
  if (S.rootHandle) {
    try {
      var dir = await fsDirHandle([kind, id], false);
      for await (var f of dir.values()) {
        if (f.name.match(/\.glb$/i)) return f.name;
      }
    } catch (e) { /* ignore */ }
  } else if (S.files) {
    var names = [];
    S.files.forEach(function (fl, p) {
      var m = p.match(new RegExp('^' + kind + '/' + id + '/(.+\\.glb)$', 'i'));
      if (m) names.push(m[1]);
    });
    if (names.length) return names.sort()[0];
  }
  return null;
}

async function writeFile(path, text) {
  // 本地 HTTP 服务（server.py）：POST /api/save 真正写回 art/ 文件
  if (location.protocol.indexOf('http') === 0) {
    try {
      var r = await fetch('/api/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: path, text: text })
      });
      var j = await r.json();
      if (r.ok && j.ok) return true;
      if (j && j.error) setStatus('写回失败：' + j.error, 'err');
    } catch (e) { /* 降级下载 */ }
  }
  if (S.rootHandle && S.writable) {
    var parts = path.split('/'); var name = parts.pop();
    var dir = await fsDirHandle(parts, true);
    var fh = await dir.getFileHandle(name, { create: true });
    var w = await fh.createWritable();
    await w.write(text);
    await w.close();
    return true;
  }
  // 降级：下载 JSON
  var blob = new Blob([text], { type: 'application/json' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = path.split('/').pop();
  a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
  return false;
}

// ---------------- 打开目录 ----------------
$('btnOpen').addEventListener('click', async function () {
  if (typeof window.showDirectoryPicker === 'function') {
    try {
      var h = await window.showDirectoryPicker();
      S.rootHandle = h; S.files = null; S.writable = true;
      await afterOpen();
      return;
    } catch (e) {
      if (e && e.name === 'AbortError') return; // 用户取消
      // 其他异常（如非安全上下文）→ 降级
    }
  }
  $('dirInput').click();
});

$('dirInput').addEventListener('change', async function () {
  var files = Array.from(this.files || []);
  if (!files.length) return;
  var map = new Map();
  files.forEach(function (f) {
    var p = (f.webkitRelativePath || f.name).split('/');
    p.shift(); // 去掉根目录名（art/）
    map.set(p.join('/'), f);
  });
  S.files = map; S.rootHandle = null; S.writable = false;
  await afterOpen();
});

async function afterOpen() {
  var cfg = await fetchConfigCars();   // 所有模式都先试配表；失败返回 null
  S.cfgCars = cfg;
  var wheels = await listDir('wheels');
  var cars;
  if (cfg) {
    // 配表为车辆唯一清单，目录扫描仅用于标注每台车的资产状态
    var byId = {};
    var dirs = await listDir('cars');
    dirs.forEach(function (d) { byId[d.id] = d; });
    cars = cfg.map(function (c) {
      var d = byId[c.id] || { hasJson: false, hasModel: false };
      return { id: c.id, name: c.name, hasJson: d.hasJson, hasModel: d.hasModel };
    });
    cars.sort(function (a, b) { return (+a.id) - (+b.id); });
  } else {
    cars = await listDir('cars');   // 降级：纯目录扫描（旧行为）
  }
  S.cars = cars; S.wheels = wheels;
  S.mode = null; S.assetId = null; S.json = null;
  clearModel(); clearMarkers(); clearWheelPreview();
  renderAssetLists();
  var canWrite = S.writable ? '可直接写回' : '只读模式：保存将下载 JSON，请手动替换';
  var warn = [];
  if (!cars.length) warn.push(cfg ? '配表无车（或资产均缺）' : 'cars/ 为空');
  if (!wheels.length) warn.push('wheels/ 为空');
  if (!cfg) warn.push('配表不可用，已降级为目录扫描');
  setStatus(warn.length ? ('已打开目录（' + warn.join('，') + '）— ' + canWrite) : ('已打开目录 — ' + canWrite), 'ok');
}

// ---------------- HTTP 联调/自动加载模式 ----------------
// ?art=<base> 显式指定资产根；否则当页面由本地 HTTP 服务打开时，自动以 /art/ 为 base
// 加载资产（免手动选目录，只读，保存走下载）。双击 file:// 打开时无此能力，仍走「打开 art 目录」。
// manifest 由 make_placeholder_assets.py 生成。
async function loadHttpMode() {
  var q = new URLSearchParams(location.search).get('art');
  var base = q !== null ? q : (location.protocol.indexOf('http') === 0 ? '/art/' : null);
  if (!base) return;
  if (!base.endsWith('/')) base += '/';
  try {
    var r = await fetch(base + 'manifest.json');
    if (!r.ok) throw new Error('manifest.json 不可用');
    var manifest = await r.json();
    var map = new Map();
    for (var i = 0; i < (manifest.files || []).length; i++) {
      var p = manifest.files[i];
      var res = await fetch(base + p);
      if (!res.ok) continue;
      var body = p.indexOf('.json') >= 0 ? await res.text() : await res.arrayBuffer();
      map.set(p, new File([body], p.split('/').pop()));
    }
    S.files = map; S.rootHandle = null; S.writable = false;
    await afterOpen();
  } catch (e) {
    setStatus('HTTP 联调模式加载失败：' + (e && e.message || e), 'err');
  }
}
loadHttpMode();

// ---------------- GLB 加载 ----------------
var gltfLoader = new THREE.GLTFLoader();
var sceneCache = {}; // 'cars/xx' / 'wheels/xx' -> THREE.Object3D（原始场景，仅用于 clone）

function clearModel() {
  restoreMatVisuals();   // 还原材质自发光，避免污染 sceneCache 共享材质
  while (modelGroup.children.length) modelGroup.remove(modelGroup.children[0]);
  S.modelBBox = null;
  S.matList = []; S.matById = {}; S.matSel = null;
  clearSpinPreview();
}

// ---------------- 部件结构与材质标记 ----------------
// 遍历已加载模型：收集材质条目（uuid 归并同材质的多次引用），快照原始自发光用于还原。
function collectMaterials(root) {
  var byId = {}; var order = [];
  root.traverse(function (o) {
    if (!o.isMesh) return;
    var mats = Array.isArray(o.material) ? o.material : [o.material];
    mats.forEach(function (m) {
      if (!m) return;
      var e = byId[m.uuid];
      if (!e) {
        e = byId[m.uuid] = {
          id: m.uuid, mat: m, meshes: [],
          name: m.name || '未命名材质',
          colorHex: '#' + (m.color ? m.color.getHexString() : '888888'),
          baseEmissive: m.emissive ? m.emissive.getHex() : null,
          baseIntensity: m.emissiveIntensity != null ? m.emissiveIntensity : 1.0,
          // 预设材质实时预览需要还原的基线
          baseColor: m.color ? m.color.getHex() : 0xffffff,
          baseOpacity: m.opacity != null ? m.opacity : 1.0,
          baseTransparent: !!m.transparent,
          baseMetalness: m.isMeshStandardMaterial && m.metalness != null ? m.metalness : null,
          baseRoughness: m.isMeshStandardMaterial && m.roughness != null ? m.roughness : null
        };
        order.push(e);
      }
      if (e.meshes.indexOf(o) < 0) e.meshes.push(o);
    });
  });
  S.matList = order;
  S.matById = byId;
  S.matSel = null;
}

function slotOfMaterial(entry) {
  var m = (S.mode === 'body' && S.json) ? S.json.materials : null;
  if (!m) return null;
  for (var i = 0; i < MAT_SLOTS.length; i++) {
    if (m[MAT_SLOTS[i].key] === entry.name) return MAT_SLOTS[i].key;
  }
  return null;
}

// 该材质绑定的预设槽位（返回 { key, entry } 或 null）
function presetOfMaterial(matEntry) {
  var ps = (S.mode === 'body' && S.json) ? S.json.material_presets : null;
  if (!ps) return null;
  for (var i = 0; i < PRESET_SLOTS.length; i++) {
    var key = PRESET_SLOTS[i].key;
    if (ps[key] && ps[key].material === matEntry.name) return { key: key, entry: ps[key] };
  }
  return null;
}

// 视口反馈（优先级：选中高亮 > 预设材质实时预览 > 行为槽位标记色 > 原始状态）
function applyMatVisuals() {
  S.matList.forEach(function (e) {
    var m = e.mat;
    var preset = presetOfMaterial(e);
    var slot = slotOfMaterial(e);
    if (S.matSel === e.id) {
      _restoreBase(e, m);
      if (m.emissive) {
        m.emissive.setHex(slot ? matSlotColor(slot) : (preset ? presetSlotDef(preset.key).color : 0xffffff));
        m.emissiveIntensity = 0.65;
      }
    } else if (preset && m.isMeshStandardMaterial) {
      // 预设实时预览：颜色/透明度即时生效，金属度/粗糙度按预设风格
      var p = preset.entry.params || {};
      _restoreBase(e, m);
      if (m.emissive) { m.emissive.setHex(e.baseEmissive != null ? e.baseEmissive : 0x000000); m.emissiveIntensity = e.baseIntensity; }
      m.color.set(p.color || '#ffffff');
      var alpha = p.alpha != null ? +p.alpha : 1.0;
      m.transparent = alpha < 1.0;
      m.opacity = alpha;
      m.metalness = preset.key === 'paint' ? 0.85 : 0.6;
      m.roughness = preset.key === 'paint' ? 0.35 : 0.1;
    } else if (slot) {
      _restoreBase(e, m);
      if (m.emissive) {
        m.emissive.setHex(matSlotColor(slot));
        m.emissiveIntensity = 0.35;
      }
    } else {
      _restoreBase(e, m);
      if (m.emissive) { m.emissive.setHex(e.baseEmissive != null ? e.baseEmissive : 0x000000); m.emissiveIntensity = e.baseIntensity; }
    }
    if (m.isMeshStandardMaterial) m.needsUpdate = true;
  });
}

function _restoreBase(e, m) {
  if (m.color) m.color.setHex(e.baseColor);
  m.transparent = e.baseTransparent;
  m.opacity = e.baseOpacity;
  if (m.isMeshStandardMaterial) {
    if (e.baseMetalness != null) m.metalness = e.baseMetalness;
    if (e.baseRoughness != null) m.roughness = e.baseRoughness;
  }
}

function restoreMatVisuals() {
  (S.matList || []).forEach(function (e) {
    var m = e.mat;
    if (!m) return;
    _restoreBase(e, m);
    if (m.emissive) {
      m.emissive.setHex(e.baseEmissive != null ? e.baseEmissive : 0x000000);
      m.emissiveIntensity = e.baseIntensity;
    }
    if (m.isMeshStandardMaterial) m.needsUpdate = true;
  });
}

function selectMaterialEntry(id) {
  S.matSel = (S.matSel === id) ? null : id;
  applyMatVisuals();
  document.querySelectorAll('#right .mat-chip').forEach(function (el) {
    el.classList.toggle('sel', el.dataset.mat === S.matSel);
  });
}

// 槽位绑定：同一槽位仅一个材质；同一材质不重复占多个槽位
function setMaterialSlot(slotKey, matName) {
  if (S.mode !== 'body' || !S.json || !S.json.materials) return;
  var m = S.json.materials;
  m[slotKey] = null;
  if (matName) {
    MAT_SLOTS.forEach(function (s) { if (m[s.key] === matName) m[s.key] = null; });
    m[slotKey] = matName;
  }
  applyMatVisuals();
  renderPanel();
  scheduleSave();
}

function autoDetectSlots() {
  if (S.mode !== 'body' || !S.json) return;
  var m = S.json.materials;
  MAT_SLOTS.forEach(function (s) { m[s.key] = null; });
  var used = {};
  MAT_AUTORULES.forEach(function (r) {
    for (var i = 0; i < S.matList.length; i++) {
      var e = S.matList[i];
      if (used[e.id] || !r[1].test(e.name)) continue;
      m[r[0]] = e.name;
      used[e.id] = true;
      break;
    }
  });
  // 预设材质球同样按名称识别（未被行为槽占用的材质里找）
  var ps = S.json.material_presets;
  PRESET_SLOTS.forEach(function (s) { ps[s.key] = null; });
  PRESET_AUTORULES.forEach(function (r) {
    for (var i = 0; i < S.matList.length; i++) {
      var e2 = S.matList[i];
      if (used[e2.id] || !r[1].test(e2.name)) continue;
      ps[r[0]] = { material: e2.name, params: JSON.parse(JSON.stringify(PRESET_DEFAULT_PARAMS[r[0]])) };
      used[e2.id] = true;
      break;
    }
  });
  applyMatVisuals();
  renderPanel();
  scheduleSave();
}

// 预设槽位绑定：同一预设仅一个材质；同一材质不重复占多个预设（与行为槽互不占用）
function setPresetSlot(slotKey, matName) {
  if (S.mode !== 'body' || !S.json || !S.json.material_presets) return;
  var ps = S.json.material_presets;
  ps[slotKey] = null;
  if (matName) {
    PRESET_SLOTS.forEach(function (s) { if (ps[s.key] && ps[s.key].material === matName) ps[s.key] = null; });
    ps[slotKey] = { material: matName, params: JSON.parse(JSON.stringify(PRESET_DEFAULT_PARAMS[slotKey])) };
  }
  applyMatVisuals();
  renderPanel();
  scheduleSave();
}

// 调整预设暴露的参数（颜色/透明度等），视口实时预览
function setPresetParam(slotKey, paramKey, value) {
  var ps = (S.json && S.json.material_presets) || null;
  if (!ps || !ps[slotKey]) return;
  ps[slotKey].params[paramKey] = value;
  applyMatVisuals();
  scheduleSave();
}

function loadGLB(kind, id, preferredName) {
  return new Promise(async function (resolve, reject) {
    var cacheKey = kind + '/' + id + '/' + (preferredName || '');
    if (sceneCache[cacheKey]) return resolve(sceneCache[cacheKey].clone(true));
    var name = preferredName;
    if (!name) name = await firstModelName(kind, id);
    if (!name) return reject(new Error('未找到模型文件（.glb）'));
    var buf = await readFileBuffer(relPath([kind, id, name]));
    if (!buf) return reject(new Error('读取模型失败：' + name));
    gltfLoader.parse(buf, '', function (gltf) {
      sceneCache[cacheKey] = gltf.scene;
      resolve(gltf.scene.clone(true));
    }, function (err) {
      reject(new Error('模型解析失败（建议使用单文件 .glb）：' + (err && err.message || err)));
    });
  });
}

function fitView() {
  var box = new THREE.Box3();
  var has = false;
  [modelGroup, markerGroup, previewGroup].forEach(function (g) {
    g.traverse(function (o) {
      if (o.isMesh && o.visible !== false) {
        o.updateWorldMatrix(true, false);
        box.expandByObject(o); has = true;
      }
    });
  });
  if (!has) box.set(new THREE.Vector3(-1, 0, -1), new THREE.Vector3(1, 1, 1));
  var center = box.getCenter(new THREE.Vector3());
  var size = box.getSize(new THREE.Vector3());
  var radius = Math.max(size.length() * 0.5, 0.5);
  var dist = radius / Math.tan(THREE.MathUtils.degToRad(camera.fov * 0.5)) * 1.5;
  var dir = new THREE.Vector3(1.1, 0.75, 1.6).normalize();
  camera.position.copy(center).add(dir.multiplyScalar(dist));
  controls.target.copy(center);
  controls.update();
}
$('btnFit').addEventListener('click', fitView);

// ---------------- 资产选择与编辑 ----------------
function renderAssetLists() {
  function fill(ul, items, kind) {
    ul.innerHTML = '';
    if (!items.length) {
      var li = document.createElement('li');
      li.className = 'empty'; li.textContent = '（空）';
      ul.appendChild(li); return;
    }
    items.forEach(function (it) {
      var li = document.createElement('li');
      li.innerHTML = '<span>' + it.id + (it.name ? ' · ' + it.name : '') + '</span><span class="tag">' +
        (it.hasModel ? (it.hasJson ? '已定义' : '未定义') : '缺模型') + '</span>';
      li.addEventListener('click', function () { selectAsset(kind, it.id); });
      li.dataset.id = it.id; li.dataset.kind = kind;
      ul.appendChild(li);
    });
  }
  fill($('listCars'), S.cars, 'cars');
  fill($('listWheels'), S.wheels, 'wheels');
  markActiveInList();
}

function markActiveInList() {
  document.querySelectorAll('#left .sec li[data-id]').forEach(function (li) {
    li.classList.toggle('active', li.dataset.kind === (S.mode === 'body' ? 'cars' : 'wheels') && li.dataset.id === S.assetId);
  });
}

async function loadMeta(kind, id) {
  var jsonName = kind === 'cars' ? 'body.json' : 'wheel.json';
  var text = await readFileText(relPath([kind, id, jsonName]));
  var j = {};
  if (text) {
    try { j = JSON.parse(text); } catch (e) { setStatus('JSON 解析失败，将按默认值编辑：' + jsonName, 'err'); }
  }
  if (kind === 'cars') {
    j.version = 2;
    j.id = id;
    j.name = j.name || '';
    j.model = j.model || '';
    delete j.wheel_positions;   // 旧 v1 字段清理，避免漏回写
    j.body_width = j.body_width != null ? r4(+j.body_width) : DEFAULT_BODY_WIDTH;
    var mats = j.materials || {};
    j.materials = {
      headlight: mats.headlight || null,
      brake_light: mats.brake_light || null,
      body: mats.body || null
    };
    var ps = j.material_presets || {};
    var psOut = {};
    PRESET_SLOTS.forEach(function (s) {
      var e = ps[s.key];
      if (!(e && typeof e === 'object')) { psOut[s.key] = null; return; }
      // 参数按当前槽位定义过滤（旧版遗留键如 flake_amount 直接丢弃），缺失补默认值
      var allowed = {};
      s.params.forEach(function (p) { allowed[p.key] = true; });
      var merged = Object.assign({}, PRESET_DEFAULT_PARAMS[s.key]);
      var src = e.params || {};
      Object.keys(src).forEach(function (k) { if (allowed[k]) merged[k] = src[k]; });
      psOut[s.key] = { material: e.material || null, params: merged };
    });
    j.material_presets = psOut;
    AXLES.forEach(function (k) {
      var ax = j[k + '_axle'] || {};
      j[k + '_axle'] = {
        y: r4(ax.y != null ? +ax.y : AXLE_DEFAULT[k].y),
        z: r4(ax.z != null ? +ax.z : AXLE_DEFAULT[k].z)
      };
    });
  } else {
    j.version = j.version || 1;
    j.id = id;
    j.name = j.name || '';
    j.model = j.model || '';
    var c = j.center || [0, 0, 0];
    j.center = [r4(+c[0]), r4(+c[1]), r4(+c[2])];
    j.radius = j.radius != null ? r4(+j.radius) : 0.3;
    j.width = j.width != null ? r4(+j.width) : 0.2;
  }
  return j;
}

async function selectAsset(kind, id) {
  clearModel(); clearMarkers(); clearWheelPreview();
  S.mode = kind === 'cars' ? 'body' : 'wheel';
  S.assetId = id;
  S.json = await loadMeta(kind, id);
  setTool(DEFAULT_TOOL);   // 切资产重置工具（轮毂模式自动置 null）
  markActiveInList();

  var modelName = S.json.model || await firstModelName(kind, id);
  var hadModel = false;
  try {
    var obj = await loadGLB(kind, id, modelName);
    modelGroup.add(obj);
    S.modelBBox = new THREE.Box3().setFromObject(obj);
    if (S.modelBBox.isEmpty()) S.modelBBox = null;
    collectMaterials(obj);
    applyMatVisuals();   // 已有槽位绑定的材质恢复常显标记色
    hadModel = true;
  } catch (e) {
    setStatus(e.message + '（可先在空场景中定义，后续补模型）', 'err');
  }
  if (!S.json.model && modelName) S.json.model = modelName;

  if (S.mode === 'wheel') {
    makeMarker('center', '中心', 0x3ecf8e);
    setMarkerVisual('center', new THREE.Vector3().fromArray(S.json.center));
  } else {
    AXLES.forEach(function (k) {
      var a = axleOf(k);
      makeMarker(k, AXLE_LABEL[k], AXLE_COLOR[k]);
      setMarkerVisual(k, new THREE.Vector3(0, a.y, a.z));
    });
    await rebuildPreviewWheelList();
    if (previewWheelId) await setPreviewWheel(previewWheelId);
  }
  refreshMarkerScale();
  selectMarker(S.mode === 'wheel' ? 'center' : 'front');
  renderPanel();
  fitView();
  $('previewSec').style.display = S.mode === 'body' ? '' : 'none';
  $('btnSave').disabled = false;
  if (hadModel) setStatus('编辑：' + (S.mode === 'body' ? '车壳 ' : '轮毂 ') + id + '（拖拽标记或用右侧数值面板）', 'ok');
}

// ---------------- 轮毂缓存（供车壳预览） ----------------
async function getWheelAsset(id) {
  if (S.wheelCache[id]) return S.wheelCache[id];
  var json = await loadMeta('wheels', id);
  var scene = null;
  try { scene = await loadGLB('wheels', id, json.model); } catch (e) { scene = null; }
  S.wheelCache[id] = { json: json, scene: scene };
  return S.wheelCache[id];
}

// ---------------- 车壳模式：轮毂装配预览 ----------------
var previewSlots = {}; // key -> {group(轮位+转向), spin, wheelRoot}
var previewWheelId = '';

function clearWheelPreview() {
  while (previewGroup.children.length) previewGroup.remove(previewGroup.children[0]);
  previewSlots = {};
}

async function rebuildPreviewWheelList() {
  var sel = $('selPreviewWheel');
  sel.innerHTML = '';
  var optNone = document.createElement('option');
  optNone.value = ''; optNone.textContent = '（不预览轮毂）';
  sel.appendChild(optNone);
  S.wheels.forEach(function (w) {
    var o = document.createElement('option');
    o.value = w.id; o.textContent = w.id + (w.hasModel ? '' : '（缺模型）');
    sel.appendChild(o);
  });
  sel.value = previewWheelId;
}

async function setPreviewWheel(id) {
  previewWheelId = id;
  clearWheelPreview();
  if (S.mode !== 'body' || !id) return;
  var asset = await getWheelAsset(id);
  if (!asset.scene) { setStatus('轮毂 ' + id + ' 模型缺失，仅显示标记点', 'err'); return; }
  S.previewWheelWidth = asset.json.width != null ? asset.json.width : DEFAULT_WHEEL_WIDTH;
  S.previewWheelRadius = asset.json.radius != null ? asset.json.radius : 0.3;
  WHEEL_SLOT_KEYS.forEach(function (k) {
    var g = new THREE.Group();                    // 轮位 + 转向
    var spin = new THREE.Group();                 // 自转
    var wheelRoot = asset.scene.clone(true);      // 轮毂模型，偏移 -center 使中心点落在轮位
    var c = new THREE.Vector3().fromArray(asset.json.center || [0, 0, 0]);
    wheelRoot.position.copy(c.clone().negate());
    spin.add(wheelRoot); g.add(spin); previewGroup.add(g);
    previewSlots[k] = { group: g, spin: spin, wheelRoot: wheelRoot };
  });
  updateWheelPreview();
}

function updateWheelPreview() {
  if (S.mode !== 'body') return;
  var steer = THREE.MathUtils.degToRad(S.steerDeg);
  var bw = S.json.body_width, w = S.previewWheelWidth || DEFAULT_WHEEL_WIDTH;
  var lx = -wheelX(bw, w), rx = wheelX(bw, w);
  WHEEL_SLOT_KEYS.forEach(function (k) {
    var slot = previewSlots[k];
    if (!slot || !S.json) return;
    var a = axleOf(k.indexOf('front') === 0 ? 'front' : 'rear');
    slot.group.position.set(k.indexOf('left') >= 0 ? lx : rx, a.y, a.z);
    slot.group.rotation.y = (k.indexOf('front') === 0) ? steer : 0;
  });
  positionSemiTires();
}

// ---------------- 半透明轮胎（工具编辑时可视化齐边推导结果） ----------------
function positionSemiTires() {
  if (!semiGroup.visible) return;
  var bw = S.json.body_width, w = S.previewWheelWidth || DEFAULT_WHEEL_WIDTH;
  var r = S.previewWheelRadius || 0.3;
  var lx = -wheelX(bw, w), rx = wheelX(bw, w);
  WHEEL_SLOT_KEYS.forEach(function (k) {
    var m = semiTires[k];
    var a = axleOf(k.indexOf('front') === 0 ? 'front' : 'rear');
    m.position.set(k.indexOf('left') >= 0 ? lx : rx, a.y, a.z);
    m.scale.set(r / 0.3, w / 0.2, r / 0.3);   // y 向=厚度（轴沿 X 后）
  });
}

function syncSemiTires() {
  semiGroup.visible = !!(S.tool && S.mode === 'body');
  if (semiGroup.visible) positionSemiTires();
}

$('selPreviewWheel').addEventListener('change', function () { setPreviewWheel(this.value); });
$('chkSteer').addEventListener('change', function () { $('rngSteer').style.display = this.checked ? '' : 'none'; });
$('rngSteer').addEventListener('input', function () { S.steerDeg = +this.value; updateWheelPreview(); });
$('chkSpin').addEventListener('change', function () { S.previewSpin = this.checked; });

// ---------------- 轮毂模式：绕中心自转预览 ----------------
function clearSpinPreview() {
  if (spinPivot) { scene.remove(spinPivot); spinPivot = null; }
  modelGroup.visible = true;
}

function setSpinPreview(on) {
  clearSpinPreview();
  if (!on || S.mode !== 'wheel' || !modelGroup.children.length) return;
  modelGroup.visible = false;
  spinPivot = new THREE.Group();
  var clone = modelGroup.children[0].clone(true);
  var c = new THREE.Vector3().fromArray(S.json ? S.json.center : [0, 0, 0]);
  clone.position.copy(c.clone().negate());
  spinPivot.add(clone);
  spinPivot.position.copy(c);
  scene.add(spinPivot);
}

// ---------------- 右侧属性面板 ----------------
function vec3Row(label, values, onInput, key) {
  var div = document.createElement('div');
  div.className = 'row3';
  var s = document.createElement('span'); s.textContent = label; div.appendChild(s);
  ['x', 'y', 'z'].forEach(function (axis, i) {
    var inp = document.createElement('input');
    inp.type = 'number'; inp.step = '0.01';
    inp.value = fmt(values[i]);
    inp.addEventListener('input', function () {
      var xs = +div.children[1].value, ys = +div.children[2].value, zs = +div.children[3].value;
      if (!isFinite(xs) || !isFinite(ys) || !isFinite(zs)) return;
      onInput(xs, ys, zs);
    });
    div.appendChild(inp);
  });
  return div;
}

function axleRow(axleKey, onInput) {
  var ax = axleOf(axleKey);
  var div = document.createElement('div');
  div.className = 'row2'; div.dataset.axle = axleKey;
  var s = document.createElement('span'); s.textContent = AXLE_LABEL[axleKey]; div.appendChild(s);
  ['y', 'z'].forEach(function (axis, i) {
    var inp = document.createElement('input');
    inp.type = 'number'; inp.step = '0.01';
    inp.value = fmt(ax[axis]);
    inp.addEventListener('input', function () {
      var yy = +div.children[1].value, zz = +div.children[2].value;
      if (!isFinite(yy) || !isFinite(zz)) return;
      onInput(yy, zz);
    });
    div.appendChild(inp);
  });
  return div;
}

function fieldInput(label, value, onInput, type) {
  var div = document.createElement('div');
  div.className = 'field';
  var l = document.createElement('label'); l.textContent = label; div.appendChild(l);
  var inp = document.createElement('input');
  inp.type = type || 'text';
  inp.value = value;
  inp.addEventListener('input', function () { onInput(type === 'number' ? +inp.value : inp.value); });
  div.appendChild(inp);
  return div;
}

// ---------------- 部件与材质面板 ----------------
function buildNodeTree(container) {
  modelGroup.children.forEach(function (root) { addTreeNode(container, root, 0); });
}

function addTreeNode(container, o, depth) {
  var row = document.createElement('div');
  row.className = 'tree-node';
  row.style.paddingLeft = (depth * 12 + 2) + 'px';
  row.textContent = (o.isMesh ? '▦ ' : '· ') + (o.name || o.type);
  container.appendChild(row);
  if (o.isMesh) {
    var mats = Array.isArray(o.material) ? o.material : [o.material];
    mats.forEach(function (m) {
      if (!m) return;
      var e = S.matById[m.uuid];
      var chip = document.createElement('div');
      chip.className = 'mat-chip' + (e && S.matSel === e.id ? ' sel' : '');
      chip.dataset.mat = m.uuid;
      chip.style.marginLeft = ((depth + 1) * 12 + 2) + 'px';
      var sw = document.createElement('span');
      sw.className = 'sw';
      sw.style.background = e ? e.colorHex : '#666';
      chip.appendChild(sw);
      var nm = document.createElement('span');
      nm.className = 'mat-name';
      nm.textContent = e ? e.name : '（未知材质）';
      chip.appendChild(nm);
      if (e) {
        var slot = slotOfMaterial(e);
        if (slot) {
          var b = document.createElement('span');
          b.className = 'slot-badge';
          b.textContent = matSlotDef(slot).label;
          b.style.background = matSlotCss(slot);
          chip.appendChild(b);
        }
        var preset = presetOfMaterial(e);
        if (preset) {
          var b2 = document.createElement('span');
          b2.className = 'slot-badge';
          b2.textContent = presetSlotDef(preset.key).label;
          b2.style.background = presetSlotCss(preset.key);
          chip.appendChild(b2);
        }
        chip.addEventListener('click', function (ev) { ev.stopPropagation(); selectMaterialEntry(e.id); });
      }
      container.appendChild(chip);
    });
  }
  var kids = o.children || [];
  for (var i = 0; i < kids.length; i++) addTreeNode(container, kids[i], depth + 1);
}

function renderMatSection(panel) {
  var sec = document.createElement('div');
  sec.className = 'sec';
  var h = document.createElement('h3'); h.textContent = '部件与材质'; sec.appendChild(h);

  if (!S.matList.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = S.modelBBox ? '模型内未发现材质' : '（未加载模型）';
    sec.appendChild(empty);
    panel.appendChild(sec);
    return;
  }

  var tree = document.createElement('div');
  tree.className = 'mat-tree';
  buildNodeTree(tree);
  sec.appendChild(tree);

  if (S.mode === 'body') {
    var divider = document.createElement('div'); divider.className = 'divider'; divider.style.margin = '10px 0'; sec.appendChild(divider);

    MAT_SLOTS.forEach(function (s) {
      sec.appendChild(matSlotRow(s));
    });

    // 预设材质球：标记类型 + 调整该预设对外暴露的参数（颜色/透明度等），视口实时预览
    var divider2 = document.createElement('div'); divider2.className = 'divider'; divider2.style.margin = '10px 0'; sec.appendChild(divider2);
    var ph = document.createElement('div'); ph.className = 'field-label'; ph.textContent = '预设材质（引擎效果）'; sec.appendChild(ph);

    PRESET_SLOTS.forEach(function (s) {
      sec.appendChild(presetSlotRow(s));
    });

    var btn = document.createElement('button');
    btn.textContent = '按名称自动识别';
    btn.style.width = '100%'; btn.style.marginTop = '6px';
    btn.addEventListener('click', autoDetectSlots);
    sec.appendChild(btn);

    var hint = document.createElement('div');
    hint.className = 'hint';
    hint.textContent = '点击材质条目可在视口高亮；刹车时「刹车灯」点亮。预设材质在游戏内替换为社区效果材质（车漆/玻璃），颜色与透明度实时预览并写入 JSON。';
    sec.appendChild(hint);
  }
  panel.appendChild(sec);
}

function matSlotRow(s) {
  var row = document.createElement('div');
  row.className = 'mat-slot';
  var sw = document.createElement('span');
  sw.className = 'sw slot-sw';
  sw.style.background = matSlotCss(s.key);
  row.appendChild(sw);
  row.appendChild(buildMaterialSelect(s.key, S.json.materials[s.key] || '', function (name) {
    setMaterialSlot(s.key, name || null);
  }));
  return row;
}

function presetSlotRow(s) {
  var wrap = document.createElement('div');
  wrap.className = 'preset-wrap';
  var entry = S.json.material_presets[s.key];

  var row = document.createElement('div');
  row.className = 'mat-slot';
  var sw = document.createElement('span');
  sw.className = 'sw slot-sw';
  sw.style.background = presetSlotCss(s.key);
  row.appendChild(sw);
  row.appendChild(buildMaterialSelect(s.key, entry && entry.material || '', function (name) {
    setPresetSlot(s.key, name || null);
  }));
  wrap.appendChild(row);

  // 已绑定 → 展示该预设暴露的参数（拖动即时预览 + 防抖保存，不重建 DOM）
  if (entry && entry.material) {
    s.params.forEach(function (pd) {
      var prow = document.createElement('div');
      prow.className = 'preset-param';
      var l = document.createElement('label'); l.textContent = pd.label; prow.appendChild(l);
      if (pd.type === 'color') {
        var inp = document.createElement('input');
        inp.type = 'color';
        inp.value = entry.params[pd.key] || '#ffffff';
        inp.addEventListener('input', function () { setPresetParam(s.key, pd.key, inp.value); });
        prow.appendChild(inp);
      } else {
        var rng = document.createElement('input');
        rng.type = 'range'; rng.min = '0'; rng.max = '1'; rng.step = '0.05';
        rng.value = entry.params[pd.key];
        var val = document.createElement('span'); val.className = 'param-val';
        val.textContent = (+rng.value).toFixed(2);
        rng.addEventListener('input', function () {
          val.textContent = (+rng.value).toFixed(2);
          setPresetParam(s.key, pd.key, +rng.value);
        });
        prow.appendChild(rng); prow.appendChild(val);
      }
      wrap.appendChild(prow);
    });
  }
  return wrap;
}

// 材质下拉（三个行为槽 / 三个预设槽共用）：列出当前模型材质 + 缺失值保留明示
function buildMaterialSelect(slotKey, current, onChange) {
  var sel = document.createElement('select');
  var optNone = document.createElement('option');
  optNone.value = ''; optNone.textContent = '（未标记）';
  sel.appendChild(optNone);
  var seen = { '': true };
  var curExists = false;
  S.matList.forEach(function (e) {
    if (seen[e.name]) return;
    seen[e.name] = true;
    var o = document.createElement('option');
    o.value = e.name; o.textContent = e.name;
    sel.appendChild(o);
    if (e.name === current) curExists = true;
  });
  if (current && !curExists) {
    var o2 = document.createElement('option');
    o2.value = current; o2.textContent = current + '（模型中缺失）';
    sel.appendChild(o2);
  }
  sel.value = current;
  sel.addEventListener('change', function () { onChange(sel.value || null); });
  return sel;
}

function renderPanel(rebuildAll) {
  var panel = $('right');
  panel.innerHTML = '';
  if (!S.json) {
    var p = document.createElement('div');
    p.className = 'hint';
    p.textContent = '从左侧选择车壳或轮毂开始编辑。标记点可拖拽，也可在此输入精确数值。';
    panel.appendChild(p);
    return;
  }

  var title = document.createElement('div');
  title.className = 'sec';
  title.innerHTML = '<h3>' + (S.mode === 'body' ? '车壳' : '轮毂') + ' · ' + S.assetId + '</h3>';
  panel.appendChild(title);

  panel.appendChild(fieldInput('名称 name', S.json.name || '', function (v) { S.json.name = v; scheduleSave(); }));
  panel.appendChild(fieldInput('模型 model', S.json.model || '', function (v) { S.json.model = v; scheduleSave(); }));

  var divider = document.createElement('div'); divider.className = 'divider'; panel.appendChild(divider);

  if (S.mode === 'wheel') {
    var h = document.createElement('div'); h.className = 'sec'; h.innerHTML = '<h3>轮毂中心点</h3>'; panel.appendChild(h);
    panel.appendChild(vec3Row('center', S.json.center, function (x, y, z) {
      setMarkerPos('center', new THREE.Vector3(x, y, z), { silent: true, noMirror: true });
      refreshPanelValues();
    }));
    panel.appendChild(fieldInput('半径 radius', S.json.radius, function (v) { S.json.radius = r4(v); scheduleSave(); }, 'number'));
    panel.appendChild(fieldInput('宽度 width', S.json.width, function (v) { S.json.width = r4(v); scheduleSave(); }, 'number'));

    var btnCenter = document.createElement('button');
    btnCenter.textContent = '吸附到包围盒中心';
    btnCenter.style.width = '100%'; btnCenter.style.marginTop = '6px';
    btnCenter.disabled = !S.modelBBox;
    btnCenter.addEventListener('click', function () {
      var c = S.modelBBox.getCenter(new THREE.Vector3());
      setMarkerPos('center', c);
    });
    panel.appendChild(btnCenter);

    var chkSpin = document.createElement('label');
    chkSpin.className = 'chk'; chkSpin.style.marginTop = '10px';
    chkSpin.innerHTML = '<input type="checkbox"> 绕中心自转预览（验证中心是否为轮轴心）';
    chkSpin.querySelector('input').addEventListener('change', function () { setSpinPreview(this.checked); });
    panel.appendChild(chkSpin);

    var hint = document.createElement('div');
    hint.className = 'hint';
    hint.textContent = '中心点 = 轮轴穿过轮心的位置，运行时与车壳轮位对齐，旋转围绕它进行。';
    panel.appendChild(hint);
  } else {
    var h2 = document.createElement('div'); h2.className = 'sec'; h2.innerHTML = '<h3>前后轴 + 半宽</h3>'; panel.appendChild(h2);

    var bwInp = fieldInput('半宽 body_width', S.json.body_width, function (v) {
      S.json.body_width = r4(Math.max(MIN_BODY_WIDTH, +v || 0));
      updateWidthMarkers();
      updateWheelPreview();
      scheduleSave();
    }, 'number');
    bwInp.querySelector('input').dataset.bw = '1';
    panel.appendChild(bwInp);

    AXLES.forEach(function (k) {
      var row = axleRow(k, function (y, z) {
        setMarkerPos(k, new THREE.Vector3(0, y, z), { silent: true });
        refreshPanelValues();
      });
      row.style.cursor = 'pointer';
      row.addEventListener('click', function (e) { if (e.target.tagName !== 'INPUT') selectMarker(k); });
      panel.appendChild(row);
    });

    var hint2 = document.createElement('div');
    hint2.className = 'hint';
    hint2.textContent = '轴标记可拖拽（x 恒 0）或数值输入 y/z；body_width 为车体最宽处半宽，四轮按所选轮毂 width 齐边推导（x = ±(body_width − width/2)）。';
    panel.appendChild(hint2);
  }

  renderMatSection(panel);
}

function refreshPanelValues() {
  // 拖拽后同步面板数值，不重建 DOM（避免输入焦点丢失）
  document.querySelectorAll('#right .row2, #right .row3').forEach(function (row) {
    var inputs = row.querySelectorAll('input');
    if (row.dataset.axle) {
      // 车壳：轴行只刷 y/z
      var ax = S.json[row.dataset.axle + '_axle'];
      if (!ax) return;
      ['y', 'z'].forEach(function (axis, i) {
        if (document.activeElement !== inputs[i]) inputs[i].value = fmt(ax[axis]);
      });
    } else {
      // 轮毂：center 行刷 x/y/z
      var v = S.json.center;
      if (!v) return;
      ['x', 'y', 'z'].forEach(function (_, i) {
        if (document.activeElement !== inputs[i]) inputs[i].value = fmt(v[i]);
      });
    }
  });
  // body_width 数值框同步（拖车宽手柄时实时刷新）
  var bwInp = document.querySelector('#right input[data-bw]');
  if (bwInp && document.activeElement !== bwInp) bwInp.value = fmt(S.json.body_width);
}

// ---------------- 自动保存（防抖写回 body.json / wheel.json） ----------------
var saveTimer = null;
var saving = false;
var pendingSave = null;   // {path, text} 快照，保证切换资产后仍保存正确文件

function scheduleSave() {
  if (!S.json || !S.assetId) return;
  var path = S.mode === 'body' ? relPath(['cars', S.assetId, 'body.json']) : relPath(['wheels', S.assetId, 'wheel.json']);
  var text = JSON.stringify(orderedJson(), null, 2) + '\n';
  pendingSave = { path: path, text: text };
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, 400);
}

async function flushSave() {
  saveTimer = null;
  if (!pendingSave || saving) return;
  saving = true;
  var job = pendingSave; pendingSave = null;
  try {
    var wrote = await writeFile(job.path, job.text);
    if (wrote) {
      setStatus('已自动保存 ' + job.path, 'ok');
    } else {
      setStatus('已生成 ' + job.path.split('/').pop() + '（只读，请手动放入 ' + job.path.replace(/\/[^/]+$/, '') + '）', 'ok');
    }
  } catch (e) {
    setStatus('自动保存失败：' + (e && e.message || e), 'err');
  } finally {
    saving = false;
  }
}

function orderedJson() {
  var j = S.json;
  if (S.mode === 'wheel') {
    var out = {
      version: j.version, id: j.id, name: j.name || '', model: j.model || 'wheel.glb',
      center: j.center.slice(), radius: j.radius, width: j.width
    };
    Object.keys(j).forEach(function (k) { if (!(k in out)) out[k] = j[k]; });
    return out;
  }
  var out2 = {
    version: 2, id: j.id, name: j.name || '', model: j.model || 'body.glb',
    body_width: j.body_width,
    front_axle: { y: j.front_axle.y, z: j.front_axle.z },
    rear_axle: { y: j.rear_axle.y, z: j.rear_axle.z },
    materials: { headlight: j.materials.headlight, brake_light: j.materials.brake_light, body: j.materials.body },
    material_presets: {
      paint: j.material_presets.paint ? JSON.parse(JSON.stringify(j.material_presets.paint)) : null,
      headlight_lens: j.material_presets.headlight_lens ? JSON.parse(JSON.stringify(j.material_presets.headlight_lens)) : null,
      glass: j.material_presets.glass ? JSON.parse(JSON.stringify(j.material_presets.glass)) : null
    }
  };
  Object.keys(j).forEach(function (k) { if (!(k in out2)) out2[k] = j[k]; }); // anchors 等扩展字段原样保留
  return out2;
}

$('btnSave').addEventListener('click', flushSave);   // 手动按钮 = 立即保存

// ---------------- 渲染循环 ----------------
var lastT = performance.now();
function animate(t) {
  requestAnimationFrame(animate);
  var dt = Math.min((t - lastT) / 1000, 0.05); lastT = t;
  if (spinPivot) spinPivot.rotation.x += dt * 2.2;
  if (S.previewSpin) {
    WHEEL_SLOT_KEYS.forEach(function (k) {
      var slot = previewSlots[k];
      if (slot) slot.spin.rotation.x += dt * 3.0;
    });
  }
  controls.update();
  renderer.render(scene, camera);
  labelRenderer.render(scene, camera);
}
// ---------------- 调试 / 自动化测试钩子 ----------------
// 不经目录选择器注入虚拟文件系统：{ 路径: ArrayBuffer | string }
// window.__artEditor.injectFiles({'cars/x/body.glb': buf, 'cars/x/body.json': '...'})
window.__artEditor = {
  injectFiles: async function (files) {
    var map = new Map();
    Object.keys(files).forEach(function (p) {
      map.set(p, new File([files[p]], p.split('/').pop()));
    });
    S.files = map; S.rootHandle = null; S.writable = false;
    await afterOpen();
  },
  state: S,
  selectAsset: selectAsset,
  setMarkerPos: setMarkerPos,
  setPreviewWheel: setPreviewWheel,
  setMaterialSlot: setMaterialSlot,
  autoDetectSlots: autoDetectSlots,
  orderedJson: function () { return orderedJson(); },
  status: function () { return statusEl.textContent; }
};

requestAnimationFrame(animate);

renderPanel();
})();
