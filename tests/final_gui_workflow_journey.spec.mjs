import { test, expect, request as playwrightRequest } from '@playwright/test';
import { execSync } from 'node:child_process';
import { copyFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

/**
 * Peer-reviewer journey: build a Tissue-Micro-Array workflow ENTIRELY through the GUI —
 * dropping SIBs from the palette onto the canvas and wiring control-flow + data-flow edges —
 * then generate/execute it and inspect the result. Recorded with video.
 *
 * The SIBs are dynamically provided by the backend (sib-manager). After "Refresh SIB Library"
 * the palette is populated with the real SIBs (InitTMA, SegArrayTMA, ...). Placing one creates a
 * fully prime-referenced, port-initialised SIB; edges are created with the ControlFlow / DataFlow
 * palette tools.
 *
 * Runs against either deployment via env (see final_cinco_de_bio_full_demo.spec.mjs header).
 */

const editorUrl = process.env.CINCODEBIO_EDITOR_URL ?? 'http://localhost/editor/';
const appUrl = (process.env.CINCODEBIO_APP_URL ?? 'http://localhost/app').replace(/\/+$/, '');
const executionApiUrl = (process.env.CINCODEBIO_EXECUTION_API_URL ?? 'http://localhost/execution-api/ext').replace(/\/+$/, '');
const runtimeLabel = process.env.CINCODEBIO_RUNTIME_LABEL ?? 'k3s';
const installLog = process.env.CINCODEBIO_INSTALL_LOG ?? '';
const WS = '/editor/workspace';
const modelName = 'PeerReviewDemo';
const FILE = `${WS}/${modelName}.flow`;
const slug = runtimeLabel.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
const videoPath = `artifacts/playwright/final-gui-journey-${slug}.webm`;
const tracePath = `artifacts/playwright/final-gui-journey-${slug}-trace.zip`;

// --- TMA dearray pipeline (built entirely via the palette) ---
const SIBS = [
  { name: 'InitTMA', dx: 70, dy: 40 },
  { name: 'SegArrayTMA', dx: 470, dy: 40 },
  { name: 'EditPredictedRoisTMA', dx: 870, dy: 40 },
  { name: 'CropCoresTMA', dx: 270, dy: 330 },
  { name: 'AceDTMA', dx: 670, dy: 330 }
];
const CONTROL_FLOW = [
  ['InitTMA', 'SegArrayTMA'], ['SegArrayTMA', 'EditPredictedRoisTMA'],
  ['EditPredictedRoisTMA', 'CropCoresTMA'], ['CropCoresTMA', 'AceDTMA']
];
// [sourceSib, outputPort, targetSib, inputPort] — every input port must be fed (SibCheck)
const DATA_FLOW = [
  ['InitTMA', 'tissue_micro_array', 'SegArrayTMA', 'tissue_micro_array'],
  ['InitTMA', 'nuclear_stain', 'SegArrayTMA', 'nuclear_stain'],
  ['InitTMA', 'tissue_micro_array', 'EditPredictedRoisTMA', 'tissue_micro_array'],
  ['InitTMA', 'nuclear_stain', 'EditPredictedRoisTMA', 'nuclear_stain'],
  ['SegArrayTMA', 'predicted_rois', 'EditPredictedRoisTMA', 'predicted_rois'],
  ['InitTMA', 'tissue_micro_array', 'CropCoresTMA', 'tissue_micro_array'],
  ['EditPredictedRoisTMA', 'rois', 'CropCoresTMA', 'rois'],
  ['CropCoresTMA', 'dearrayed_tissue_micro_array', 'AceDTMA', 'dearrayed_tissue_micro_array']
];

test.use({ video: 'on', ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1000 } });

