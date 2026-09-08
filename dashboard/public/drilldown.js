'use strict';

const UserDetails = (() => {
  const dialog = document.createElement('dialog');
  dialog.className = 'user-dialog';
  dialog.setAttribute('aria-labelledby', 'users-title');
  dialog.innerHTML = `<header class="user-head"><div><h2 id="users-title">관련 유저</h2><p id="users-context"></p></div><button class="quiet" id="users-close" aria-label="유저 상세 닫기">닫기</button></header>
    <p id="users-description"></p><p id="users-build"></p>
    <label class="user-search">유저 ID 검색<input id="users-search" type="search" autocomplete="off" placeholder="account_id 입력"></label>
    <p id="users-status" role="status"></p><button id="users-retry" class="quiet" hidden>다시 시도</button>
    <div class="user-table"><table><caption class="sr-only">관련 유저 목록</caption><thead><tr><th scope="col">유저 ID (account_id)</th><th scope="col">관련 건수</th></tr></thead><tbody id="users-rows"></tbody></table></div>
    <nav class="user-pages" aria-label="유저 목록 페이지"><button id="users-prev" class="quiet">이전</button><span id="users-page"></span><button id="users-next" class="quiet">다음</button></nav>`;
  document.body.appendChild(dialog);
  const find = (id) => dialog.querySelector('#users-' + id);
  let selected = null;
  let users = [];
  let page = 0;
  let loaded = false;
  let request = null;
  let opener = null;

  function group(snapshot, metric, date, series) {
    const groups = snapshot?.drilldown?.metrics?.[metric]?.[date];
    if (!groups) return null;
    const entry = Object.entries(groups).find(([, value]) => value.series.includes(series));
    return entry ? { key: entry[0], ...entry[1] } : null;
  }

  function preview(snapshot, metric, date, series) {
    const entry = group(snapshot, metric, date, series);
    if (!entry) return [];
    const lines = [`관련 유저 ${entry.total_users.toLocaleString()}명`, ...entry.preview.map((user) => `ID ${user.account_id} · ${user.count}건`)];
    if (entry.total_users > 10) lines.push(`외 ${entry.total_users - 10}명`);
    if (entry.unidentified_records) lines.push(`계정 식별 불가 기록 ${entry.unidentified_records}건`);
    lines.push('클릭하여 전체 목록 보기');
    return lines;
  }

  function validate(snapshot) {
    if (!snapshot.drilldown) return;
    const details = snapshot.drilldown;
    if (!/^[0-9a-f]{32}$/.test(details.build_id) || !details.metrics) throw new Error('유저 상세 형식 오류');
    for (const metric of ['dau', 'bait_rock', 'catch_rate', 'safari_session']) {
      const dates = details.metrics[metric];
      if (!dates || Object.keys(dates).length !== snapshot[metric].length) throw new Error('유저 상세 날짜 오류');
      for (const row of snapshot[metric]) {
        const entries = dates[row.d];
        if (!entries || !Object.keys(entries).length) throw new Error('유저 상세 그룹 오류');
        for (const entry of Object.values(entries)) {
          if (!entry || !Array.isArray(entry.series) || !entry.series.length
              || entry.series.some((series) => typeof series !== 'string') || typeof entry.label !== 'string'
              || entry.path !== `details/${details.build_id}/${metric}/${row.d}.json`
              || !Number.isSafeInteger(entry.total_users) || entry.total_users < 0
              || !Number.isSafeInteger(entry.unidentified_records) || entry.unidentified_records < 0
              || !Array.isArray(entry.preview) || entry.preview.length !== Math.min(10, entry.total_users)) {
            throw new Error('유저 미리보기 오류');
          }
          const seen = new Set();
          for (const user of entry.preview) {
            if (!user || typeof user.account_id !== 'string' || !/^-?\d+$/.test(user.account_id)
                || !Number.isSafeInteger(user.count) || user.count <= 0 || seen.has(user.account_id)) throw new Error('유저 ID 오류');
            seen.add(user.account_id);
          }
        }
      }
    }
  }

  function render() {
    const term = find('search').value.trim();
    const filtered = users.filter((user) => user.account_id.includes(term));
    const pages = Math.max(1, Math.ceil(filtered.length / 50));
    page = Math.min(page, pages - 1);
    find('rows').replaceChildren();
    for (const user of filtered.slice(page * 50, (page + 1) * 50)) {
      const row = document.createElement('tr');
      row.insertCell().textContent = user.account_id;
      row.insertCell().textContent = user.count.toLocaleString();
      find('rows').appendChild(row);
    }
    find('page').textContent = `${page + 1} / ${pages}`;
    find('prev').disabled = !loaded || page === 0;
    find('next').disabled = !loaded || page + 1 >= pages;
    if (loaded) {
      find('status').textContent = `${filtered.length.toLocaleString()}명${term ? ' 검색됨' : ' · 관련 건수순'}`
        + (selected.entry.unidentified_records ? ` · 계정 식별 불가 기록 ${selected.entry.unidentified_records}건` : '')
        + (!filtered.length ? (term ? ' · 일치하는 ID가 없습니다.' : ' · 식별 가능한 계정이 없습니다.') : '');
    }
  }

  async function load() {
    request?.abort();
    const controller = new AbortController();
    request = controller;
    const context = selected;
    loaded = false;
    users = [];
    page = 0;
    find('retry').hidden = true;
    find('status').textContent = '유저 목록을 불러오는 중…';
    render();
    const timeout = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch('data/' + context.entry.path, { signal: controller.signal });
      if (!response.ok) throw new Error(response.status === 404 ? 'expired' : 'request');
      const payload = await response.json();
      const details = payload.groups?.[context.entry.key];
      if (payload.build_id !== context.build || payload.metric !== context.metric || payload.date !== context.date
          || !details || !Array.isArray(details.users) || details.users.length !== context.entry.total_users
          || details.unidentified_records !== context.entry.unidentified_records) throw new Error('invalid');
      const seen = new Set();
      let previous = null;
      for (const user of details.users) {
        if (!user || !/^-?\d+$/.test(user.account_id) || typeof user.account_id !== 'string'
            || !Number.isSafeInteger(user.count) || user.count <= 0 || seen.has(user.account_id)
            || (previous && (user.count > previous.count
              || (user.count === previous.count && BigInt(user.account_id) < BigInt(previous.account_id))))) throw new Error('invalid');
        seen.add(user.account_id);
        previous = user;
      }
      if (JSON.stringify(details.users.slice(0, 10)) !== JSON.stringify(context.entry.preview)) throw new Error('invalid');
      if (request !== controller || !dialog.open) return;
      users = details.users;
      loaded = true;
      render();
    } catch (error) {
      if (request !== controller || !dialog.open) return;
      find('status').textContent = error.message === 'expired'
        ? '이 빌드의 상세 파일이 만료되었습니다. 패널을 닫고 대시보드를 새로고침한 뒤 다시 열어주세요.'
        : '유저 목록을 읽지 못했습니다. 다시 시도하세요.';
      find('retry').hidden = false;
    } finally {
      clearTimeout(timeout);
    }
  }

  function open(snapshot, metric, date, series, label, trigger) {
    const entry = group(snapshot, metric, date, series);
    if (!entry) return;
    selected = { entry: structuredClone(entry), metric, date, build: snapshot.drilldown.build_id };
    opener = trigger || document.activeElement;
    find('title').textContent = `${label} · 관련 유저`;
    find('context').textContent = `${date} · 한국 시간(KST)`;
    find('description').textContent = entry.label;
    find('build').textContent = `집계 빌드 ${snapshot.built_at} · 열람 중인 빌드를 유지합니다`;
    find('search').value = '';
    if (!dialog.open) dialog.showModal();
    find('search').focus();
    load();
  }

  find('close').onclick = () => dialog.close();
  dialog.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      dialog.close();
    }
  });
  dialog.addEventListener('close', () => {
    request?.abort();
    request = null;
    if (opener?.isConnected) opener.focus();
    else document.getElementById('refresh').focus();
  });
  find('search').oninput = () => { page = 0; render(); };
  find('prev').onclick = () => { page -= 1; render(); };
  find('next').onclick = () => { page += 1; render(); };
  find('retry').onclick = load;
  return { group, preview, open, validate };
})();
