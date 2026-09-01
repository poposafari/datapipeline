# poposafari-data-pipeline

미니 PC `poposafari`(172.30.1.13)에서 도는 DuckDB 웨어하우스. **prod 박스에는 이 레포의 코드가 한 줄도 올라가지 않는다.**

| | |
| --- | --- |
| 입력 | R2 버킷 `poposafari-analytics` 의 `audit/` 프리픽스 하나뿐 |
| 정본 | **R2 아카이브.** prod 는 업로드 직후 `audit_log` 를 비운다 (§정본이 뒤집혔다) |
| prod 접근 | **없다.** 대사도 R2 객체끼리 한다. Tailscale 은 ad-hoc 디버깅 전용 |
| 도구 | DuckDB (정적 단일 바이너리). Celeron N3150 에 JVM 기반 BI 는 부담 |
| 대시보드 | 정적 JSON + Chart.js. 상시 프로세스는 파일 서버 하나뿐 |

설계 근거는 `docs/plan-v3-data-pipeline.md`, 그 상위는 `docs/data-pipeline-plan-v2.md`.

---

## 계약 — server 레포가 실제로 올리는 것

```
s3://poposafari-analytics/
  audit/YYYY/MM/DD/audit-<UTC stamp>-<cutoff>.jsonl.gz
```

`scripts/ops/archive-audit.sh` 가 다음을 gzip 해서 올린다:

```sql
SELECT row_to_json(t) FROM (SELECT * FROM audit_log WHERE id <= $CUTOFF ORDER BY id) t
```

- **gzip JSONL.** 한 줄에 1행. CSV 가 아니다.
- **9컬럼이고 `ip` 가 들어 있다.** `SELECT *` 이기 때문이다.
- `detail` 은 jsonb 라 **중첩 JSON 객체**다. 따옴표로 감싼 문자열이 아니다.
- `created_at` 은 `"2026-08-20T12:34:56.789+00:00"` (postgres:15-alpine 에 TZ 미설정 → UTC).
- `<cutoff>` = 그 배치가 가져간 max id. 경로의 날짜는 **아카이브일**이지 이벤트일이 아니다.
- **재스윕(`backfill/`) · 마스터(`master/`) · 카운트(`meta/`) 는 없다.**

> ⚠️ 계획서 v3 §1 은 CSV 8컬럼 + `raw/dt=` 파티션 + 야간 재스윕 + `meta/counts.csv.gz` 로
> 적혀 있다. **그렇게 만들어지지 않았다.** 위가 실물이고, 계획서 §1 은 그에 맞게 고쳤다.

### 정본이 뒤집혔다

`archive-audit.sh` 는 업로드 뒤 `DELETE FROM audit_log` 를 하고, `backup-pg.sh` 는
`--exclude-table-data=audit_log` 다. 즉 **R2 아카이브가 유일본이고 이 웨어하우스가
두 번째 사본이다.** `poposafari.duckdb` 를 지우고 다시 만들 수 있는 건 R2 객체가
살아 있는 동안뿐이다.

### 알려진 결함 — 복구 불가능한 유실 창

`archive-audit.sh` 는 export 하는 `SELECT` 와 `DELETE FROM audit_log WHERE id <= cutoff`
가 **별개 psql 세션**이다. bigserial 은 커밋 순서가 아니라 채번 순서라, 그 사이에
커밋된 행은 익스포트 없이 삭제된다. 예전 설계에서는 야간 재스윕이 메웠지만
재스윕이 없다. 5분 랙(`AUDIT_LAG_MINUTES`)이 완화할 뿐 없애지 못한다.

→ `checks/reconcile.sh` 가 **아카이브 자체의 id 갭**으로 탐지한다. 탐지만 되고
   되찾을 수는 없다. server 쪽 수정이 필요한 사안이라 여기서는 기록만 한다.

### 마스킹 책임이 이쪽으로 넘어왔다

계약 §1-3 은 server 가 보장한다고 적었지만, 셋 다 보장되지 않는다.

| 항목 | 실제 | 이쪽 조치 |
| --- | --- | --- |
| `ip` 부재 | `SELECT *` 라 실려 온다 | `load/10_load_audit.sql` 이 적재에서 드롭 |
| `url` 쿼리스트링 절단 | `app.ts:150` 이 `request.url` 그대로 | `views/00_audit.sql` 이 `split_part(…,'?',1)` |
| `body.username` 제거 | `REDACT_KEYS` 에 `username` 이 없다 | 뷰가 편의 컬럼으로 꺼내지 않는다 |

`checks/assertions.sql` 은 이제 "상대편 계약이 깨졌나"가 아니라 **"우리 마스킹이
동작하나"** 를 본다. 소스가 여전히 그런 상태인지는 `checks/contract_drift.sql` 이
보고하고, 그건 매일 돌지 않는다 — 매일 걸리는 알림은 죽은 알림이다.

