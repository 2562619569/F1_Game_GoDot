/* ModRacer 美术资源编辑器
 * 车壳（cars/<id>/body.json，四个轮位）与轮毂（wheels/<id>/wheel.json，中心点）的
 * 可视化定义工具。写回依赖 File System Access API；不支持时降级为「读取目录 + 下载 JSON」。
 * 坐标约定与 docs/美术资源与车辆结构.md 一致：GLB 场景根空间、米、Y-up、车头朝 -Z。
 */
(function () {
'use strict';

// ---------------- 常量与状态 ----------------
var BODY_KEYS = ['front_left', 'front_right', 'rear_left', 'rear_right'];
var BODY_LABEL = { front_left: '前左 FL', front_right: '前右 FR', rear_left: '后左 RL', rear_right: '后右 RR' };
var BODY_COLOR = { front_left: 0x37c8ff, front_right: 0xff5fd0, rear_left: 0xffd23e, rear_right: 0xff8a3c };
var PAIR = { front_left: 'front_right', front_right: 'front_left', rear_left: 'rear_right', rear_right: 'rear_left' };
var BODY_DEFAULT_POS = { front_left: [-0.5, 0.35, -0.66], front_right: [0.5, 0.35, -0.66], rear_left: [-0.5, 0.35, 0.66], rear_right: [0.5, 0.35, 0.66] };

var S = {
  rootHandle: null,      // FileSystemDirectoryHandle（art/ 根）
  files: null,           // Map<相对路径, File>（降级模式）
  writable: false,
  cars: [], wheels: [],
  mode: null,            // 'body' | 'wheel'
  assetId: null,
  json: null,            // 当前资产元数据（编辑中）
  selected: null,        // 选中的标记 key
  mirrorX: true,
  snap: 0.01,
  steerDeg: 0,
  modelBBox: null,
  wheelCache: {}         // 轮毂 id -> {json, scene}
};

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
function clearMarkers() {
  Object.keys(markers).forEach(function (k) {
    // r147 CSS2DRenderer 不随对象移除清理 DOM，需手动摘除标签元素
    markers[k].group.traverse(function (o) {
      if (o.isCSS2DObject && o.element && o.element.parentNode) {
        o.element.parentNode.removeChild(o.element);
      }
    });
    markerGroup.remove(markers[k].group);
  });
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
    new THREE.MeshBasicMaterial({ color: color })
  );
  sphere.scale.setScalar(0.28 * s);
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
    markers[k].sphere.material.color.setHex(on ? 0xffffff : (S.mode === 'wheel' ? 0x3ecf8e : BODY_COLOR[k]));
    markers[k].group.scale.setScalar(markerScale() * (on ? 1.35 : 1));
  });
  renderPanel();
}

// ---------------- 拖拽交互 ----------------
var raycaster = new THREE.Raycaster();
var dragPlane = new THREE.Plane();
var dragging = null;
var downPos = null;

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
    dragging = key;
    controls.enabled = false;
    selectMarker(key);
    var p = markers[key].group.position.clone();
    var n = new THREE.Vector3(); camera.getWorldDirection(n);
    dragPlane.setFromNormalAndCoplanarPoint(n, p);
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

// ---------------- 数据写入（镜像 / JSON / 预览联动） ----------------
function setMarkerPos(key, pos, opts) {
  opts = opts || {};
  var p = new THREE.Vector3(r4(pos.x), r4(pos.y), r4(pos.z));
  setMarkerVisual(key, p);

  if (S.mode === 'wheel') {
    S.json.center = [p.x, p.y, p.z];
    if (spinPivot) { spinPivot.position.copy(p); }
  } else {
    S.json.wheel_positions[key] = [p.x, p.y, p.z];
    if (S.mirrorX && !opts.noMirror && PAIR[key]) {
      var q = new THREE.Vector3(r4(-p.x), p.y, p.z);
      S.json.wheel_positions[PAIR[key]] = [q.x, q.y, q.z];
      setMarkerVisual(PAIR[key], q);
    }
    updateWheelPreview();
  }
  if (!opts.silent) renderPanel(false);
}

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
  S.cars = await listDir('cars');
  S.wheels = await listDir('wheels');
  S.mode = null; S.assetId = null; S.json = null;
  clearModel(); clearMarkers(); clearWheelPreview();
  renderAssetLists();
  var canWrite = S.writable ? '可直接写回' : '只读模式：保存将下载 JSON，请手动替换';
  var warn = [];
  if (!S.cars.length) warn.push('cars/ 为空');
  if (!S.wheels.length) warn.push('wheels/ 为空');
  setStatus(warn.length ? ('已打开目录（' + warn.join('，') + '）— ' + canWrite) : ('已打开目录 — ' + canWrite), 'ok');
}