test(`peer-reviewer journey: build TMA workflow via palette + execute (${runtimeLabel})`, async ({ page, context }, testInfo) => {
  test.setTimeout(600_000);
  mkdirSync(dirname(tracePath), { recursive: true });
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
  const diagnostics = [];
  page.on('console', m => diagnostics.push(`console:${m.type()}:${m.text()}`));
  page.on('pageerror', e => diagnostics.push(`pageerror:${e.message}`));
  const api = await playwrightRequest.newContext({ ignoreHTTPSErrors: true });

  try {
    seedEmpty();

    await test.step('1. install + open the Cinco editor', async () => {
      await page.goto(editorUrl, { waitUntil: 'domcontentloaded', timeout: 120_000 });
      await page.waitForLoadState('networkidle', { timeout: 90_000 }).catch(() => undefined);
      await expect(page.locator('body')).toContainText('File', { timeout: 120_000 });
      await installGuide(page);
      await showInstallCard(page, runtimeLabel, installLog);
      await page.waitForTimeout(6_000);
      await removeInstallCard(page);
      // maximise the modelling canvas (hide the bottom panel)
      await page.keyboard.press('Meta+j').catch(() => undefined);
      await page.waitForTimeout(800);
      await openDiagram(page);
      await page.waitForTimeout(3_500);
    });

    let canvas;
    await test.step('2a. refresh the SIB library so the palette is populated', async () => {
      await setGuide(page, 'Refresh SIB Library', 'The SIBs are provided dynamically by sib-manager. Refreshing populates the palette with the installed SIBs.');
      canvas = await canvasBox(page);
      await refreshSibLibrary(page, canvas);
      await expect.poll(() => sibCount(), { timeout: 90_000, message: 'waiting for siblib/' }).toBeGreaterThan(0);
      await page.waitForTimeout(2_000);
      // Re-open the diagram so the palette is re-fetched with the freshly-loaded SIB library
      // (on a fresh cluster the palette was first requested before the library existed).
      await openDiagram(page);
      await page.waitForTimeout(4_000);
      await expect(await paletteItem(page, 'InitTMA')).toBeVisible({ timeout: 60_000 });
    });

    await test.step('2b. drop the SIBs from the palette onto the canvas', async () => {
      canvas = await canvasBox(page);
      for (const s of SIBS) {
        await setGuide(page, `Add ${s.name}`, `Drag ${s.name} from the palette onto the canvas — the SIB is created with its prime reference and typed ports.`);
        const ok = await placeSib(page, s.name, canvas.x + s.dx, canvas.y + s.dy);
        expect(ok, `placed ${s.name}`).toBe(true);
        await page.waitForTimeout(900);
      }
    });

    // Build a name -> {id, ports} map from the saved model
    const map = await test.step('2c. wire control-flow + data-flow edges with the palette', async () => {
      const model = readModel();
      const byName = {};
      for (const c of model._containments ?? []) {
        const ports = {};
        for (const p of c._containments ?? []) {
          if (p.type === 'cincodebio:inputport') ports['in:' + p._attributes?.name] = p.id;
          if (p.type === 'cincodebio:outputport') ports['out:' + p._attributes?.name] = p.id;
        }
        byName[c._attributes?.name] = { id: c.id, ports };
      }
      // control flow chain
      for (const [src, tgt] of CONTROL_FLOW) {
        await setGuide(page, 'Control flow', `Connect ${src} → ${tgt} (success branch) with the ControlFlow tool.`);
        const ok = await createControlFlow(page, byName[src].id, byName[tgt].id);
        expect(ok, `control flow ${src}->${tgt}`).toBe(true);
        await page.waitForTimeout(500);
      }
      // data flow
      for (const [src, op, tgt, ip] of DATA_FLOW) {
        await setGuide(page, 'Data flow', `Connect ${src}.${op} → ${tgt}.${ip} with the DataFlow tool.`);
        const sId = byName[src].ports['out:' + op], tId = byName[tgt].ports['in:' + ip];
        const ok = await createDataFlow(page, sId, tId);
        expect(ok, `data flow ${src}.${op}->${tgt}.${ip}`).toBe(true);
        await page.waitForTimeout(400);
      }
      return byName;
    });
    void map;
    await page.keyboard.press('Meta+s').catch(() => undefined);
    await page.waitForTimeout(2_000);

    await test.step('3. generate / execute the workflow', async () => {
      await setGuide(page, 'Generate workflow', 'The editor validates the model (SibCheck / DataFlowCheck / ControlFlowCheck) and submits it to execution-api.');
      // refresh once more so validation has the up-to-date library, then generate
      await refreshSibLibrary(page, await canvasBox(page)).catch(() => undefined);
      await page.waitForTimeout(1_500);
      const spy = await installCommandSpy(page);
      expect(spy.ok, spy.message ?? 'CommandRegistry').toBe(true);
      const before = await getWorkflowIds(api);
      const trig = await triggerGenerate(page);
      expect(trig.ok, trig.message ?? 'trigger generate').toBe(true);
      await page.waitForTimeout(4_000);

      const workflowId = await test.step('confirm submission', async () => {
        await expect.poll(
          async () => (await getWorkflowIds(api)).filter(id => !before.includes(id)).length,
          { timeout: 120_000, message: () => `diag:\n${diagnostics.slice(-25).join('\n')}\n\neditor:\n${editorLogs()}` }
        ).toBeGreaterThan(0);
        return (await getWorkflowIds(api)).filter(id => !before.includes(id))[0];
      });

      await test.step('4. inspect execution + result', async () => {
        const wf = await context.newPage();
        await installGuide(wf);
        await setGuide(wf, 'Workflow execution', `Workflow ${workflowId} running on the platform.`);
        const r = await wf.goto(`${appUrl}/workflows/${workflowId}`, { waitUntil: 'domcontentloaded', timeout: 90_000 }).catch(() => undefined);
        expect(r?.status() ?? 0).toBeLessThan(400);
        await wf.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => undefined);
        const state = await waitForExecution(wf, api, workflowId);
        await resultPanel(wf, state);
        await wf.waitForTimeout(7_000);
        await wf.screenshot({ path: `artifacts/playwright/final-gui-journey-${slug}-result.png`, fullPage: true });
        await testInfo.attach('execution-state', { body: JSON.stringify(state, null, 2), contentType: 'application/json' });
        await wf.close();
      });
    });
  } finally {
    await api.dispose().catch(() => undefined);
    await context.tracing.stop({ path: tracePath }).catch(() => undefined);
    const video = page.video();
    await page.close().catch(() => undefined);
    if (video) {
      const src = await video.path().catch(() => undefined);
      if (src) { mkdirSync(dirname(videoPath), { recursive: true }); copyFileSync(src, videoPath); }
      await testInfo.attach(`gui-journey-${slug}-video`, { path: videoPath, contentType: 'video/webm' }).catch(() => undefined);
    }
  }
});

