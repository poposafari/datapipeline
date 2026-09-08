const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const publicDirectory = path.join(__dirname, 'public');
  const snapshot = JSON.parse(fs.readFileSync(path.join(process.env.DATA_DIR, 'snapshot.json'), 'utf8'));
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/data/snapshot.json') {
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify(snapshot));
      return;
    }
    if (pathname.startsWith('/data/details/')) {
      const root = path.resolve(process.env.DATA_DIR);
      const filename = path.resolve(root, '.' + pathname.slice('/data'.length));
      if (!filename.startsWith(root + path.sep) || !fs.existsSync(filename) || !fs.statSync(filename).isFile()) {
        response.writeHead(404).end();
        return;
      }
      response.setHeader('Content-Type', 'application/json');
      response.end(fs.readFileSync(filename));
      return;
    }
    const filename = path.resolve(publicDirectory, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!filename.startsWith(publicDirectory + path.sep) || !fs.existsSync(filename)) {
      response.writeHead(404).end();
      return;
    }
    response.setHeader('Content-Type', { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' }[path.extname(filename)] || 'application/octet-stream');
    response.end(fs.readFileSync(filename));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({ channel: 'chrome', headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, colorScheme: 'light' });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.clock.install();
    await page.addInitScript(() => localStorage.setItem('poposafari.dashboard.v1', JSON.stringify({
      range: 999, visible: { dau: 'bad' }, mode: { dau: 'bad' }, series: { 'dau:dau': 'bad' },
    })));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction(() => document.querySelector('#refresh-status').dataset.state === 'ok');
    if (snapshot.drilldown) {
      let detailRequests = 0;
      page.on('request', (request) => { if (request.url().includes('/data/details/')) detailRequests += 1; });
      const date = snapshot.dau.at(-1).d;
      const entry = snapshot.drilldown.metrics.dau[date].active;
      await page.locator('[data-card="dau"] canvas').scrollIntoViewIfNeeded();
      const position = await page.evaluate(() => {
        const chart = charts.dau;
        const point = chart.getDatasetMeta(0).data.at(-1);
        const bounds = chart.canvas.getBoundingClientRect();
        return { x: bounds.x + point.x, y: bounds.y + (point.y + point.base) / 2 };
      });
      await page.mouse.move(position.x, position.y);
      await page.waitForFunction(() => charts.dau.tooltip?.body?.some((body) => body.after.some((line) => line.includes('관련 유저'))));
      assert.equal(await page.evaluate(() => charts.dau.tooltip.body.length), 1);
      assert.equal(detailRequests, 0);
      await page.mouse.click(position.x, position.y);
      await page.locator('.user-dialog').waitFor({ state: 'visible' });
      await page.waitForFunction(() => document.querySelector('#users-status').textContent.includes('관련 건수순'));
      assert.equal(await page.locator('#users-rows tr').count(), Math.min(entry.total_users, 50));
      if (entry.preview.length) {
        await page.locator('#users-search').fill(entry.preview[0].account_id);
        assert(await page.locator('#users-rows tr').count() >= 1);
      }
      await page.locator('#users-search').fill('nonexistent');
      assert.match(await page.locator('#users-status').textContent(), /일치하는 ID/);
      const pinnedBuild = await page.locator('#users-build').textContent();
      const original = structuredClone(snapshot.drilldown);
      snapshot.drilldown.build_id = 'f'.repeat(32);
      for (const dates of Object.values(snapshot.drilldown.metrics)) {
        for (const groups of Object.values(dates)) {
          for (const value of Object.values(groups)) value.path = value.path.replace(original.build_id, snapshot.drilldown.build_id);
        }
      }
      await page.evaluate(() => refreshSnapshot());
      assert.equal(await page.locator('#users-build').textContent(), pinnedBuild);
      snapshot.drilldown = original;
      await page.keyboard.press('Escape');
      await page.locator('.user-dialog').waitFor({ state: 'hidden' });
      assert.equal(await page.locator('.user-dialog').isVisible(), false);
      await page.evaluate(() => refreshSnapshot());

      await page.route('**/data/details/**', (route) => route.fulfill({ status: 404, body: '' }));
      await page.locator('[data-card="dau"] .data-details summary').click();
      const trigger = page.getByRole('button', { name: `${date} DAU 유저 보기`, exact: true });
      await trigger.click();
      await page.waitForFunction(() => document.querySelector('#users-status').textContent.includes('만료'));
      await page.unroute('**/data/details/**');
      await page.getByRole('button', { name: '다시 시도', exact: true }).click();
      await page.waitForFunction(() => document.querySelector('#users-status').textContent.includes('관련 건수순'));
      await page.keyboard.press('Escape');
      assert.equal(await trigger.evaluate((button) => button === document.activeElement), true);
      const active = snapshot.drilldown.metrics.dau[date].active;
      const savedActive = structuredClone(active);
      const manyUsers = Array.from({ length: 125 }, (_, index) => ({ account_id: String(700000 + index), count: 1 }));
      active.total_users = manyUsers.length;
      active.preview = manyUsers.slice(0, 10);
      const payload = JSON.parse(fs.readFileSync(path.join(process.env.DATA_DIR, active.path), 'utf8'));
      payload.groups.active.users = manyUsers;
      await page.route('**/data/details/**', (route) => route.fulfill({ json: payload }));
      await page.evaluate(() => refreshSnapshot());
      await trigger.click();
      await page.waitForFunction(() => document.querySelectorAll('#users-rows tr').length === 50);
      await page.getByRole('button', { name: '다음', exact: true }).click();
      assert.equal(await page.locator('#users-page').textContent(), '2 / 3');
      await page.getByRole('button', { name: '다음', exact: true }).click();
      assert.equal(await page.locator('#users-rows tr').count(), 25);
      await page.locator('#users-search').fill('700123');
      assert.equal(await page.locator('#users-rows tr').count(), 1);
      assert.equal(await page.locator('#users-page').textContent(), '1 / 1');
      await page.setViewportSize({ width: 390, height: 844 });
      assert(await page.locator('.user-dialog').evaluate((element) => element.scrollWidth <= element.clientWidth));
      const panelArtifacts = process.env.ARTIFACTS || '/tmp/popo-browser';
      fs.mkdirSync(panelArtifacts, { recursive: true });
      await page.screenshot({ path: path.join(panelArtifacts, 'users-mobile.png') });
      await page.keyboard.press('Escape');
      await page.setViewportSize({ width: 1440, height: 1100 });
      await page.unroute('**/data/details/**');
      snapshot.drilldown.metrics.dau[date].active = savedActive;
      await page.evaluate(() => refreshSnapshot());
      await page.locator('[data-card="dau"] .data-details summary').click();
      const savedDetails = snapshot.drilldown;
      delete snapshot.drilldown;
      await page.evaluate(() => refreshSnapshot());
      assert.equal(await page.evaluate(() => UserDetails.group(currentSnapshot, 'dau', currentSnapshot.dau.at(-1).d, 'dau')), null);
      snapshot.drilldown = savedDetails;
      await page.evaluate(() => refreshSnapshot());
    }
    assert.equal(await page.getByRole('button', { name: '30일', exact: true }).getAttribute('aria-pressed'), 'true');
    assert.equal(await page.locator('canvas:visible').count(), 4);
    await page.evaluate(() => { window.originalCharts = Object.fromEntries(Object.entries(charts).map(([key, chart]) => [key, chart.id])); });
    await page.getByRole('button', { name: '7일', exact: true }).click();
    assert(await page.evaluate(() => charts.dau.data.labels.length <= 7));
    await page.getByRole('button', { name: '단일 축', exact: true }).click();
    assert.equal(await page.evaluate(() => charts.dau.options.scales.y2.display), false);
    await page.locator('[data-series-for="dau"]').getByRole('button', { name: 'DAU', exact: true }).click();
    assert.equal(await page.evaluate(() => charts.dau.data.datasets.length), 1);
    await page.locator('[data-card="dau"] .data-details summary').click();
    await page.locator('[data-table-for="dau"] table').waitFor();
    assert.equal(await page.locator('[data-table-for="dau"] table').count(), 1);
    await page.getByRole('button', { name: '미끼 · 돌', exact: true }).click();
    assert.equal(await page.locator('[data-card="bait_rock"]').isVisible(), false);
    await page.getByRole('button', { name: '미끼 · 돌', exact: true }).click();
    await page.getByRole('button', { name: '미완결 비율', exact: true }).click();
    assert.equal(await page.evaluate(() => charts.safari_session.options.scales.y.ticks.callback(25)), '25%');
    assert(await page.evaluate(() => Object.entries(charts).every(([key, chart]) => chart.id === window.originalCharts[key])));
    await page.getByRole('button', { name: '보기 설정 초기화', exact: true }).click();

    const summary = await page.locator('[data-summary="dau"]').textContent();
    await page.route('**/data/snapshot.json', (route) => route.abort());
    await page.getByRole('button', { name: '새로고침', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('#refresh-status').dataset.state === 'error');
    assert.equal(await page.locator('[data-summary="dau"]').textContent(), summary);
    assert.equal(await page.locator('canvas:visible').count(), 4);
    await page.unroute('**/data/snapshot.json');
    await page.getByRole('button', { name: '새로고침', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('#refresh-status').dataset.state === 'ok');

    snapshot.dau.at(-1).dau += 100;
    await page.clock.fastForward(61000);
    await page.waitForFunction((previous) => document.querySelector('[data-summary="dau"]').textContent !== previous, summary);
    const refreshed = await page.locator('[data-summary="dau"]').textContent();
    await page.evaluate(() => {
      Object.defineProperty(document, 'hidden', { value: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    snapshot.dau.at(-1).dau += 100;
    await page.clock.fastForward(120000);
    assert.equal(await page.locator('[data-summary="dau"]').textContent(), refreshed);
    await page.evaluate(() => {
      Object.defineProperty(document, 'hidden', { value: false, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction((previous) => document.querySelector('[data-summary="dau"]').textContent !== previous, refreshed);

    snapshot.dau.at(-1).dau -= 200;
    await page.getByRole('button', { name: '새로고침', exact: true }).click();
    await page.waitForFunction((original) => document.querySelector('[data-summary="dau"]').textContent === original, summary);
    await page.locator('[data-card="dau"] .data-details summary').click();

    const artifacts = process.env.ARTIFACTS || '/tmp/popo-browser';
    fs.mkdirSync(artifacts, { recursive: true });
    await page.screenshot({ path: path.join(artifacts, 'desktop.png'), fullPage: true });
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.screenshot({ path: path.join(artifacts, 'dark.png'), fullPage: true });
    for (const width of [390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), `overflow at ${width}px`);
    }
    await page.emulateMedia({ colorScheme: 'light' });
    await page.screenshot({ path: path.join(artifacts, 'mobile.png'), fullPage: true });
    const originalMeta = snapshot.meta[0].latest_event_utc;
    snapshot.meta[0].latest_event_utc = 123;
    await page.getByRole('button', { name: '새로고침', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('#refresh-status').dataset.state === 'error');
    assert.equal(await page.locator('[data-summary="dau"]').textContent(), summary);
    snapshot.meta[0].latest_event_utc = originalMeta;
    for (const metric of ['bait_rock', 'dau', 'catch_rate', 'safari_session']) {
      for (const row of snapshot[metric]) {
        for (const key of Object.keys(row)) if (key !== 'd') row[key] = 0;
      }
    }
    await page.getByRole('button', { name: '새로고침', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('[data-summary="dau"]').textContent === '0');
    assert.equal(await page.locator('canvas:visible').count(), 4);
    snapshot.safari_session.forEach((row) => { row.dwell_median_min = null; row.dwell_p90_min = null; });
    await page.getByRole('button', { name: '새로고침', exact: true }).click();
    await page.waitForFunction(() => !document.querySelector('[data-card="safari_session"] .empty').hidden);
    assert.match(await page.locator('[data-card="safari_session"] .empty').textContent(), /계산할 수/);
    for (const title of ['미끼 · 돌', 'DAU · 신규', '포획률', '체류시간']) {
      await page.locator('#visible-chips').getByRole('button', { name: title, exact: true }).click();
    }
    assert.equal(await page.locator('#all-hidden').isVisible(), true);
    assert.deepEqual(errors, []);
    console.log('PASS: user hover, lazy details, search, pagination, pinned build, expired/retry, focus, legacy, mobile; settings, chart reuse, recovery, polling, themes, zero/null');
    console.log(`Screenshots: ${artifacts}`);
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