---

## 부트스트랩 (미니 PC, 1회)

```bash
sudo ./bootstrap/install.sh
# 1. /srv/warehouse/secrets.sql 에 R2 자격증명 입력 (읽기 전용 + analytics 스코프)
# 2. 첫 적재 — 빈 테이블이면 scan_from 이 자동으로 전량으로 넓어진다
./load/run.sh && ./dashboard/build.sh
```

`install.sh` 가 하는 일: DuckDB 버전 고정 설치, `/srv/warehouse` 0700,
`secrets.sql` 0600, `/etc/cron.d/poposafari`, logrotate, 대시보드 systemd 유닛.

> ⚠️ **prod ops 1회가 선행되어야 한다.** `archive-audit.sh` 의 기본 버킷은
> `.env.backup` 의 `poposafari-backups` 다. cron 줄에
> `BACKUP_ENV=…/docker/prod/.env.audit` 를 주고 그 파일에
> `R2_BUCKET=poposafari-analytics` 만 넣으면 server 코드 변경 없이 갈린다.
> 이걸 안 하면 감사로그가 백업 버킷에 쌓이고, 미니 PC 토큰 스코프를 그쪽으로
> 넓혀야 해서 아래 보안 경계가 무너진다.

## 일상 운영

| | |
| --- | --- |
| 적재 + 대시보드 빌드 | 19:00 UTC (04:00 KST) |
| 대사 | 19:30 UTC (04:30 KST) |
| 로그 | `/var/log/poposafari/{load,check}.log` |
| 알림 | `DISCORD_WEBHOOK_ALERTS` (server 레포 `.env.backup` 과 같은 채널) |
| 대시보드 | `http://172.30.1.13:8080` (`/etc/default/poposafari-dashboard` 에서 조정) |

```bash
duckdb /srv/warehouse/poposafari.duckdb
D .read /opt/poposafari-data-pipeline/recipes/onboarding_8.sql
D .read /opt/poposafari-data-pipeline/checks/contract_drift.sql
```

### 복구

```bash
# 적재 중 크래시로 파일이 깨졌을 때 — 즉시 롤백 (하드링크 스냅샷)
cp /srv/warehouse/poposafari.duckdb.prev /srv/warehouse/poposafari.duckdb

# 전량 재구축 — 빈 테이블이면 scan_from 이 자동으로 2026-01-01 부터로 넓어진다.
rm /srv/warehouse/poposafari.duckdb && ./load/run.sh
```

---

## 구조

```
bootstrap/   install.sh, secrets.sql.example, cron.d/
load/        00_schema → 05_scan → 10_load_audit → 15_load_log
             → 20_load_master | 21_master_stub,  run.sh
views/       00_audit(방어적 파싱·마스킹) → 10_master_join(정규화) → 20_metrics
recipes/     onboarding_8.sql, abuse/*.sql   ← 수동 실행
checks/      assertions.sql(적재 후 자동), contract_drift.sql(수동),
             reconcile.sh(일 1회)
dashboard/   queries/*.sql → build.sh → public/{index.html,app.js} + serve/
fixtures/    gen.py, run-local.sh            ← R2 없이 전 구간 검증
docs/        설계 문서
```

계층은 3개가 아니라 **2개**다 — raw 테이블 + 뷰. `raw→stg→mart` 는 BigQuery
과금 구조(뷰 무료, 스캔 유료)에 맞춘 형태이고 DuckDB 에는 스캔 과금이 없다.
mart 를 물리화할 이유가 생기면 그때 `CREATE TABLE AS`.

### 왜 적재가 duckdb 를 두 번 부르나

SQL 에는 분기가 없는데, `read_json` 은 **0개 파일에 매칭되면 에러**다. R2 에
객체가 아직 없는 날에도 파이프라인은 조용히 성공해야 한다. 그래서 `05_scan.sql`
이 대상 목록을 `wh.scan_plan` 에 적고, `run.sh` 가 행 수를 세서 다음 단계를
조립한다. 마스터 유무 분기도 같은 이유다.

---

## 지표

`views/20_metrics.sql`. 전부 `wh.audit_v` 만 본다.

| 뷰 | 내용 |
| --- | --- |
| `bait_rock_daily` | 미끼·돌 사용 건수, 포획 시도 대비 점유율, 잔류율 |
| `dau_daily` | DAU + 신규 가입(`CREATE_USER`) |
| `catch_attempt` / `catch_rate_daily` | 시도 대비 성공·도주·break_out, 미끼/돌 세그먼트 |
| `safari_session` / `safari_session_daily` | 입장→퇴장 체류시간, 미완결 비율 |
| `money_series` / `economy_daily` | 잔고 시계열, faucet/sink |

읽을 때 반드시 알아야 할 것 세 가지:

