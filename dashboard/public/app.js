/* PopoSafari 대시보드
 *
 * build.sh 가 구운 data/*.json 을 읽어 Chart.js 로 그린다. 서버 로직은 없다 —
 * 데이터가 하루 1회 갱신되므로 요청마다 DuckDB 를 때릴 이유가 없고, 그 덕에
 * Celeron N3150 에서 상시 도는 프로세스가 정적 파일 서버 하나로 끝난다.
 *
 * 기간 토글은 90일치를 다 받아두고 클라이언트가 잘라 쓴다. 90일 x 4지표가
 * 수십 KB 라 다시 굽는 것보다 이쪽이 싸다.
 */
'use strict';

const METRICS = ['bait_rock', 'dau', 'catch_rate', 'safari_session'];
const TITLES = {
  bait_rock: '미끼 · 돌',
  dau: 'DAU · 신규',
  catch_rate: '포획률',
  safari_session: '체류시간',
};
const STORE_KEY = 'poposafari.dashboard.v1';

const DEFAULTS = {
  range: 30,
  visible: Object.fromEntries(METRICS.map((m) => [m, true])),
  mode: {
    bait_rock: 'count',
    dau: 'dual',
    catch_rate: 'outcome',
    safari_session: 'dwell',
  },
  series: {},   // "카드:시리즈키" → boolean. 비어 있으면 전부 켜진 것으로 본다.
};

/* localStorage 는 사파리 프라이빗 모드 등에서 접근 자체가 던진다.
   대시보드가 안 뜨는 것보다 토글이 안 남는 게 낫다. */
function loadState() {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (!raw) return structuredClone(DEFAULTS);
    const saved = JSON.parse(raw);
    return {
      range: [7, 30, 90].includes(saved.range) ? saved.range : DEFAULTS.range,
      visible: Object.fromEntries(METRICS.map((metric) => [metric,
        typeof saved.visible?.[metric] === 'boolean' ? saved.visible[metric] : true])),
      mode: Object.fromEntries(METRICS.map((metric) => [metric,
        seriesSpec(metric, saved.mode?.[metric]).length ? saved.mode[metric] : DEFAULTS.mode[metric]])),
      series: Object.fromEntries(Object.entries(saved.series || {}).filter(([key, value]) =>
        typeof value === 'boolean' && METRICS.some((metric) => key.startsWith(metric + ':')))),
    };
  } catch {
    return structuredClone(DEFAULTS);
  }
}
function saveState() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch { /* 무시 */ }
}

let state = loadState();
const data = {};
const charts = {};

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

/* 각 카드가 어떤 시리즈를 갖는지. 모드마다 다르다. */
function seriesSpec(metric, mode) {
  switch (metric + ':' + mode) {
    case 'bait_rock:count':
      return [
        { key: 'bait_n', label: '미끼 사용', color: '--s-bait', type: 'bar' },
        { key: 'rock_n', label: '돌 사용', color: '--s-rock', type: 'bar' },
      ];
    case 'bait_rock:share':
      return [
        { key: 'bait_share', label: '미끼', color: '--s-bait', pct: true },
        { key: 'rock_share', label: '돌', color: '--s-rock', pct: true },
        { key: 'plain_share', label: '미사용', color: '--s-plain', pct: true },
      ];
    case 'bait_rock:effect':
      return [
        { key: 'bait_stay_rate', label: '미끼 후 잔류율', color: '--s-bait', pct: true },
        { key: 'rock_stay_rate', label: '돌 후 잔류율', color: '--s-rock', pct: true },
      ];
    case 'dau:dual':
    case 'dau:single':
      return [
        { key: 'dau', label: 'DAU', color: '--s-dau', type: 'bar' },
        { key: 'new_users', label: '신규 가입', color: '--s-new', type: 'line',
          axis: mode === 'dual' ? 'y2' : 'y' },
      ];
    case 'catch_rate:outcome':
      return [
        { key: 'caught', label: '성공', color: '--s-caught', type: 'bar', stack: 'o' },
        { key: 'broke_out', label: '빠져나감', color: '--s-break', type: 'bar', stack: 'o' },
        { key: 'fled', label: '도망', color: '--s-flee', type: 'bar', stack: 'o' },
      ];
    case 'catch_rate:rate':
      return [
        { key: 'catch_rate', label: '성공률', color: '--s-caught', pct: true },
        { key: 'break_out_rate', label: '빠져나감', color: '--s-break', pct: true },
        { key: 'flee_rate', label: '도망', color: '--s-flee', pct: true },
      ];
    case 'catch_rate:segment':
      return [
        { key: 'catch_rate_bait', label: '미끼 사용 시', color: '--s-bait', pct: true },
        { key: 'catch_rate_rock', label: '돌 사용 시', color: '--s-rock', pct: true },
        { key: 'catch_rate_plain', label: '미사용', color: '--s-plain', pct: true },
      ];
    case 'safari_session:dwell':
      return [
        { key: 'dwell_median_min', label: '중앙값(분)', color: '--s-dwell' },
        { key: 'dwell_p90_min', label: 'p90(분)', color: '--s-plain' },
      ];
    case 'safari_session:unclosed':
      return [
        { key: 'unclosed_rate', label: '퇴장 기록 없는 비율', color: '--s-warn', pct: true },
        { key: 'sessions', label: '세션 수', color: '--s-plain', type: 'bar', axis: 'y2' },
      ];
    default:
      return [];
  }
}

