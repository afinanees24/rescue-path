// Real-time 3D house for the Drone-Eye dashboard (three.js).
// window.house3d.update(parts) sets the damage state; everything eases toward it every frame.
//   parts = {overall, roof, walls, windows, garage, car, smoke, fire, pending, person}
//   each damage field is 'none' | 'light' | 'heavy' | 'destroyed'
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const LV = { none: 0, light: 1, heavy: 2, destroyed: 3 };
const pick = (arr, lvl) => arr[LV[lvl] ?? 0];
const C = (hex) => new THREE.Color(hex);
const CHAR = C('#231F1C');

const host = document.getElementById('three');
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.domElement.style.cssText = 'width:100%;height:100%;display:block;outline:none;cursor:grab;transition:opacity .8s';
host.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 200);
camera.position.set(14, 9, 16);
const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 1.6, 0);
controls.enableDamping = true;
controls.enablePan = false;
controls.minDistance = 12;
controls.maxDistance = 30;
controls.maxPolarAngle = Math.PI * 0.46;
controls.autoRotate = true;
controls.autoRotateSpeed = 0.55;

// ---------- light ----------
scene.add(new THREE.HemisphereLight('#FFFFFF', '#B9B4A8', 1.1));
const sun = new THREE.DirectionalLight('#FFF4E2', 2.2);
sun.position.set(8, 14, 6);
sun.castShadow = true;
sun.shadow.mapSize.set(1024, 1024);
Object.assign(sun.shadow.camera, { left: -12, right: 12, top: 12, bottom: -12, near: 1, far: 40 });
sun.shadow.radius = 4;
scene.add(sun);
const fireLight = new THREE.PointLight('#FF7A2E', 0, 14, 1.6);
fireLight.position.set(0, 4, 0.5);
scene.add(fireLight);

// ---------- helpers ----------
const std = (hex, extra = {}) => new THREE.MeshStandardMaterial({ color: hex, roughness: 0.9, metalness: 0, ...extra });
function mesh(geo, mat, { cast = true, receive = true } = {}) {
  const m = new THREE.Mesh(geo, mat); m.castShadow = cast; m.receiveShadow = receive; return m;
}
function canvasTex(draw, size = 256) {
  const c = document.createElement('canvas'); c.width = c.height = size;
  draw(c.getContext('2d'), size);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; return t;
}
const radialTex = (inner, outer) => canvasTex((g, s) => {
  const r = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
  r.addColorStop(0, inner); r.addColorStop(1, outer); g.fillStyle = r; g.fillRect(0, 0, s, s);
});
const shingleTex = canvasTex((g, s) => {
  g.fillStyle = '#FFFFFF'; g.fillRect(0, 0, s, s);
  g.strokeStyle = 'rgba(0,0,0,.18)'; g.lineWidth = 2;
  for (let y = 0; y < s; y += 22) {
    g.beginPath(); g.moveTo(0, y); g.lineTo(s, y); g.stroke();
    for (let x = (y / 22) % 2 ? 0 : 16; x < s; x += 32) { g.beginPath(); g.moveTo(x, y); g.lineTo(x, y + 22); g.stroke(); }
  }
});
shingleTex.wrapS = shingleTex.wrapT = THREE.RepeatWrapping; shingleTex.repeat.set(2, 1.5);
const sidingTex = canvasTex((g, s) => {
  g.fillStyle = '#FFFFFF'; g.fillRect(0, 0, s, s); g.strokeStyle = 'rgba(0,0,0,.08)'; g.lineWidth = 2;
  for (let y = 0; y < s; y += 16) { g.beginPath(); g.moveTo(0, y); g.lineTo(s, y); g.stroke(); }
});
sidingTex.wrapS = sidingTex.wrapT = THREE.RepeatWrapping; sidingTex.repeat.set(2, 2);

// Everything that animates registers a target: {obj, key, to} and eases toward it.
const easers = [];
function ease(get, set, target) { const e = { get, set, to: target }; easers.push(e); return e; }