- **포획 성공은 관측이 아니라 역산이다.** `POKEMON_CATCH` 에 `wildUid` 가 없어서
  (detail 이 `{userPokemonId, pokedexId, level, isShiny, mapId, isS000Starter}`)
  시도↔성공을 직접 이을 수 없다. 같은 `(account_id, wild_uid)` 안에서 시도와 실패를
  순번으로 짝짓고, **실패가 안 붙은 시도를 성공으로** 본다.
  `caught_gap` 이 그 역산과 실제 `POKEMON_CATCH` 행 수의 차이다 — 0 근처가 정상이다.
- **s000(튜토리얼)은 거의 모든 지표에서 제외된다.** 강제 성공(`isS000Starter`)이고
  도주가 꺼져 있어 섞으면 포획률이 통째로 위로 뜬다. 단 `SAFARI_BAIT`/`ROCK` 의
  detail 에는 `mapId` 가 없어 잔류율만은 s000 을 못 거른다.
- **사파리 세션은 짝이 안 맞는 게 정상이다.** `SAFARI_ENTER` 는 plaza→safari 이고
  s000 이 아닐 때만 발행되고(`safari.service.ts:96`), `SAFARI_EXIT` 는 모든 이탈에서
  발행된다. 창을 닫으면 EXIT 가 아예 없다. 그래서 `unclosed_rate` 자체가 지표다.

---

## 대시보드

```bash
./dashboard/build.sh          # 웨어하우스 → public/data/*.json (90일치)
./dashboard/check.sh          # 차트가 읽는 컬럼 ↔ JSON 컬럼 대조
```

Node 도 빌드 툴체인도 없다. `duckdb -json` 으로 JSON 을 굽고 단일 HTML 이 그린다.
데이터가 하루 1회 갱신되므로 요청마다 쿼리할 이유가 없고, 그 덕에 상시 프로세스가
`python3 -m http.server` 하나로 끝난다.

토글(기간 7/30/90, 차트 표시, 카드별 모드·시리즈)은 전부 클라이언트에서 처리하고
`localStorage` 에 남는다. 90일치를 한 번에 받아 브라우저가 잘라 쓴다.

- 상단에 **마지막 적재 시각**을 항상 띄운다. 36시간이 넘으면 빨갛게 경고한다 —
  정적 대시보드의 가장 흔한 사고가 낡은 숫자를 최신으로 착각하는 것이다.
- 데이터가 없는 지표는 빈 차트가 아니라 **"데이터 없음" 문구**가 뜬다.
- `check.sh` 가 없으면 SQL 컬럼명을 바꿨을 때 **에러 없이 빈 차트**가 된다.
  `fixtures/run-local.sh` 가 이걸 매번 돌린다.

---

## 검증

```bash
POPOSAFARI_SERVER=/path/to/server ./fixtures/run-local.sh
```

R2 도 prod 도 없이 전 구간이 돈다. `fixtures/gen.py` 가 `archive-audit.sh` 의
출력 형식을 그대로 흉내낸 가짜 아카이브를 만들고, 파이프라인이 반드시 견뎌야 할
함정을 의도적으로 심는다. `POPOSAFARI_SERVER` 를 주면 마스터는 server 레포의
실물 CSV 를 쓴다 — `pokedex_id` 정규형 회귀가 거기 걸린다.

## 이 파이프라인이 견디는 함정