const seriesOn = (metric, key) => state.series[metric + ':' + key] !== false;

/* ── 렌더 ─────────────────────────────────────────────────────────── */

function sliceRows(metric) {
  const rows = data[metric] || [];
  const latest = METRICS.map((name) => data[name]?.at(-1)?.d || '').sort().at(-1);
  if (!latest) return [];
  const cutoff = new Date(Date.parse(latest + 'T00:00:00Z') - (state.range - 1) * 86400000)
    .toISOString().slice(0, 10);
  return rows.filter((row) => row.d >= cutoff && row.d <= latest);
}

function renderChart(metric) {
  const rows = sliceRows(metric);
  const spec = seriesSpec(metric, state.mode[metric]).filter((s) => seriesOn(metric, s.key));
  const box = document.querySelector(`[data-card="${metric}"] .plot`);
  const empty = box.querySelector('.empty');

  // 값이 하나도 없는 경우와 시리즈를 전부 꺼둔 경우를 구분해서 알려준다.
  // 빈 차트를 그대로 두면 "0인가, 아직 데이터가 없는 건가"를 알 수 없다.
  let msg = null;
  if (!rows.length) msg = '아직 데이터가 없습니다. 적재가 한 번이라도 돌았는지 확인하세요.';
  else if (!spec.length) msg = '표시할 시리즈를 하나 이상 켜세요.';
  else if (!spec.some((series) => rows.some((row) => Number.isFinite(row[series.key]))))
    msg = '계산할 수 있는 값이 없습니다. 분모가 없는 비율은 0%로 표시하지 않습니다.';

  empty.hidden = !msg;
  empty.textContent = msg || '';
  box.querySelector('canvas').style.visibility = msg ? 'hidden' : '';
  if (msg) {
    box.querySelector('canvas').setAttribute('aria-label', msg);
    return;
  }
  box.querySelector('canvas').setAttribute('aria-label',
    `${TITLES[metric]}, ${rows[0].d}부터 ${rows.at(-1).d}까지. 아래 요약과 표에서 값을 확인하세요.`);

  // 퍼센트 표기는 **왼쪽 축에 붙은 시리즈**만 보고 정한다. 보조축(y2)이 있다고
  // 왼쪽 축의 % 를 떼면, 0~40 이 비율인지 개수인지 알 수 없는 눈금이 된다.
  const useY2 = spec.some((s) => s.axis === 'y2');
  const leftPct = spec.some((s) => s.pct && s.axis !== 'y2');
  const grid = css('--border');
  const tick = css('--muted');

  const datasets = spec.map((s) => {
    const color = css(s.color);
    const isBar = (s.type || 'line') === 'bar';
    return {
      type: isBar ? 'bar' : 'line',
      label: s.label,
      data: rows.map((r) => (s.pct && r[s.key] !== null ? r[s.key] * 100 : r[s.key])),
      backgroundColor: isBar ? color : 'transparent',
      borderColor: color,
      borderWidth: isBar ? 0 : 2,
      pointRadius: 0,
      pointHoverRadius: 4,
      pointHitRadius: 12,
      tension: 0.25,
      // 값이 없는 날(NULL)은 선을 잇지 않는다. 0으로 이으면 "시도가 없어서
      // 알 수 없음"이 "0%"로 보인다.
      spanGaps: false,
      stack: s.stack,
      yAxisID: s.axis === 'y2' ? 'y2' : 'y',
      order: isBar ? 2 : 1,
    };
  });

  const config = {
    data: { labels: rows.map((r) => r.d), datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: { mode: currentSnapshot?.drilldown ? 'nearest' : 'index', intersect: false },
      onClick: (event, elements, chart) => {
        const point = elements[0];
        if (!point) return;
        chart.canvas.tabIndex = -1;
        UserDetails.open(currentSnapshot, metric, rows[point.index].d,
          spec[point.datasetIndex].key, spec[point.datasetIndex].label, chart.canvas);
      },
      plugins: {
        legend: { display: false },   // 시리즈 토글이 범례를 겸한다
        tooltip: {
          filter: (item, index) => !currentSnapshot?.drilldown || index === 0,
          callbacks: {
            afterLabel: (context) => UserDetails.preview(currentSnapshot, metric,
              rows[context.dataIndex].d, spec[context.datasetIndex].key),
            label: (c) => {
              const s = spec[c.datasetIndex];
              if (c.parsed.y === null) return `${c.dataset.label}: —`;
              return `${c.dataset.label}: ${s.pct ? c.parsed.y.toFixed(1) + '%' : c.parsed.y}`;
            },
          },
        },
      },
      scales: {
        x: {
          stacked: spec.some((s) => s.stack),
          grid: { display: false },
          ticks: { color: tick, maxRotation: 0, autoSkipPadding: 22 },
        },
        y: {
          stacked: spec.some((s) => s.stack),
          beginAtZero: true,
          suggestedMax: leftPct ? 100 : undefined,
          grid: { color: grid },
          border: { display: false },
          ticks: { color: tick, callback: (v) => (leftPct ? v + '%' : v) },
        },
        y2: {
          display: useY2,
          position: 'right',
          beginAtZero: true,
          grid: { display: false },
          border: { display: false },
          ticks: { color: tick },
        },
      },
    },
  };
  if (charts[metric]) {
    charts[metric].data = config.data;
    charts[metric].options = config.options;
    charts[metric].update('none');
    charts[metric].resize();
  } else {
    charts[metric] = new Chart(box.querySelector('canvas'), config);
  }
}