// ---------- ground ----------
const world = new THREE.Group(); scene.add(world);
const ground = mesh(new THREE.CircleGeometry(16, 64), std('#E4E3DC'), { cast: false });
ground.rotation.x = -Math.PI / 2; world.add(ground);
const lawn = mesh(new THREE.CircleGeometry(9, 64), std('#C9D4B4'), { cast: false });
lawn.rotation.x = -Math.PI / 2; lawn.position.y = 0.005; world.add(lawn);
const ashMat = new THREE.MeshBasicMaterial({ map: radialTex('rgba(30,26,22,1)', 'rgba(30,26,22,0)'), transparent: true, opacity: 0, depthWrite: false });
const ash = new THREE.Mesh(new THREE.PlaneGeometry(16, 16), ashMat);
ash.rotation.x = -Math.PI / 2; ash.position.y = 0.012; world.add(ash);
const drive = mesh(new THREE.PlaneGeometry(3, 6), std('#B9B7AF'), { cast: false });
drive.rotation.x = -Math.PI / 2; drive.position.set(-5.2, 0.01, 4.6); world.add(drive);

// ---------- house ----------
const W = 6, D = 4.5, H = 2.6, T = 0.18;
const house = new THREE.Group(); world.add(house);
const wallMat = std('#EFE9DF', { map: sidingTex });
function wall(w, h, x, z, ry) {   // pivot at the floor so it can 'burn down' (scale.y)
  const g = new THREE.Group(); g.position.set(x, 0, z); g.rotation.y = ry;
  const m = mesh(new THREE.BoxGeometry(w, h, T), wallMat); m.position.y = h / 2; g.add(m); house.add(g); return g;
}
const wFront = wall(W, H, 0, D / 2, 0), wBack = wall(W, H, 0, -D / 2, 0);
const wLeft = wall(D, H, -W / 2, 0, Math.PI / 2), wRight = wall(D, H, W / 2, 0, Math.PI / 2);

const glassMat = new THREE.MeshStandardMaterial({ color: '#9EC3D6', roughness: 0.15, metalness: 0.1, transparent: true, opacity: 0.85, emissive: '#FF6A1A', emissiveIntensity: 0 });
const frameMat = std('#F7F5F0');
function windowOn(parent, x, y, w, h, side = 1) {
  const g = new THREE.Group(); g.position.set(x, y, side * (T / 2 + 0.02));
  const frame = mesh(new THREE.BoxGeometry(w + 0.14, h + 0.14, 0.05), frameMat, { cast: false }); g.add(frame);
  const glass = mesh(new THREE.PlaneGeometry(w, h), glassMat, { cast: false }); glass.position.z = side * 0.03; if (side < 0) glass.rotation.y = Math.PI; g.add(glass);
  parent.add(g); return g;
}
const frontPanel = wFront.children[0];
windowOn(frontPanel, -1.8, 0.2, 1.1, 0.9); windowOn(frontPanel, 1.8, 0.2, 1.1, 0.9);
const doorMat = std('#6B4F3A');
const door = mesh(new THREE.BoxGeometry(0.95, 1.9, 0.06), doorMat, { cast: false }); door.position.set(0, -0.35, T / 2 + 0.03); frontPanel.add(door);
windowOn(wBack.children[0], -1.4, 0.2, 1.1, 0.9, -1); windowOn(wBack.children[0], 1.4, 0.2, 1.1, 0.9, -1);
windowOn(wLeft.children[0], 0, 0.2, 1.2, 0.9, 1); windowOn(wRight.children[0], 0, 0.2, 1.2, 0.9, -1);