// ---------------- HTTP 联调模式：index.html?art=<base> ----------------
// 从本地 HTTP 服务按 manifest.json 拉取资产（只读，保存走下载）。
// 用于自动化测试与无 File System Access API 环境的预览；manifest 由
// make_placeholder_assets.py 生成。
async function loadHttpMode() {
  var base = new URLSearchParams(location.search).get('art');
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
  while (modelGroup.children.length) modelGroup.remove(modelGroup.children[0]);
  S.modelBBox = null;
  clearSpinPreview();
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
      li.innerHTML = '<span>' + it.id + '</span><span class="tag">' +
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
    j.version = j.version || 1;
    j.id = id;
    j.name = j.name || '';
    j.model = j.model || '';
    j.wheel_positions = j.wheel_positions || {};
    BODY_KEYS.forEach(function (k) {
      var v = j.wheel_positions[k] || BODY_DEFAULT_POS[k];
      j.wheel_positions[k] = [r4(+v[0]), r4(+v[1]), r4(+v[2])];
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
  markActiveInList();

  var modelName = S.json.model || await firstModelName(kind, id);
  var hadModel = false;
  try {
    var obj = await loadGLB(kind, id, modelName);
    modelGroup.add(obj);
    S.modelBBox = new THREE.Box3().setFromObject(obj);
    if (S.modelBBox.isEmpty()) S.modelBBox = null;
    hadModel = true;
  } catch (e) {
    setStatus(e.message + '（可先在空场景中定义，后续补模型）', 'err');
  }
  if (!S.json.model && modelName) S.json.model = modelName;

  if (S.mode === 'wheel') {
    makeMarker('center', '中心', 0x3ecf8e);
    setMarkerVisual('center', new THREE.Vector3().fromArray(S.json.center));
  } else {
    BODY_KEYS.forEach(function (k) {
      makeMarker(k, BODY_LABEL[k].split(' ')[1], BODY_COLOR[k]);
      setMarkerVisual(k, new THREE.Vector3().fromArray(S.json.wheel_positions[k]));
    });
    await rebuildPreviewWheelList();
    if (previewWheelId) await setPreviewWheel(previewWheelId);
  }
  refreshMarkerScale();
  selectMarker(S.mode === 'wheel' ? 'center' : 'front_left');
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
  BODY_KEYS.forEach(function (k) {
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
  BODY_KEYS.forEach(function (k) {
    var slot = previewSlots[k];
    if (!slot || !S.json) return;
    slot.group.position.copy(new THREE.Vector3().fromArray(S.json.wheel_positions[k]));
    slot.group.rotation.y = (k === 'front_left' || k === 'front_right') ? steer : 0;
  });
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

  panel.appendChild(fieldInput('名称 name', S.json.name || '', function (v) { S.json.name = v; }));
  panel.appendChild(fieldInput('模型 model', S.json.model || '', function (v) { S.json.model = v; }));

  var divider = document.createElement('div'); divider.className = 'divider'; panel.appendChild(divider);

  if (S.mode === 'wheel') {
    var h = document.createElement('div'); h.className = 'sec'; h.innerHTML = '<h3>轮毂中心点</h3>'; panel.appendChild(h);
    panel.appendChild(vec3Row('center', S.json.center, function (x, y, z) {
      setMarkerPos('center', new THREE.Vector3(x, y, z), { silent: true, noMirror: true });
      refreshPanelValues();
    }));
    panel.appendChild(fieldInput('半径 radius', S.json.radius, function (v) { S.json.radius = r4(v); }, 'number'));
    panel.appendChild(fieldInput('宽度 width', S.json.width, function (v) { S.json.width = r4(v); }, 'number'));

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
    var h2 = document.createElement('div'); h2.className = 'sec'; h2.innerHTML = '<h3>四个轮位</h3>'; panel.appendChild(h2);

    var chkMirror = document.createElement('label');
    chkMirror.className = 'chk';
    chkMirror.innerHTML = '<input type="checkbox"' + (S.mirrorX ? ' checked' : '') + '> X 轴左右镜像联动';
    chkMirror.querySelector('input').addEventListener('change', function () { S.mirrorX = this.checked; });
    panel.appendChild(chkMirror);

    BODY_KEYS.forEach(function (k) {
      var row = vec3Row(BODY_LABEL[k], S.json.wheel_positions[k], function (x, y, z) {
        setMarkerPos(k, new THREE.Vector3(x, y, z), { silent: true });
        refreshPanelValues();
      });
      row.style.cursor = 'pointer';
      row.addEventListener('click', function (e) { if (e.target.tagName !== 'INPUT') selectMarker(k); });
      row.dataset.slot = k;
      panel.appendChild(row);
    });

    var hint2 = document.createElement('div');
    hint2.className = 'hint';
    hint2.textContent = '轮位同时驱动物理轮挂点。选中标记后可在视口中拖拽；前轮位在车头方向（−Z）。';
    panel.appendChild(hint2);
  }
}

function refreshPanelValues() {
  // 拖拽/镜像联动后同步面板数值，不重建 DOM（避免输入焦点丢失）
  document.querySelectorAll('#right .row3').forEach(function (row) {
    var key = row.dataset.slot || 'center';
    var v = S.mode === 'wheel' ? S.json.center : S.json.wheel_positions[key];
    if (!v) return;
    var inputs = row.querySelectorAll('input');
    ['x', 'y', 'z'].forEach(function (_, i) {
      if (document.activeElement !== inputs[i]) inputs[i].value = fmt(v[i]);
    });
  });
}

// ---------------- 保存 ----------------
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
    version: j.version, id: j.id, name: j.name || '', model: j.model || 'body.glb',
    wheel_positions: {}
  };
  BODY_KEYS.forEach(function (k) { out2.wheel_positions[k] = j.wheel_positions[k].slice(); });
  Object.keys(j).forEach(function (k) { if (!(k in out2)) out2[k] = j[k]; }); // anchors 等扩展字段原样保留
  return out2;
}

$('btnSave').addEventListener('click', async function () {
  if (!S.json) return;
  var path = S.mode === 'body' ? relPath(['cars', S.assetId, 'body.json']) : relPath(['wheels', S.assetId, 'wheel.json']);
  var text = JSON.stringify(orderedJson(), null, 2) + '\n';
  try {
    if (S.rootHandle && S.writable) {
      await writeFile(path, text);
      setStatus('已写回 ' + path, 'ok');
      S.cars = await listDir('cars'); S.wheels = await listDir('wheels'); renderAssetLists();
    } else {
      await writeFile(path, text);
      setStatus('已生成下载 ' + path.split('/').pop() + '，请手动放到 art/' + path.replace(/\/[^/]+$/, ''), 'ok');
    }
  } catch (e) {
    setStatus('保存失败：' + (e && e.message || e), 'err');
  }
});

// ---------------- 渲染循环 ----------------
var lastT = performance.now();
function animate(t) {
  requestAnimationFrame(animate);
  var dt = Math.min((t - lastT) / 1000, 0.05); lastT = t;
  if (spinPivot) spinPivot.rotation.x += dt * 2.2;
  if (S.previewSpin) {
    BODY_KEYS.forEach(function (k) {
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
  orderedJson: function () { return orderedJson(); },
  status: function () { return statusEl.textContent; }
};

requestAnimationFrame(animate);

renderPanel();
})();