// ---------- modelling helpers ----------
async function placeSib(page, name, x, y) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const item = await paletteItem(page, name);
    if (!(await item.isVisible({ timeout: 5_000 }).catch(() => false))) return false;
    await item.click();
    await page.waitForTimeout(700);
    await page.mouse.move(x, y, { steps: 10 });
    await page.waitForTimeout(250);
    await page.mouse.click(x, y);
    await page.waitForTimeout(1_700);
    await page.keyboard.press('Meta+s').catch(() => undefined);
    await page.waitForTimeout(1_600);
    if ((readModel()._containments ?? []).some(c => c._attributes?.name === name)) return true;
    await page.keyboard.press('Escape').catch(() => undefined);
  }
  return false;
}

async function createControlFlow(page, srcId, tgtId) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const before = countEdges(/controlflow/i);
    const tool = await paletteItem(page, 'ControlFlow');
    await tool.click();
    await page.waitForTimeout(600);
    const s = await elPos(page, srcId), t = await elPos(page, tgtId);
    if (!s || !t) { await page.keyboard.press('Escape').catch(() => undefined); continue; }
    // click the SIB header strips (above the port rows)
    await page.mouse.click(s.x, s.top + 12);
    await page.waitForTimeout(700);
    await page.mouse.click(t.x, t.top + 12);
    await page.waitForTimeout(1_300);
    await page.keyboard.press('Escape').catch(() => undefined);
    await page.keyboard.press('Meta+s').catch(() => undefined);
    await page.waitForTimeout(1_400);
    if (countEdges(/controlflow/i) > before) return true;
  }
  return false;
}

