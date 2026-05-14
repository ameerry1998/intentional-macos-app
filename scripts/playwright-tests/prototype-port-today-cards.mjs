// Playwright test: dashboard.html Today page renders weekly-goal cards from
// seeded bridge data, cards are clickable + open the full-page editor, and
// the grip is draggable. Runs against dashboard.html via file://.

import { chromium } from 'playwright';
import { mkdirSync, writeFileSync } from 'fs';
import { resolve } from 'path';

const OUT = '/tmp/intentional-pw/prototype-port-today';
mkdirSync(OUT, { recursive: true });

const DASHBOARD = 'file://' + resolve(process.cwd(), '../../Intentional/dashboard.html');

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
const page = await ctx.newPage();

const logs = [];
page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));

await ctx.addInitScript(() => { window.__INTENTIONAL_TEST_MODE = true; });
await page.goto(DASHBOARD);
await page.waitForLoadState('domcontentloaded');
await page.waitForTimeout(600);

let passed = 0, failed = 0;
function assert(cond, msg) {
  if (cond) { logs.push(`  PASS ${msg}`); passed++; }
  else { logs.push(`  FAIL ${msg}`); failed++; }
}

// Inject seed data BEFORE any timed renders fire.
await page.evaluate(() => {
  const week = (() => {
    const d = new Date();
    const day = d.getDay() || 7;
    d.setDate(d.getDate() - (day - 1));
    return d.toISOString().slice(0, 10);
  })();
  if (typeof window._monthlyGoalsList === 'function') {
    window._monthlyGoalsList([
      { id: 'm1', title: 'Ship Puck', outcome: '25 paid', color_hex: '#D85A30', month_of: '2026-05-01', status: 'in_progress', version: 1 },
      { id: 'm2', title: '4hr deep work', outcome: '20 weekdays', color_hex: '#1D9E75', month_of: '2026-05-01', status: 'planned', version: 1 },
    ]);
  }
  if (typeof window._intentionsList === 'function') {
    window._intentionsList([
      { id: 'wg1', name: 'Record 3 demos', outcome: 'Posted to IG by Sun', status: 'in_progress',
        week_of: week, monthly_goal_id: 'm1', mac_websites: [], mac_bundle_ids: [],
        allow_websites: [], allow_bundle_ids: [], strictness_preset: 'strict',
        ai_scoring_enabled: true, intent_text: 'Recording demo videos.', version: 1,
        description: '', color_hex: null, icon: null, hours_done: 0, weekly_target_hours: 4 },
      { id: 'wg2', name: 'Block phone 9-5', outcome: 'Zero scrolls', status: 'planned',
        week_of: week, monthly_goal_id: 'm2', mac_websites: ['instagram.com'], mac_bundle_ids: [],
        allow_websites: [], allow_bundle_ids: [], strictness_preset: 'strict',
        ai_scoring_enabled: true, intent_text: '', version: 1,
        description: '', color_hex: null, icon: null, hours_done: 0, weekly_target_hours: null },
    ]);
  }
});

await page.waitForTimeout(300);
await page.screenshot({ path: `${OUT}/01-today-with-cards.png` });

// 1. Sidebar nav check
const planNav = await page.locator('.sidebar-item[data-page="plan"]').count();
assert(planNav === 1, `Plan nav item exists (count=${planNav})`);
const focusModesNav = await page.locator('.sidebar-item[data-page="intentions"]').count();
assert(focusModesNav === 0, `Focus Modes nav removed (count=${focusModesNav})`);
const blockingPill = await page.locator('#sb-blocking').isVisible().catch(() => false);
assert(blockingPill, 'Blocking pill visible bottom-left');
const themeToggle = await page.locator('#theme-toggle-btn').count();
assert(themeToggle === 0, `Theme toggle skipped per goal command (count=${themeToggle})`);

// 2. Weekly goal cards rendered
const cards = await page.locator('.wg-card').count();
assert(cards >= 2, `at least 2 wg-cards rendered (got ${cards})`);

// 3. First card has the expected title
const firstTitle = await page.locator('.wg-card .wg-ttl').first().textContent();
assert((firstTitle || '').trim() === 'Record 3 demos', `first card title (got "${firstTitle}")`);

// 4. Grip is draggable
const gripDraggable = await page.locator('.wg-card .wg-grip').first().getAttribute('draggable');
assert(gripDraggable === 'true', `grip is draggable (got "${gripDraggable}")`);

// 5. Clicking the card body opens the editor
await page.locator('.wg-card').first().click();
await page.waitForTimeout(400);
await page.screenshot({ path: `${OUT}/02-editor-opened.png` });
// Check the mount has rendered content
const editorContent = await page.locator('#goal-edit-mount .ge-page').count();
assert(editorContent === 1, `editor full page rendered (#goal-edit-mount .ge-page count=${editorContent})`);

// 6. Back button returns to Today
await page.locator('.ge-back').click();
await page.waitForTimeout(300);
const todayVisible = await page.locator('#now-card-mount').isVisible().catch(() => false);
assert(todayVisible, 'back returned to Today (now-card-mount visible)');
await page.screenshot({ path: `${OUT}/03-back-to-today.png` });

logs.push(`\n=== SUMMARY: ${passed} passed, ${failed} failed ===`);
writeFileSync(`${OUT}/console.log`, logs.join('\n'));
console.log(logs.join('\n'));

await browser.close();
process.exit(failed > 0 ? 1 : 0);