function renderNote(metric) {
  const el = document.querySelector(`[data-note-for="${metric}"]`);
  const rows = sliceRows(metric);
  el.classList.remove('warn');
  if (!rows.length) { el.textContent = ''; return; }

  const sum = (k) => rows.reduce((a, r) => a + (r[k] || 0), 0);

  if (metric === 'bait_rock') {
    const att = sum('attempts');
    const share = att ? ((sum('attempts_bait') + sum('attempts_rock')) / att) * 100 : null;
    el.textContent = share === null
      ? '기간 내 포획 시도가 없어 사용 비율을 낼 수 없습니다.'
      : `기간 합계 — 미끼 ${sum('bait_n')}회 · 돌 ${sum('rock_n')}회. `
        + `포획 시도 ${att}건 중 ${share.toFixed(1)}%가 미끼나 돌을 쓴 상태였습니다.`;
    return;
  }

  if (metric === 'dau') {
    el.textContent = `기간 합계 — 신규 가입 ${sum('new_users')}명. `
      + `DAU 최고 ${Math.max(...rows.map((r) => r.dau))}명.`;
    return;
  }

  if (metric === 'catch_rate') {
    const att = sum('attempts');
    const gap = rows.reduce((a, r) => a + Math.abs(r.caught_gap || 0), 0);
    let t = att
      ? `기간 합계 — 시도 ${att}건, 성공 ${sum('caught')}건 (${((sum('caught') / att) * 100).toFixed(1)}%).`
      : '기간 내 포획 시도가 없습니다.';
    // 성공은 관측이 아니라 역산이다(POKEMON_CATCH 에 wildUid 가 없다).
    // 그 오차를 숨기지 않고 같이 보여준다.
    if (gap) {
      t += ` 역산 성공과 실제 기록의 차이 ${gap}건`
        + (att && gap / att > 0.1 ? ' — 10%를 넘습니다. 서버 쪽 감사로그를 확인하세요.' : ' (역산 오차).');
      if (att && gap / att > 0.1) el.classList.add('warn');
    }
    el.textContent = t;
    return;
  }

  if (metric === 'safari_session') {
    const s = sum('sessions');
    const unclosed = s ? ((s - sum('closed_sessions')) / s) * 100 : null;
    el.textContent = s
      ? `기간 합계 — 세션 ${s}건, 그중 ${unclosed.toFixed(1)}%는 퇴장 기록이 없습니다 `
        + '(창 닫기·연결 끊김. 정상적으로 발생합니다).'
      : '기간 내 사파리 입장 기록이 없습니다.';
  }
}