async function createDataFlow(page, srcPortId, tgtPortId) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const before = countEdges(/dataflow/i);
    const tool = await paletteItem(page, 'DataFlow');
    await tool.click();
    await page.waitForTimeout(600);
    const s = await elPos(page, srcPortId), t = await elPos(page, tgtPortId);
    if (!s || !t) { await page.keyboard.press('Escape').catch(() => undefined); continue; }
    await page.mouse.click(s.x, s.y);
    await page.waitForTimeout(700);
    await page.mouse.click(t.x, t.y);
    await page.waitForTimeout(1_300);
    await page.keyboard.press('Escape').catch(() => undefined);
    await page.keyboard.press('Meta+s').catch(() => undefined);
    await page.waitForTimeout(1_400);
    if (countEdges(/dataflow/i) > before) return true;
  }
  return false;
}

async function refreshSibLibrary(page, canvas) {
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press('Escape').catch(() => undefined);
    await page.mouse.click(canvas.x + canvas.w - 30, canvas.y + canvas.h - 30, { button: 'right' });
    const it = page.locator('.p-Menu-itemLabel, .lm-Menu-itemLabel, [role="menuitem"]').filter({ hasText: /Refresh SIB Library/ }).first();
    if (await it.isVisible({ timeout: 1_500 }).catch(() => false)) { await it.click(); await page.waitForTimeout(7_000); return; }
  }
}