// roof: two slabs hinged at the ridge
const RUN = D / 2 + 0.35, RISE = 1.6, ANG = Math.atan2(RISE, RUN), LEN = Math.hypot(RUN, RISE), RIDGE = H + RISE;
const roofMat = std('#8C6A55', { map: shingleTex });
function slab(side) {
  const g = new THREE.Group(); g.position.set(0, RIDGE, 0);
  const m = mesh(new THREE.BoxGeometry(W + 0.6, 0.16, LEN), roofMat); m.position.z = side * LEN / 2; g.add(m);
  house.add(g); return g;
}
const roofF = slab(1), roofB = slab(-1);
const gableMat = std('#EFE9DF', { map: sidingTex });
function gable(x) {
  const s = new THREE.Shape(); s.moveTo(-D / 2, 0); s.lineTo(D / 2, 0); s.lineTo(0, RISE); s.closePath();
  const g = new THREE.Group(); g.position.set(x, H, 0); g.rotation.y = Math.PI / 2;
  const m = mesh(new THREE.ExtrudeGeometry(s, { depth: T, bevelEnabled: false }), gableMat); m.position.z = -T / 2; g.add(m);
  house.add(g); return g;
}
const gabL = gable(-W / 2), gabR = gable(W / 2);
const chimMat = std('#9C6B54');
const chimney = mesh(new THREE.BoxGeometry(0.7, 4.6, 0.7), chimMat); chimney.position.set(1.9, 2.3, -1.0); house.add(chimney);
const floorSlab = mesh(new THREE.BoxGeometry(W + 0.3, 0.12, D + 0.3), std('#CFCBC2'), { cast: false }); floorSlab.position.y = 0.06; house.add(floorSlab);

// ---------- garage ----------
const garage = new THREE.Group(); garage.position.set(-5.2, 0, -0.4); world.add(garage);
const garMat = std('#E6E0D4', { map: sidingTex });
const garBody = new THREE.Group(); garage.add(garBody);
const gb = mesh(new THREE.BoxGeometry(3, 2.3, 3.6), garMat); gb.position.y = 1.15; garBody.add(gb);
const garDoorMat = std('#D8D2C6');
const gd = mesh(new THREE.BoxGeometry(2.3, 1.8, 0.05), garDoorMat, { cast: false }); gd.position.set(0, 0.95, 1.83); garBody.add(gd);
const garRoof = mesh(new THREE.BoxGeometry(3.4, 0.16, 4), roofMat); garRoof.position.y = 2.38; garage.add(garRoof);

// ---------- car ----------
const car = new THREE.Group(); car.position.set(-5.2, 0, 4.4); car.rotation.y = 0.08; world.add(car);
const carMat = std('#4F79A8', { roughness: 0.45, metalness: 0.3 });
const cb = mesh(new THREE.BoxGeometry(1.7, 0.6, 3.6), carMat); cb.position.y = 0.55; car.add(cb);
const cc = mesh(new THREE.BoxGeometry(1.5, 0.55, 1.9), carMat); cc.position.set(0, 1.1, -0.2); car.add(cc);
const carGlass = std('#2B3440', { roughness: 0.2 });
const cg = mesh(new THREE.BoxGeometry(1.52, 0.4, 1.7), carGlass, { cast: false }); cg.position.set(0, 1.12, -0.2); car.add(cg);
const tireMat = std('#1C1C1C');
[[-0.85, 1.2], [0.85, 1.2], [-0.85, -1.2], [0.85, -1.2]].forEach(([x, z]) => {
  const t = mesh(new THREE.CylinderGeometry(0.34, 0.34, 0.25, 18), tireMat); t.rotation.z = Math.PI / 2; t.position.set(x, 0.34, z); car.add(t);
});