function renderSeriesToggles(metric) {
  const host = document.querySelector(`[data-series-for="${metric}"]`);
  host.innerHTML = '';
  for (const s of seriesSpec(metric, state.mode[metric])) {
    const b = document.createElement('button');
    b.className = 'chip';
    b.setAttribute('aria-pressed', String(seriesOn(metric, s.key)));
    b.innerHTML = `<span class="swatch" style="background:${css(s.color)}"></span>${s.label}`;
    b.onclick = () => {
      state.series[metric + ':' + s.key] = !seriesOn(metric, s.key);
      saveState();
      b.setAttribute('aria-pressed', String(seriesOn(metric, s.key)));
      renderChart(metric);
      renderTable(metric);
    };
    host.appendChild(b);
  }
}

function renderCard(metric) {
  const card = document.querySelector(`[data-card="${metric}"]`);
  card.hidden = !state.visible[metric];
  document.querySelectorAll(`[data-mode-for="${metric}"] button`).forEach((b) => {
    b.setAttribute('aria-pressed', String(b.dataset.mode === state.mode[metric]));
  });
  if (card.hidden) return;
  renderSeriesToggles(metric);
  renderChart(metric);
  renderNote(metric);
  renderTable(metric);
}

function renderTable(metric) {
  const host = document.querySelector(`[data-table-for="${metric}"]`);
  if (!host.closest('details').open) return;
  const spec = seriesSpec(metric, state.mode[metric]).filter((series) => seriesOn(metric, series.key));
  host.replaceChildren();
  if (!spec.length) return;
  const table = document.createElement('table');
  const caption = table.createCaption();
  caption.textContent = `${TITLES[metric]} 일별 데이터`;
  const heading = table.createTHead().insertRow();
  for (const label of ['날짜', ...spec.map((series) => series.label)]) {
    const cell = document.createElement('th');
    cell.scope = 'col';
    cell.textContent = label;
    heading.appendChild(cell);
  }
  const body = table.createTBody();
  for (const row of sliceRows(metric)) {
    const record = body.insertRow();
    record.insertCell().textContent = row.d;
    for (const series of spec) {
      const value = row[series.key];
      const cell = record.insertCell();
      cell.textContent = value === null ? '—' : series.pct
        ? (value * 100).toFixed(1) + '%' : number.format(value);
      if (UserDetails.group(currentSnapshot, metric, row.d, series.key)) {
        const button = document.createElement('button');
        button.className = 'user-link';
        button.textContent = '유저 보기';
        button.setAttribute('aria-label', `${row.d} ${series.label} 유저 보기`);
        button.onclick = () => UserDetails.open(currentSnapshot, metric, row.d, series.key, series.label, button);
        cell.appendChild(button);
      }
    }
  }
  host.appendChild(table);
}

const number = new Intl.NumberFormat('ko-KR', { maximumFractionDigits: 1 });

function renderSummary() {
  const daily = sliceRows('dau');
  const attempts = sliceRows('catch_rate');
  const sum = (rows, key) => rows.reduce((total, row) => total + (row[key] || 0), 0);
  const count = sum(attempts, 'attempts');
  const values = {
    dau: daily.length ? number.format(sum(daily, 'dau') / daily.length) : '—',
    new_users: daily.length ? number.format(sum(daily, 'new_users')) : '—',
    attempts: attempts.length ? number.format(count) : '—',
    catch_rate: count ? (sum(attempts, 'caught') / count * 100).toFixed(1) + '%' : '—',
  };
  for (const [key, value] of Object.entries(values)) {
    document.querySelector(`[data-summary="${key}"]`).textContent = value;
  }
  document.getElementById('summary-period').textContent = `최근 ${state.range}일 · 한국 시간(KST) · 데이터가 제공된 날짜 기준`;
  document.getElementById('all-hidden').hidden = METRICS.some((metric) => state.visible[metric]);
}