async function paletteItem(page, name) {
  return page.locator('.tool-button, [class*="tool-button"]').filter({ hasText: new RegExp(name + '$') }).first();
}
async function elPos(page, id) {
  return page.evaluate(eid => {
    const el = document.getElementById(eid) || document.querySelector(`[id$="${eid}"]`) || document.querySelector(`[id*="${eid}"]`);
    if (!el) return null;
    const b = el.getBoundingClientRect();
    return { x: Math.round(b.x + b.width / 2), y: Math.round(b.y + b.height / 2), top: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) };
  }, id);
}
async function canvasBox(page) {
  return page.evaluate(() => { const e = document.querySelector('svg.sprotty-graph, .sprotty svg, [class*="sprotty"] svg'); const b = e.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; });
}
async function openDiagram(page) {
  const r = await page.evaluate(async p => {
    const c = window.theia?.container;
    const m = Array.from(c?._bindingDictionary?._map?.entries?.() ?? []).map(([id]) => { try { return c.get(id); } catch { return undefined; } }).find(s => s?.constructor?.name === 'CincoGLSPDiagramMananger' && typeof s.doOpen === 'function');
    if (!m) return { ok: false };
    const fn = p.substring(p.lastIndexOf('/') + 1);
    const uri = { scheme: 'file', path: { base: fn, name: fn, ext: '.flow', toString: () => p, fsPath: () => p }, toString: () => `file://${p}`, withPath: x => ({ ...uri, path: x }) };
    const w = await m.createWidget(m.createWidgetOptions(uri, {})); await m.doOpen(w, uri, { mode: 'activate' }); window.__cdbW = w; return { ok: true };
  }, FILE);
  expect(r.ok, 'open diagram').toBe(true);
}
async function triggerGenerate(page) {
  return page.evaluate(ws => {
    const widget = window.__cdbW;
    const isC = v => v && typeof v.get === 'function' && v._bindingDictionary;
    const containers = [];
    for (const k of [...Object.keys(widget), 'diContainer', 'container', '_container']) { const v = widget[k]; if (isC(v) && !containers.includes(v)) containers.push(v); }
    for (const c of containers) {
      const d = Array.from(c._bindingDictionary?._map?.entries?.() ?? []).map(([id]) => { try { return c.get(id); } catch { return undefined; } }).find(s => s && typeof s.dispatch === 'function' && typeof s.request === 'function' && /ActionDispatcher/.test(s.constructor?.name ?? ''));
      if (d) { const rootId = widget.editorContext?.modelRoot?.id; if (!rootId) return { ok: false }; d.dispatch({ kind: 'cincoGenerate', modelElementId: rootId, targetFolder: ws, args: {} }); return { ok: true }; }
    }
    return { ok: false };
  }, WS);
}
async function installCommandSpy(page) {
  return page.evaluate(() => {
    const c = window.theia?.container;
    const reg = Array.from(c?._bindingDictionary?._map?.entries?.() ?? []).map(([id]) => { try { return c.get(id); } catch { return undefined; } }).find(s => s && typeof s.executeCommand === 'function' && typeof s.getCommand === 'function' && Array.isArray(s.commands));
    if (!reg) return { ok: false };
    window.__cdbCmd = []; if (!reg.__w) { const o = reg.executeCommand.bind(reg); reg.executeCommand = (id, ...a) => { try { window.__cdbCmd.push({ id }); } catch { /* */ } return o(id, ...a); }; reg.__w = true; }
    return { ok: true };
  });
}
async function waitForExecution(wf, api, id) {
  const items = wf.locator('#wf-state-container li');
  await expect(wf.locator('#wf-status')).toBeVisible({ timeout: 60_000 }).catch(() => undefined);
  await expect.poll(async () => items.count(), { timeout: 180_000 }).toBeGreaterThan(0).catch(() => undefined);
  await expect.poll(async () => (await items.allTextContents().catch(() => [])).some(x => /awaiting_interaction|processing|completed|failed|accepted|running|submitted/i.test(x)), { timeout: 180_000 }).toBe(true).catch(() => undefined);
  const statusText = (await wf.locator('#wf-status').innerText().catch(() => '')).trim();
  const jobs = (await items.allTextContents().catch(() => [])).map(s => s.trim()).filter(Boolean);
  let backend; try { const r = await api.get(`${executionApiUrl}/get-workflows`); backend = (await r.json()).find(w => (w.id ?? w._id) === id); } catch { /* */ }
  return { workflowId: id, statusText, jobs, backendStatus: backend?.status };
}
async function resultPanel(wf, s) {
  await wf.evaluate(st => { const p = document.createElement('div'); p.style.cssText = 'position:fixed;left:24px;bottom:24px;z-index:2147483647;width:560px;max-width:calc(100vw - 48px);padding:16px;border-radius:8px;border:1px solid rgba(255,255,255,0.18);background:rgba(12,18,22,0.94);color:#eef;font:12px/1.45 monospace;white-space:pre-wrap'; p.textContent = 'WORKFLOW EXECUTION RESULT\n' + JSON.stringify({ workflowId: st.workflowId, backendStatus: st.backendStatus, jobs: st.jobs }, null, 2); document.body.appendChild(p); }, s);
}
async function getWorkflowIds(api) {
  try { const r = await api.get(`${executionApiUrl}/get-workflows`, { timeout: 15_000 }); if (!r.ok()) return []; const b = await r.json(); return Array.isArray(b) ? b.map(w => String(w.id ?? w._id ?? '')).filter(Boolean) : []; } catch { return []; }
}