// ---------- trees ----------
const trees = [];
[[5.6, -3.2, 1.1], [6.4, 2.6, 0.9], [-2.2, -5.4, 1.2], [3.2, -5.6, 0.8]].forEach(([x, z, s]) => {
  const g = new THREE.Group(); g.position.set(x, 0, z); g.scale.setScalar(s);
  const trunk = mesh(new THREE.CylinderGeometry(0.14, 0.2, 1.6, 8), std('#6B5140')); trunk.position.y = 0.8; g.add(trunk);
  const leafMat = std('#6E9B5E');
  const top = new THREE.Group(); top.position.y = 1.6; g.add(top);
  [[0, 0.7, 0, 1.0], [0.45, 0.35, 0.2, 0.7], [-0.4, 0.4, -0.2, 0.75]].forEach(([lx, ly, lz, r]) => {
    const l = mesh(new THREE.IcosahedronGeometry(r, 1), leafMat); l.position.set(lx, ly, lz); top.add(l);
  });
  world.add(g); trees.push({ top, leafMat, trunkMat: trunk.material });
});

// ---------- person marker ----------
const person = new THREE.Group(); person.position.set(3.6, 0, 4.0); world.add(person);
const personMat = std('#2E4A63');
const body = mesh(new THREE.CapsuleGeometry(0.22, 0.75, 4, 10), personMat); body.position.y = 0.62; person.add(body);
const head = mesh(new THREE.SphereGeometry(0.2, 16, 12), std('#D9B99B')); head.position.y = 1.32; person.add(head);
const ringMat = new THREE.MeshBasicMaterial({ color: '#D4F53C', transparent: true, opacity: 0.9, side: THREE.DoubleSide, depthWrite: false });
const ring = new THREE.Mesh(new THREE.RingGeometry(0.45, 0.6, 40), ringMat); ring.rotation.x = -Math.PI / 2; ring.position.y = 0.03; person.add(ring);
const beacon = new THREE.Mesh(new THREE.SphereGeometry(0.12, 12, 10), new THREE.MeshBasicMaterial({ color: '#D4F53C' })); beacon.position.y = 1.85; person.add(beacon);
person.scale.setScalar(0.001);

// ---------- particles: smoke, flames, embers ----------
const smokeTex = radialTex('rgba(110,104,98,0.9)', 'rgba(110,104,98,0)');
const flameTex = radialTex('rgba(255,210,120,1)', 'rgba(255,90,20,0)');
const smoke = [], flames = [];
for (let i = 0; i < 36; i++) {
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: smokeTex, transparent: true, opacity: 0, depthWrite: false }));
  s.userData = { life: Math.random(), speed: 0.12 + Math.random() * 0.1, x0: (Math.random() - 0.5) * 4, z0: (Math.random() - 0.5) * 3 };
  world.add(s); smoke.push(s);
}
for (let i = 0; i < 40; i++) {
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: flameTex, transparent: true, opacity: 0, depthWrite: false, blending: THREE.AdditiveBlending }));
  s.userData = { life: Math.random(), speed: 0.9 + Math.random() * 0.8, x0: (Math.random() - 0.5) * 5, z0: (Math.random() - 0.5) * 3.5 };
  world.add(s); flames.push(s);
}
const EMB = 80, embGeo = new THREE.BufferGeometry(), embPos = new Float32Array(EMB * 3), embSeed = [];
for (let i = 0; i < EMB; i++) embSeed.push({ life: Math.random(), x: (Math.random() - 0.5) * 6, z: (Math.random() - 0.5) * 4, s: 0.5 + Math.random() });
embGeo.setAttribute('position', new THREE.BufferAttribute(embPos, 3));
const embMat = new THREE.PointsMaterial({ color: '#FF9A3D', size: 0.12, transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false });
world.add(new THREE.Points(embGeo, embMat));