function renderAll() {
  document.querySelectorAll('#range-seg button').forEach((b) => {
    b.setAttribute('aria-pressed', String(Number(b.dataset.range) === state.range));
  });
  document.querySelectorAll('#visible-chips .chip').forEach((b) => {
    b.setAttribute('aria-pressed', String(!!state.visible[b.dataset.metric]));
  });
  METRICS.forEach(renderCard);
  renderSummary();
}

function renderMeta(meta, builtAt) {
  const el = document.getElementById('meta');
  if (!meta) { el.textContent = '메타데이터를 읽지 못했습니다.'; return; }

  const loaded = meta.last_load_at ? meta.last_load_at.slice(0, 16) : '없음';
  // 적재는 하루 1회다. 36시간을 넘으면 cron 이 멎었거나 적재가 실패하고 있다.
  const ageH = meta.last_load_at
    ? (Date.now() - Date.parse(meta.last_load_at.replace(' ', 'T') + 'Z')) / 3.6e6
    : Infinity;
  const stale = ageH > 36;

  el.replaceChildren();
  const lines = [
    `마지막 적재 ${loaded} UTC` + (stale
      ? (Number.isFinite(ageH) ? ` (${Math.floor(ageH)}시간 전 · 갱신 지연)` : ' · 아직 적재 기록이 없습니다') : ''),
    `최근 이벤트 ${meta.latest_event_utc?.slice(0, 16) || '없음'} UTC`,
    `총 ${number.format(meta.total_rows || 0)}행 · 직전 적재 +${number.format(meta.last_inserted || 0)} / 객체 ${number.format(meta.last_files || 0)}`,
  ];
  lines.forEach((line, index) => {
    const row = document.createElement('div');
    row.textContent = line;
    if (index === 0 && stale) row.className = 'stale';
    el.appendChild(row);
  });

  document.getElementById('built').textContent = builtAt ? `빌드 ${builtAt.trim()}` : '';
}

/* ── 초기화 ───────────────────────────────────────────────────────── */