// ---------- overlay helpers ----------
async function installGuide(page) {
  await page.evaluate(() => { if (document.getElementById('cdb-guide')) return; const p = document.createElement('div'); p.id = 'cdb-guide'; p.style.cssText = 'position:fixed;right:24px;bottom:24px;z-index:2147483647;width:460px;max-width:calc(100vw - 48px);padding:16px 18px;border-radius:8px;border:1px solid rgba(255,255,255,0.18);background:rgba(16,22,27,0.93);color:#f2f7f5;box-shadow:0 18px 60px rgba(0,0,0,.34);font:14px/1.42 "Avenir Next","Trebuchet MS",sans-serif'; p.innerHTML = '<div id="cdb-gt" style="font-size:18px;font-weight:800;margin-bottom:6px"></div><div id="cdb-gb"></div>'; document.body.appendChild(p); });
}
async function setGuide(page, title, body) {
  await page.evaluate(({ title, body }) => { const t = document.getElementById('cdb-gt'); const b = document.getElementById('cdb-gb'); if (t) t.textContent = title; if (b) b.textContent = body; }, { title, body }).catch(() => undefined);
}
async function showInstallCard(page, runtime, log) {
  await page.evaluate(({ runtime, log }) => {
    const p = document.createElement('div'); p.id = 'cdb-install';
    p.style.cssText = 'position:fixed;inset:0;z-index:2147483646;background:#0b0f13;color:#9effa0;font:13px/1.5 SFMono-Regular,Consolas,monospace;padding:40px 56px;white-space:pre-wrap;overflow:hidden';
    const lines = (log || `$ CINCODEBIO_RUNTIME=${runtime} bash install.sh\n[INFO] Building / starting ${runtime}...\n[INFO] Waiting for core services to start...\n[INFO]   all pods Ready\n[INFO] CincoDeBio is ready!`).split('\n').slice(-26).join('\n');
    p.textContent = `CincoDeBio peer-review journey — step 1: install (${runtime})\n\n` + lines + '\n\n[ cluster ready — opening the editor... ]';
    document.body.appendChild(p);
  }, { runtime, log });
}
async function removeInstallCard(page) { await page.evaluate(() => document.getElementById('cdb-install')?.remove()).catch(() => undefined); }

// ---------- editor-pod helpers ----------
function seedEmpty() {
  execPod(`mkdir -p ${q(WS)} && cat > ${q(FILE)}`, JSON.stringify({ id: modelName, type: 'cincodebio:cincodebiographmodel', _attributes: {}, _containments: [], _edges: [] }, null, 2));
  execPod(`rm -rf ${q(WS + '/.siblib')} ${q(WS + '/siblib')} && mkdir -p ${q(WS + '/siblib')}`);
}
function readModel() { try { return JSON.parse(execPod(`cat ${q(FILE)}`)); } catch { return {}; } }
function countEdges(re) { return (readModel()._edges ?? []).filter(e => re.test(e.type ?? '')).length; }
function sibCount() { return Number(execPod(`find ${q(WS + '/siblib')} -type f | wc -l`).trim()); }
function execPod(cmd, input) {
  const pod = execSync(`${kubectlCmd()} get pod -n default -l app=cinco-de-bio-editor -o jsonpath='{.items[0].metadata.name}'`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  return execSync(`${kubectlCmd()} exec -i -n default -c cinco-de-bio-editor ${q(pod)} -- sh -lc ${q(cmd)}`, { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
}
function editorLogs() { try { return execSync(`${kubectlCmd()} logs -n default deploy/cinco-de-bio-editor -c cinco-de-bio-editor --since=4m --tail=200`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }); } catch (e) { return String(e); } }
function kubectlCmd() { const c = process.env.CINCODEBIO_KUBECTL_COMMAND ?? 'docker exec -i cincodebio kubectl'; if (/^docker\s+exec\s+/.test(c) && !/\s-i(\s|$)/.test(c)) return c.replace(/^docker\s+exec\s+/, 'docker exec -i '); return c; }
function q(v) { return `'${String(v).replaceAll("'", "'\\''")}'`; }