| 함정 | 조치 | 근거 |
| --- | --- | --- |
| **`pokedex_id` 형식 2종** | 정규형 = **패딩 문자열**. 정수 캐스팅 금지 | `pokemon.csv` 의 id 는 평문 정수와 패딩 합성 id 가 섞여 있고(`0058_hisui`), `map/*.json` 스폰 id 와 `user_pokemon.pokedex_id`(varchar(20))는 전부 패딩이다. 정수로 정규화하면 변종 폼이 NULL 이 되어 조인이 조용히 사라진다. 규칙의 정본은 server `csv_to_json.py:48-52` |
| **`created_at` 타임존** | `TIMESTAMPTZ` 로 캐스팅 후 `AT TIME ZONE 'UTC'` → `TIMESTAMP` 로 저장 | 문자열에 `+00:00` 이 박혀 있어 이 변환은 세션 TZ 와 무관하게 결정적이다. `TIMESTAMPTZ` 컬럼으로 두면 조회 때마다 KST 로 재해석되어 **9시간 밀린다** |
| **빈 글롭** | `glob()` 으로 먼저 세고 셸이 분기 | `read_json` 은 0개 파일에 매칭되면 **에러**다. 첫 배포일에 반드시 밟는 경로 |
| **hive 파티션 부재** | 경로에서 `YYYY/MM/DD` 를 정규식으로 추출 | `audit/` 레이아웃에는 `dt=` 가 없다 |
| **아카이브일 ≠ 이벤트일** | 스캔 창을 7일로 넉넉히 | 자정 근처 행은 다음 날 배치에 실린다 |
| **타입 추론 갈림** | `columns` 명시 | JSONL 은 null 이 명시적이라 CSV 만큼 위험하진 않지만, 파일마다 추론이 갈리는 걸 막는다 |
| **`detail` 무보증** | `json_extract_string` + `TRY_CAST` | jsonb 라 문법이 깨질 순 없지만 **객체가 아닌 값**과 NULL 은 온다. 행 전체가 죽으면 안 된다 |
| **CRLF 마스터** | `rtrim(col, chr(13))` | `pokemon.csv`/`item.csv` 는 CRLF, EOF 개행 없음 |
| **`status` 대부분 NULL** | 그대로 받는다 | `status` 를 채우는 건 `app.ts` 의 onResponse/onError 훅뿐이다. `auditTx`/`auditAsync` 직접 호출 경로는 전부 NULL — 포획·입장·거래가 다 여기 해당한다 |
| **티켓은 건수가 아니라 장수** | `sum(detail.claimed)` | `SAFARI_TICKET_CLAIM` 한 건이 최대 3장을 준다. 건수로 세면 획득이 과소 계상되어 어뷰징 룰이 전원을 오탐한다 |
| **`load_log` 카운트** | 적재 전/후 차분 | 총 행수를 넣으면 "이번에 몇 행 들어왔나"를 영영 알 수 없다 |
| **`SAFARI_ENTER.ticketConsumed`** | 신호로 쓰지 않는다 | 하드코딩 리터럴 `true` 라 항상 참이다 |

---

## 보안 · PII 경계

| 항목 | 조치 |
| --- | --- |
| R2 토큰 | 읽기 전용 + `poposafari-analytics` 스코프. 백업 버킷 토큰 재사용 금지 |
| `poposafari-backups` | **읽지 않는다.** 감사로그가 그쪽으로 가고 있다면 위 prod ops 로 분리할 것 |
| `ip` | 소스에는 있다. **적재에서 버린다.** 웨어하우스에 영구 보존되지 않게 |
| `url` 쿼리스트링 | 뷰에서 자른다. OAuth code 가 그대로 실려 온다 |
| `body.username` | 뷰가 컬럼으로 꺼내지 않는다. 원본 `detail` 을 직접 봐야 보인다 |
| `/srv/warehouse` | 0700. LVM plain 이라 디스크 암호화 없음 — **물리 도난 시 노출된다.** 1인 가정 환경에서 수용 가능으로 판단하되 명시해 둔다 |
| `secrets.sql` | 0600, 레포 밖, `.gitignore` |
| 대시보드 | 인증 없음. **집계값만** 있고 `account_id` 조차 나가지 않는다. 대신 `0.0.0.0` 이 아니라 LAN/Tailscale 주소에만 바인드한다 |
| `account_id` | 가명 식별자. 로컬 분석이라 해싱 실익 없음. 외부 공유 시에만 `md5(account_id ‖ salt)` |
| `LOGIN_OAUTH.detail.providerId` | 직접 식별자. 1차 적재는 유지 — 계정 매핑 디버깅에 실사용 가치. 뷰가 안정된 뒤 판단 |
| 국외이전 | 해당 없음. 자체 호스팅 |

> `pg_dump` 에서 `session`·`audit_log` 데이터가 빠졌으므로(server `8e0d189`),
> "백업 버킷에 살아있는 `session.id` 가 있다"는 예전 근거는 더 이상 유효하지 않다.
> 그래도 백업 버킷을 읽지 않는 원칙은 유지한다 — 계정 비밀번호 해시가 남아 있고,
> 분석에 필요하지도 않다.

---

## 승격 경로 (착수 금지 · 조건부)

| 항목 | 트리거 |
| --- | --- |
| 대시보드를 Evidence.dev 로 | 지표가 10개를 넘어 정적 HTML 이 손에 부칠 때. 그때 Node 를 들인다 |
| compose 승격 | 상시 컴포넌트가 **두 개째** 생길 때. 지금은 정적 파일 서버 하나뿐이다 |
| 어뷰징 탐지 자동화 | 실제 어뷰징 1건 확인 |
| 접속 세션 길이 지표 | `SOCKET_CONNECT`/`SOCKET_DISCONNECT` + `ownedSlot` 로 지금도 가능. 필요해질 때 |
| 중앙 로그 수집 | "로그 찾느라 SSH 주 3회 이상". 그때도 Alloy 는 **미니 PC 쪽에** |
| Parquet 전환 | JSONL.gz 스캔이 느려질 때 |
| 잔고 스냅샷 잡 | `money_after` 로 복원이 안 되는 질문이 생길 때(거래 없는 유저) |