// ---------- state targets ----------
const S = {   // current eased values
  wallSoot: 0, roofSoot: 0, garSoot: 0, carSoot: 0, treeBurn: 0, ash: 0,
  smoke: 0, fire: 0, embers: 0, glass: 0.85, person: 0,
  hF: 1, hB: 1, hL: 1, hR: 1, garH: 1,
  rFy: RIDGE, rFa: ANG, rBy: RIDGE, rBa: -ANG, rFz: 0, rBz: 0, gab: 1, gabR: 1, roofScale: 1, garRoofY: 2.38, garRoofTilt: 0
};
const TGT = { ...S };
function setTargets(p) {
  const w = p.walls, r = p.roof, o = p.overall;
  Object.assign(TGT, {
    wallSoot: pick([0, 0.25, 0.6, 0.85], w),
    roofSoot: pick([0, 0.35, 0.75, 0.92], r),
    garSoot: pick([0, 0.25, 0.65, 0.9], p.garage),
    carSoot: pick([0, 0.2, 0.7, 0.92], p.car),
    treeBurn: pick([0, 0.3, 0.75, 1], o),
    ash: pick([0, 0.25, 0.6, 0.85], o),
    glass: pick([0.85, 0.65, 0.0, 0.0], p.windows),
    hF: pick([1, 1, 1, 0.8], w), hB: pick([1, 1, 0.75, 0.38], w), hL: pick([1, 1, 0.95, 0.62], w), hR: pick([1, 1, 0.82, 0.28], w),
    garH: pick([1, 1, 0.9, 0.4], p.garage),
    rFy: pick([RIDGE, RIDGE, RIDGE - 0.9, 0.55], r), rFa: pick([ANG, ANG, 1.15, 0.12], r), rFz: pick([0, 0, 0.2, -1.4], r),
    rBy: pick([RIDGE, RIDGE, RIDGE - 0.15, 0.75], r), rBa: pick([-ANG, -ANG, -ANG - 0.08, -0.2], r), rBz: pick([0, 0, 0, 1.3], r),
    roofScale: pick([1, 1, 0.97, 0.72], r),
    gab: pick([1, 1, 0.7, 0.02], r), gabR: pick([1, 1, 0.25, 0.02], r),
    garRoofY: pick([2.38, 2.38, 2.0, 0.9], p.garage), garRoofTilt: pick([0, 0, 0.25, 0.5], p.garage),
    smoke: p.smoke ? (o === 'destroyed' ? 1 : 0.75) : 0,
    fire: p.fire ? 1 : 0,
    embers: p.fire ? 1 : (o === 'heavy' ? 0.35 : 0),
    person: p.person ? 1 : 0
  });
  renderer.domElement.style.opacity = p.pending ? 0.5 : 1;
}

// ---------- colors ----------
const BASE = { wall: C('#EFE9DF'), roof: C('#8C6A55'), gar: C('#E6E0D4'), car: C('#4F79A8'), leaf: C('#6E9B5E'), leafBurnt: C('#5A4632'), chim: C('#9C6B54'), door: C('#6B4F3A'), glass: C('#9EC3D6'), frame: C('#F7F5F0') };
const tmp = new THREE.Color();
const mix = (base, k, to = CHAR) => tmp.copy(base).lerp(to, k);