async function getJSON(path) {
  // cache: 'no-store' — 매일 같은 URL 로 내용만 바뀐다. 브라우저 캐시를 믿으면
  // 어제 숫자를 오늘 것으로 착각하게 된다.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(path, { cache: 'no-store', signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

let currentSnapshot = null;
let refreshTimer = null;
let refreshing = false;

function validateSnapshot(snapshot) {
  if (snapshot.schema_version !== 1 || !Number.isFinite(Date.parse(snapshot.built_at))
      || !Array.isArray(snapshot.meta) || snapshot.meta.length !== 1
      || typeof snapshot.meta[0] !== 'object' || !snapshot.meta[0]) {
    throw new Error('지원하지 않는 데이터 형식');
  }
  const meta = snapshot.meta[0];
  for (const key of ['last_load_at', 'latest_event_utc']) {
    if (meta[key] !== null && (typeof meta[key] !== 'string'
        || !Number.isFinite(Date.parse(meta[key].replace(' ', 'T') + 'Z')))) {
      throw new Error('집계 기준 시각 오류');
    }
  }
  for (const key of ['total_rows', 'last_inserted', 'last_files', 'master_pokemon_rows']) {
    if (meta[key] !== null && (!Number.isInteger(meta[key]) || meta[key] < 0)) {
      throw new Error('집계 메타데이터 오류');
    }
  }
  if (typeof meta.master_sha !== 'string') throw new Error('집계 메타데이터 오류');
  for (const metric of METRICS) {
    const rows = snapshot[metric];
    const modes = [...document.querySelectorAll(`[data-mode-for="${metric}"] button`)]
      .map((button) => button.dataset.mode);
    const keys = new Set(modes.flatMap((mode) => seriesSpec(metric, mode).map((series) => series.key)));
    const extra = { bait_rock: ['attempts', 'attempts_bait', 'attempts_rock'],
      dau: [], catch_rate: ['attempts', 'caught_gap'], safari_session: ['closed_sessions', 'sessions'] };
    extra[metric].forEach((key) => keys.add(key));
    if (!Array.isArray(rows) || rows.length > 90) throw new Error(`${TITLES[metric]} 데이터 형식 오류`);
    let previous = '';
    for (const row of rows) {
      if (!row || !/^\d{4}-\d{2}-\d{2}$/.test(row.d) || !Number.isFinite(Date.parse(row.d))
          || new Date(row.d).toISOString().slice(0, 10) !== row.d
          || (previous && Date.parse(row.d) - Date.parse(previous) !== 86400000)
          || [...keys].some((key) => row[key] !== null && !Number.isFinite(row[key]))) {
        throw new Error(`${TITLES[metric]} 데이터 검증 실패`);
      }
      previous = row.d;
    }
  }
}

async function refreshSnapshot() {
  clearTimeout(refreshTimer);
  if (document.hidden || refreshing) return;
  refreshing = true;
  const status = document.getElementById('refresh-status');
  try {
    const snapshot = await getJSON('data/snapshot.json');
    validateSnapshot(snapshot);
    UserDetails.validate(snapshot);
    const changed = METRICS.filter((metric) => JSON.stringify(data[metric]) !== JSON.stringify(snapshot[metric])
      || currentSnapshot?.drilldown?.build_id !== snapshot.drilldown?.build_id);
    const previousEnd = METRICS.map((metric) => data[metric]?.at(-1)?.d || '').sort().at(-1);
    METRICS.forEach((metric) => { data[metric] = snapshot[metric]; });
    const nextEnd = METRICS.map((metric) => data[metric]?.at(-1)?.d || '').sort().at(-1);
    currentSnapshot = snapshot;
    renderMeta(snapshot.meta[0], snapshot.built_at);
    (previousEnd !== nextEnd ? METRICS : changed).forEach(renderCard);
    if (changed.length) renderSummary();
    const age = snapshot.meta[0].last_load_at
      ? Date.now() - Date.parse(snapshot.meta[0].last_load_at.replace(' ', 'T') + 'Z') : Infinity;
    status.textContent = age > 36 * 3600000 ? '적재 지연 · 마지막 데이터를 표시합니다' : '일일 배치 · 최신 빌드 확인됨';
    status.dataset.state = age > 36 * 3600000 ? 'warn' : 'ok';
  } catch (error) {
    if (!currentSnapshot) document.getElementById('meta').textContent = '집계 기준을 확인할 수 없습니다.';
    status.textContent = currentSnapshot
      ? '새 데이터 확인 실패 · 마지막 정상 데이터를 유지합니다'
      : '데이터를 불러오지 못했습니다. 빌드 상태를 확인하거나 다시 시도하세요.';
    status.dataset.state = 'error';
  } finally {
    refreshing = false;
    if (!document.hidden) refreshTimer = setTimeout(refreshSnapshot, 60000);
  }
}

async function init() {
  const chips = document.getElementById('visible-chips');
  for (const m of METRICS) {
    const b = document.createElement('button');
    b.className = 'chip';
    b.dataset.metric = m;
    b.textContent = TITLES[m];
    b.onclick = () => {
      state.visible[m] = !state.visible[m];
      saveState();
      b.setAttribute('aria-pressed', String(state.visible[m]));
      renderCard(m);
      renderSummary();
    };
    chips.appendChild(b);
  }

  document.querySelectorAll('#range-seg button').forEach((b) => {
    b.onclick = () => { state.range = Number(b.dataset.range); saveState(); renderAll(); };
  });

  document.querySelectorAll('[data-mode-for]').forEach((seg) => {
    const metric = seg.dataset.modeFor;
    seg.querySelectorAll('button').forEach((b) => {
      b.onclick = () => {
        state.mode[metric] = b.dataset.mode;
        // 모드가 바뀌면 시리즈 구성이 통째로 달라진다. 이전 모드에서 꺼둔
        // 시리즈 상태를 끌고 오면 새 차트가 빈 채로 뜬다.
        for (const k of Object.keys(state.series)) {
          if (k.startsWith(metric + ':')) delete state.series[k];
        }
        saveState();
        renderCard(metric);
      };
    });
  });

  document.getElementById('reset').onclick = () => {
    state = structuredClone(DEFAULTS);
    saveState();
    renderAll();
  };

  renderAll();
  document.getElementById('refresh').onclick = refreshSnapshot;
  document.querySelectorAll('.data-details').forEach((details) => {
    details.addEventListener('toggle', () => {
      if (details.open) renderTable(details.closest('[data-card]').dataset.card);
    });
  });
  document.addEventListener('visibilitychange', () => {
    clearTimeout(refreshTimer);
    if (!document.hidden) refreshSnapshot();
  });
  await refreshSnapshot();
}

// 시스템 테마가 바뀌면 차트 색도 따라가야 한다 (CSS 변수에서 읽으므로 다시 그린다).
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', renderAll);

init();