// ---------- loop ----------
let last = performance.now(), visible = true, t = 0;
function resize() {
  const w = host.clientWidth, h = host.clientHeight; if (!w || !h) return;
  renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(host); resize();

function frame(now) {
  requestAnimationFrame(frame);
  const dt = Math.min(0.05, (now - last) / 1000); last = now; t += dt;
  if (!visible) return;
  const k = 1 - Math.exp(-dt * 2.2);
  for (const key in TGT) S[key] += (TGT[key] - S[key]) * k;

  // structure
  wFront.scale.y = S.hF; wBack.scale.y = S.hB; wLeft.scale.y = S.hL; wRight.scale.y = S.hR;
  roofF.position.y = S.rFy; roofF.rotation.x = S.rFa; roofF.position.z = S.rFz;
  roofB.position.y = S.rBy; roofB.rotation.x = S.rBa; roofB.position.z = S.rBz;
  roofF.scale.setScalar(S.roofScale); roofB.scale.setScalar(S.roofScale);
  gabL.scale.y = S.gab; gabR.scale.y = S.gabR;
  garBody.scale.y = S.garH; garRoof.position.y = S.garRoofY; garRoof.rotation.z = S.garRoofTilt;

  // materials
  wallMat.color.copy(mix(BASE.wall, S.wallSoot)); gableMat.color.copy(mix(BASE.wall, Math.max(S.wallSoot, S.roofSoot * 0.8)));
  roofMat.color.copy(mix(BASE.roof, S.roofSoot)); chimMat.color.copy(mix(BASE.chim, S.ash * 0.75));
  garMat.color.copy(mix(BASE.gar, S.garSoot)); garDoorMat.color.copy(mix(BASE.gar, S.garSoot));
  carMat.color.copy(mix(BASE.car, S.carSoot)); doorMat.color.copy(mix(BASE.door, S.wallSoot * 0.9));
  frameMat.color.copy(mix(BASE.frame, S.wallSoot));
  glassMat.opacity = S.glass; glassMat.color.copy(mix(BASE.glass, 1 - S.glass / 0.85, C('#3A3A3A')));
  const flicker = 0.75 + 0.25 * Math.sin(t * 17) * Math.sin(t * 7.3);
  glassMat.emissiveIntensity = S.fire * 2.2 * flicker;
  for (const tr of trees) {
    tr.leafMat.color.copy(BASE.leaf).lerp(BASE.leafBurnt, Math.min(1, S.treeBurn * 1.4)).lerp(CHAR, Math.max(0, S.treeBurn - 0.5) * 1.6);
    tr.trunkMat.color.copy(mix(C('#6B5140'), S.treeBurn * 0.8));
    tr.top.scale.setScalar(1 - S.treeBurn * 0.82);
  }
  ashMat.opacity = S.ash;
  fireLight.intensity = S.fire * 30 * flicker;

  // person
  person.scale.setScalar(Math.max(0.001, S.person));
  const rp = (t * 0.8) % 1; ring.scale.setScalar(1 + rp * 2.2); ringMat.opacity = 0.9 * (1 - rp) * S.person;
  beacon.position.y = 1.85 + Math.sin(t * 3) * 0.08;

  // smoke
  const top = Math.max(S.rFy, H * S.hB);
  for (const s of smoke) {
    const u = s.userData; u.life += dt * u.speed; if (u.life > 1) { u.life = 0; u.x0 = (Math.random() - 0.5) * 4; u.z0 = (Math.random() - 0.5) * 3; }
    s.position.set(u.x0 + u.life * 2.2, top * 0.6 + u.life * 7, u.z0 - u.life * 0.8);
    s.scale.setScalar(1.2 + u.life * 4.5);
    s.material.opacity = S.smoke * 0.55 * Math.sin(Math.PI * u.life);
  }
  // flames
  for (const f of flames) {
    const u = f.userData; u.life += dt * u.speed; if (u.life > 1) { u.life = 0; u.x0 = (Math.random() - 0.5) * 5; u.z0 = (Math.random() - 0.5) * 3.5; }
    f.position.set(u.x0, Math.max(0.6, top * 0.75) + u.life * 1.6, u.z0);
    f.scale.setScalar(0.9 + (1 - u.life) * 1.1);
    f.material.opacity = S.fire * 0.85 * Math.sin(Math.PI * u.life);
  }
  // embers
  for (let i = 0; i < EMB; i++) {
    const e = embSeed[i]; e.life += dt * 0.35 * e.s; if (e.life > 1) { e.life = 0; e.x = (Math.random() - 0.5) * 6; e.z = (Math.random() - 0.5) * 4; }
    embPos[i * 3] = e.x + Math.sin(t * 2 + i) * 0.3 + e.life * 1.5; embPos[i * 3 + 1] = 1 + e.life * 6; embPos[i * 3 + 2] = e.z;
  }
  embGeo.attributes.position.needsUpdate = true; embMat.opacity = S.embers;

  controls.update();
  renderer.render(scene, camera);
}
requestAnimationFrame(frame);

window.house3d = {
  update: setTargets,
  setVisible(v) { visible = v; if (v) resize(); },
};
window.dispatchEvent(new Event('house3d-ready'));
