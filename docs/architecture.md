# PopoSafari 데이터 파이프라인 — 아키텍처

게임 서버의 감사 로그(`audit_log`)를 분석 가능한 형태로 옮기고, 지표를 뽑아
대시보드로 보여주는 파이프라인. 미니 PC 한 대에서 cron 으로 돈다.

- **입력** — Cloudflare R2 의 gzip JSONL 아카이브
- **저장** — DuckDB 단일 파일 웨어하우스
- **출력** — 정적 JSON + Chart.js 대시보드
- **현황** — 감사 로그 99,698행 적재, 지표 4종 가동 중

---

## 1. 한눈에

```
┌─────────────────────────────────────────┐
│ prod (AWS Lightsail, 4GB/2vCPU 버스터블) │
│                                          │
│  Fastify ──auditTx/auditAsync──┐        │
│                                 ▼        │
│                          PostgreSQL 15   │
│                          audit_log       │
│                                 │        │
│    archive-audit.sh (6시간 cron)│        │
│      1. SELECT row_to_json      │        │
│      2. gzip → R2 업로드         │        │
│      3. DELETE FROM audit_log ◀─┘        │
└──────────────────┬───────────────────────┘
                   │ push (S3 API)
                   ▼
┌─────────────────────────────────────────┐
│ Cloudflare R2                            │
│  s3://poposafari-db-backups/             │
│    ├── pg/     PG 논리백업   lifecycle 7일 │
│    └── audit/  감사 아카이브  lifecycle 365일│
│         YYYY/MM/DD/audit-<시각>-<cutoff> │
└──────────────────┬───────────────────────┘
                   │ pull (읽기 전용)
                   ▼
┌─────────────────────────────────────────┐
│ 미니 PC "poposafari"                     │
│  Celeron N3150 4C/4T · RAM 7.7GB         │
│                                          │
│  cron 19:00 UTC                          │
│    load/run.sh ──▶ DuckDB 웨어하우스      │
│                    /srv/warehouse/*.duckdb│
│                      raw 테이블 + 뷰 11개  │
│                         │                │
│    dashboard/build.sh ◀─┘                │
│         └─▶ public/data/*.json           │
│                         │                │
│  systemd: python3 -m http.server         │
│         └─▶ http://<tailscale>:8080      │
│                                          │
│  cron 19:30 UTC                          │
│    checks/reconcile.sh (아카이브 ↔ 웨어하우스)│
└─────────────────────────────────────────┘
```

**prod 에는 이 레포의 코드가 한 줄도 올라가지 않는다.** 미니 PC 도 prod 에 접근하지
않는다. 두 쪽이 만나는 지점은 R2 버킷 하나뿐이다.

---

## 2. 왜 이 구조인가

### 2-1. pull 이 아니라 push 를 받는다

미니 PC 가 Tailscale 로 prod 의 PostgreSQL 에 직접 붙어 가져오는 구성도 가능했다.
R2 를 경유하기로 한 이유 셋:

| | |
| --- | --- |
| **신규 네트워크 노출 0** | pull 은 5432 포트를 Tailscale 대역에 바인딩하고 읽기전용 롤을 만드는 게 선행 조건이다. push 는 이미 있는 R2 자격증명만 쓴다 |
| **가정용 회선에 의존하지 않는다** | 미니 PC 가 꺼져 있어도 prod 추출은 계속된다. 밀린 만큼 나중에 따라잡으면 된다 |
| **버스터블 CPU 크레딧** | prod 는 4GB/2vCPU 버스터블이다. 분석 쿼리가 거기 닿으면 게임 전체가 느려진다 |

부수 효과로 **정기 파이프라인이 prod 에 전혀 접근하지 않는다.** 대사(reconcile)조차
R2 객체끼리 맞춘다.

### 2-2. DuckDB — Metabase·PostgreSQL 대신

| 후보 | 탈락 사유 |
| --- | --- |
| Metabase / Superset | JVM 기반. Celeron N3150 은 싱글스레드 성능이 낮아 상시 구동 부담이 크다 |
| 별도 PostgreSQL | 분석 워크로드에 행 지향 엔진. 게다가 상시 데몬이 하나 더 늘어난다 |
| BigQuery 등 클라우드 DW | 데이터가 하루 10–24MB 다. 과금 구조와 네트워크 왕복이 규모에 안 맞는다 |

**DuckDB 를 고른 이유:**

- **정적 단일 바이너리.** 설치가 `curl` + `install` 두 줄이고 데몬이 없다. 적재는
  서비스가 아니라 cron 잡이므로 상시 프로세스가 필요 없다
- **컬럼 지향 + 벡터화.** 99,698행 × 8컬럼 스캔이 초 단위로 끝난다
- **gzip JSONL 을 직접 읽는다.** `read_json` 이 S3 API(httpfs)로 R2 를 그대로 스캔해서
  중간 적재 단계가 필요 없다
- **버전 고정 가능.** `install.sh` 가 `v1.5.5` 를 못박는다. `latest` URL 은 재현성이
  없다 — 어느 날 조용히 올라간 버전이 SQL 동작을 바꾸면 원인 추적이 불가능해진다

### 2-3. 계층은 3개가 아니라 2개 — raw 테이블 + 뷰

`raw → staging → mart` 3계층은 **BigQuery 과금 구조(뷰는 무료, 스캔은 유료)에
최적화된 형태**다. DuckDB 에는 스캔 과금이 없으므로 중간 물리 테이블을 유지할 이유가
없다. 물리화는 비용(적재 시간, 디스크, 동기화 실패 지점)만 늘린다.

→ **raw 테이블 하나 + 뷰 11개.** mart 를 물리화할 이유가 실제로 생기면 그때
`CREATE TABLE AS` 를 붙인다.

### 2-4. 대시보드 — Evidence.dev 대신 정적 JSON + Chart.js

원래 계획서는 BI GUI 승격 경로로 Evidence.dev(정적 사이트 생성형)를 지목했다.
실제로는 더 가벼운 쪽으로 갔다.

| | Evidence.dev | **채택: 정적 JSON + Chart.js** |
| --- | --- | --- |
| 런타임 | Node 20 + node_modules 수백 MB | 없음 |
| 빌드 | `npm run build`, N3150 에서 수 분 | `duckdb -json`, 1초 미만 |
| 지표 추가 | 마크다운 페이지 작성 | SQL 1개 + 차트 정의 1개 |
| 상시 프로세스 | 정적 서빙 1개 | 정적 서빙 1개 |

지표 4개를 위해 Node 툴체인을 Celeron 박스에 들이는 건 과했다. **데이터가 하루 1회
갱신되므로 요청마다 쿼리할 이유도 없다** — 미리 구워둔 JSON 을 브라우저가 읽으면 된다.

그 결과 미니 PC 의 상시 프로세스가 `python3 -m http.server` **하나**로 유지된다.
두 번째 상시 컴포넌트가 생기면 그때 compose 로 승격한다는 조건은 아직 안 건드렸다.

지표가 10개를 넘어 단일 HTML 이 손에 부치면 Evidence 로 옮기면 된다. **지금은 아니다.**

### 2-5. 계약을 코드에서 읽는다

이 레포는 원래 계획서(`plan-v3-data-pipeline.md`) §1 의 인터페이스 계약을 따라
만들어졌다. 그런데 server 레포가 실제로 배포한 것은 계획과 전부 달랐다.

| 계획서 §1 | 실제 배포된 것 |
| --- | --- |
| CSV 8컬럼, `ip` 없음 | **JSONL 9컬럼, `ip` 포함** |
| `raw/dt=YYYY-MM-DD/` hive 파티션 | `audit/YYYY/MM/DD/` (파티션 키 없음) |
| 야간 재스윕 `backfill/` | **없음** |
| 일별 카운트 `meta/counts.csv.gz` | **없음** |
| prod 가 정본, R2 는 파생 | **R2 가 정본** (업로드 후 DB 에서 DELETE) |
| 버킷 `poposafari-analytics` | `poposafari-db-backups` (pg 백업과 공유) |

→ **계약을 문서가 아니라 코드에서 다시 읽어 §1 을 실물로 재작성했다.**
문서가 계획을 말할 때 코드가 다른 걸 하고 있으면, 파이프라인은 조용히 0행을 적재한다.

---

## 3. 구성 요소별 역할

```
bootstrap/     설치 (1회)
├── install.sh                DuckDB 고정 설치, /srv/warehouse 0700, cron,
│                             logrotate, 대시보드 systemd 유닛 등록
├── secrets.sql.example       R2 자격증명 템플릿 (실물은 레포 밖 0600)
└── cron.d/poposafari         cron 정의 (@REPO@ 치환)

load/          적재 — 매일 19:00 UTC
├── 00_schema.sql             테이블 DDL (멱등)
├── 05_scan.sql               읽을 객체 목록 → wh.scan_plan
├── 10_load_audit.sql         R2 → wh.audit 안티조인 적재
├── 15_load_log.sql           적재 이력 (건너뛴 실행도 기록)
├── 20_load_master.sql        마스터 CSV → wh.master_*  (있을 때만)
├── 21_master_stub.sql        마스터 부재 시 빈 테이블
└── run.sh                    위 순서 실행 + 분기 + 실패 시 Discord

views/         모델링
├── 00_audit.sql              방어적 파싱 + PII 마스킹  → wh.audit_v
├── 10_master_join.sql        pokedex_id 정규화        → pokemon_dim, item_dim
└── 20_metrics.sql            파생 지표 8개

checks/        검증
├── assertions.sql            적재 후 자동. 전부 0행이어야 함
├── contract_drift.sql        소스 현재 상태 보고 (수동)
└── reconcile.sh              아카이브 ↔ 웨어하우스 대사 — 매일 19:30 UTC

dashboard/     시각화
├── queries/*.sql             지표 뷰 → 90일 일별 시계열
├── build.sh                  duckdb -json → public/data/*.json
├── check.sh                  차트 컬럼 ↔ JSON 컬럼 대조
├── public/                   index.html + app.js + Chart.js(벤더링)
└── serve/                    systemd 유닛

fixtures/      검증용 가짜 R2
├── gen.py                    archive-audit.sh 출력 형식을 그대로 흉내
└── run-local.sh              R2·prod 없이 전 구간 E2E (검사 68건)

recipes/       수동 실행 쿼리
├── onboarding_8.sql          온보딩 예시 쿼리 이식
└── abuse/*.sql               어뷰징 탐지 4종
```

### 3-1. 적재 파이프라인 상세

**① `05_scan.sql` — 무엇을 읽을지 먼저 정한다**

R2 를 `glob` 해서 스캔 창(기본 7일) 안의 객체 목록을 `wh.scan_plan` 테이블에 적는다.

경로에 hive 파티션(`dt=`)이 없으므로 `audit/YYYY/MM/DD/` 에서 정규식으로 날짜를 뽑고,
파일명 끝의 `<cutoff>`(그 배치가 가져간 최대 id)도 함께 저장한다. 대사가 이 값을 쓴다.

> ⚠️ 경로의 날짜는 **로그가 찍힌 날이 아니라 스크립트가 돈 UTC 시각**이다.
> 자정 근처 행은 다음 날 배치에 실린다. 스캔 창 7일이 그 어긋남을 덮는다.

**② `run.sh` — 셸이 분기한다**

DuckDB 의 `read_json` 은 **0개 파일에 매칭되면 에러**다. R2 에 객체가 아직 없는 날에도
파이프라인은 조용히 성공해야 하는데, SQL 에는 분기가 없다.

→ duckdb 를 두 번 부른다. 1단계가 `scan_plan` 행 수를 세고, 셸이 그 값을 보고 2단계
스크립트를 조립한다.

**③ `10_load_audit.sql` — 멱등 적재**

```sql
INSERT INTO wh.audit
SELECT … FROM (SELECT DISTINCT ON (id) * FROM read_json(<파일 목록>, …)) s
WHERE NOT EXISTS (SELECT 1 FROM wh.audit a WHERE a.id = s.id);
```

- **id 안티조인** → 몇 번을 돌려도 결과가 같다. 2회차 `rows_inserted = 0`
- **`DISTINCT ON (id)`** → 배치가 겹쳐도 무해 (아카이브 스크립트 재실행 시나리오)
- **`ip` 를 SELECT 하지 않는다** → 여기가 PII 경계 (§6)
- **`columns` 명시** → auto-detect 에 맡기면 파일마다 추론이 갈린다

**④ `15_load_log.sql` — 건너뛴 실행도 남긴다**

"어제 파이프라인이 돌긴 했는데 넣을 게 없었다" 와 "어제 아예 안 돌았다" 는 장애 조사에서
완전히 다른 이야기다. 적재 대상이 0개여도 이력을 남긴다.

`rows_inserted` 는 총 행수가 아니라 **이번에 늘어난 수**다. 총 행수를 넣으면
"이번에 몇 행 들어왔나"를 영영 알 수 없다.

---

## 4. 데이터 계약

`server/scripts/ops/archive-audit.sh` 가 6시간마다 다음을 수행한다:

```sql
-- 1. 5분 이상 지난 행의 최대 id 를 cutoff 로 잡는다
SELECT max(id) FROM audit_log WHERE created_at < now() - interval '5 minutes'
-- 2. 그 이하를 JSON 으로 뽑아 gzip → R2 업로드
SELECT row_to_json(t) FROM (SELECT * FROM audit_log WHERE id <= $CUTOFF ORDER BY id) t
-- 3. 업로드 검증 후 원본 삭제
DELETE FROM audit_log WHERE id <= $CUTOFF
```

**행 스키마 (9컬럼)**

| 컬럼 | 비고 |
| --- | --- |
| `id` | bigserial |
| `account_id` | |
| `action` | 35종 (`POKEMON_CATCH`, `SAFARI_BAIT`, `CREATE_USER` …) |
| `status` | **대부분 NULL.** 채우는 건 API 의 onResponse/onError 훅뿐이고, `auditTx`/`auditAsync` 직접 호출 경로(포획·입장·거래·소켓)는 전부 NULL |
| `detail` | jsonb → **중첩 JSON 객체.** 문자열이 아니다 |
| `ip` | **적재 시 이쪽에서 버린다** |
| `user_agent` | 소켓 경로는 NULL |
| `source` | `api` \| `socket` \| `worker` |
| `created_at` | `"2026-08-20T12:34:56.789+00:00"` — 오프셋 포함 ISO 문자열 |

**`detail` 은 스키마 무보증이다.** server 가 Zod 표준화를 하지 않기로 했으므로 방어적
파싱은 전적으로 이쪽 책임이다. jsonb 라 문법이 깨진 JSON 은 올 수 없지만, `NULL` 과
**객체가 아닌 값**(문자열·배열)은 온다. 어느 쪽도 행을 죽이면 안 되고 필드 추출은
NULL 이어야 한다.

---

## 5. 데이터 모델

### 5-1. raw 테이블

| 테이블 | 역할 |
| --- | --- |
| `wh.audit` | 감사 로그 본체 (8컬럼, `ip` 제외). PK = id |
| `wh.load_log` | 적재 이력 — 언제 몇 개 객체에서 몇 행 |
| `wh.scan_plan` | 이번 실행이 읽은 객체 목록 + cutoff id |
| `wh.scan_state` | 스캔 창, 적재 전 행 수 |
| `wh.src_shape` | 소스 컬럼 스냅샷 (계약 변화 탐지용) |
| `wh.master_pokemon` / `wh.master_item` | 마스터 CSV (현재는 빈 스텁) |

### 5-2. 뷰 11개

```
wh.audit_v              ← 모든 상위 뷰가 이것만 본다
  │  방어적 파싱 + PII 마스킹을 여기서 한 번만 흡수
  │
  ├── wh.money_series ──── wh.economy_daily
  ├── wh.dau_daily                          ← 지표2
  ├── wh.bait_rock_daily                    ← 지표1
  ├── wh.catch_attempt ─── wh.catch_rate_daily
  └── wh.safari_session ── wh.safari_session_daily

wh.pokemon_dim / wh.item_dim   ← 마스터 정규화 (조인용)
```

### 5-3. `audit_v` 가 흡수하는 것

- `json_extract_string` + `TRY_CAST` — 키가 없거나 타입이 안 맞으면 NULL. 예외로 안 죽는다
- **시간대** — `created_at` 은 UTC 벽시계 `TIMESTAMP`. KST 는 `+ INTERVAL 9 HOUR`
- **액션별 키 차이 통일** — `SAFARI_ENTER` 는 `detail.mapId`, `MAP_CHANGE` 는
  `{from,to,x,y}` 로 `mapId` 가 아예 없다. `map_id` 를 "이 이벤트가 일어난 맵"으로 통일
- **금액 키 비대칭** — `ITEM_BUY` 는 `totalCost`, `ITEM_SELL` 은 `totalGain`
- **PII 마스킹** — url 쿼리스트링 절단, username 미노출

---

## 6. PII · 보안 경계

### 6-1. 마스킹 책임이 이쪽으로 넘어왔다

계획서 §1-3 은 아래 3종을 "server 레포가 보장" 으로 적었다. **셋 다 보장되지 않는다.**

| 항목 | 실제 | 이쪽 조치 |
| --- | --- | --- |
| `ip` 컬럼 부재 | `SELECT *` 라 실려 온다 | `10_load_audit.sql` 이 적재에서 드롭 |
| url 쿼리스트링 절단 | `request.url` 을 그대로 기록 (OAuth code 포함) | `00_audit.sql` 이 `split_part(…,'?',1)` |
| `body.username` 제거 | `REDACT_KEYS` 에 `username` 이 없어 평문 | 뷰가 편의 컬럼으로 꺼내지 않는다 |

그래서 `assertions.sql` 의 목적도 바뀌었다 — **"상대편 계약이 깨졌나"가 아니라
"우리 마스킹이 동작하나"** 를 본다. 소스가 여전히 그런 상태인지는
`contract_drift.sql` 이 따로 보고하고, 그건 자동 실행되지 않는다.
**매일 걸리는 알림은 죽은 알림이기 때문이다.**

### 6-2. 그 밖의 경계

| 항목 | 조치 |
| --- | --- |
| R2 토큰 | 읽기 전용 + 버킷 스코프. 백업용 쓰기 토큰 재사용 금지 |
| `/srv/warehouse` | 0700. LVM plain 이라 디스크 암호화 없음 — 물리 도난 시 노출. 1인 가정 환경에서 수용으로 판단하되 명시 |
| `secrets.sql` | 0600, 레포 밖, `.gitignore` |
| 대시보드 | 인증 없음. **집계값만** 있고 `account_id` 조차 나가지 않는다. 대신 `0.0.0.0` 이 아니라 LAN/Tailscale 주소에만 바인드 |
| `account_id` | 가명 식별자. 로컬 분석이라 해싱 실익 없음 |
| 국외이전 | 해당 없음 (자체 호스팅) |

---

## 7. 지표

| 뷰 | 내용 |
| --- | --- |
| `bait_rock_daily` | 미끼·돌 사용 건수, 포획 시도 대비 점유율, 잔류율 |
| `dau_daily` | DAU + 신규 가입(`CREATE_USER`) |
| `catch_rate_daily` | 시도 대비 성공·도망·break_out, 미끼/돌 세그먼트 |
| `safari_session_daily` | 입장→퇴장 체류시간(중앙값), 미완결 비율 |
| `economy_daily` | 재화 faucet/sink |

### 읽을 때 반드시 알아야 할 것 셋

**① 포획 성공은 관측이 아니라 역산이다**

`POKEMON_CATCH_ATTEMPT` 와 `POKEMON_CATCH_FAIL` 은 `wildUid` 를 갖는데
**`POKEMON_CATCH`(성공)에는 없다.** 그래서 시도↔성공을 직접 이을 수 없다.

→ 같은 `(account_id, wild_uid)` 안에서 시도와 실패를 **순번으로 짝짓고, 실패가 안 붙은
시도를 성공으로** 본다. `caught_gap` 이 그 역산과 실제 `POKEMON_CATCH` 행 수의 차이다.
**실데이터에서 매일 0** 으로 나온다 — 역산이 맞다는 근거.

**② s000(튜토리얼)은 거의 모든 지표에서 제외된다**

`isS000Starter` 로 성공이 강제되고 도주도 꺼져 있어 섞으면 포획률이 통째로 위로 뜬다.
단 `SAFARI_BAIT`/`ROCK` 의 detail 에는 `mapId` 가 없어 **잔류율만은 s000 을 못 거른다.**

**③ 사파리 세션은 짝이 안 맞는 게 정상이다**

`SAFARI_ENTER` 는 plaza→safari 이고 s000 이 아닐 때만 발행되는데 `SAFARI_EXIT` 는
모든 이탈에서 발행된다. 창을 닫으면 EXIT 가 아예 없다.
→ **`unclosed_rate` 자체를 지표로 노출한다.** 그 비율이 튀면 서버 이상 신호다.

---

## 8. 검증 전략

### 8-1. 픽스처 — R2 도 prod 도 없이 전 구간을 돌린다

```bash
./fixtures/run-local.sh    # 검사 68건
```

`gen.py` 가 `archive-audit.sh` 의 출력 형식(gzip JSONL, 중첩 detail, 오프셋 포함
타임스탬프, `ip` 포함)을 **바이트 수준으로 흉내낸 가짜 아카이브**를 만들고, 파이프라인이
반드시 견뎌야 할 함정을 의도적으로 심는다.

시드가 고정이라 기계가 달라도 같은 결과가 나온다 — 맥에서 만든 것과 미니 PC 에서 만든
것의 행 수가 정확히 일치하는 걸 확인했다.

**검사 범위:** 멱등성 · 전량 재구축 · 마스킹 3종 · 타임존 · pokedex_id 정규형 ·
방어적 파싱 · 경계 조건 · 어서션 탐지력 · 대사 양방향 · 레시피 실행 · 대시보드 컬럼 대조

### 8-2. 3단 검증

| 단계 | 주기 | 무엇을 본다 |
| --- | --- | --- |
| `assertions.sql` | 적재 직후 자동 | 중복, 우리 마스킹, id 갭, 마스터 조인 손실 |
| `reconcile.sh` | 매일 19:30 UTC | **아카이브 ↔ 웨어하우스.** 적재 유실(복구 가능) / 아카이브 id 갭(복구 불가)을 나눠 알림 |
| `contract_drift.sql` | 수동 | 소스가 여전히 관측된 대로인지 |

### 8-3. 실제 박스에서만 드러난 버그들

로컬 픽스처가 못 잡고 미니 PC 에서 처음 드러난 것들. **전부 회귀로 편입했다.**

| 증상 | 원인 |
| --- | --- |
| 객체 46개를 찾고도 "적재 대상 없음" | `CREATE ... SECRET` 이 결과 행 `true` 를 뱉어 스캔 계획 파싱이 깨졌다. 로컬은 `SKIP_SECRETS=1` 이라 재현 안 됨 |
| 없는 마스터를 있다고 판정 → 404 | **원격(httpfs)에서 와일드카드 없는 `glob` 은 존재 확인을 하지 않는다.** 로컬 파일시스템은 정상 동작 |
| 테스트가 라이브 대시보드를 가짜 데이터로 덮어씀 | 회귀가 기본 출력 경로(= 서빙 디렉터리)에 JSON 을 구웠다 |
| 첫 에러 뒤 엉뚱한 에러가 원인을 가림 | `.bail on` 미설정 |

---

## 9. 운영

| | |
| --- | --- |
| 적재 + 대시보드 빌드 | 19:00 UTC (04:00 KST) |
| 대사 | 19:30 UTC (04:30 KST) |
| 로그 | `/var/log/poposafari/{load,check}.log` (logrotate 주간 8회전) |
| 알림 | Discord webhook |
| 대시보드 | `http://<tailscale-ip>:8080` |

**적재 전 하드링크 스냅샷** — DuckDB 는 파일을 제자리에서 고치지 않고 새 페이지를 쓰므로,
링크를 걸어두면 이전 상태가 보존된다. 디스크를 거의 안 쓰면서 즉시 롤백이 된다.

```bash
cp /srv/warehouse/poposafari.duckdb.prev /srv/warehouse/poposafari.duckdb
```

**대시보드 빌드를 `&&` 로 잇는 이유** — 적재가 실패한 날 낡은 JSON 을 덮어쓰지 않기
위해서다. 정적 대시보드의 가장 흔한 사고가 "최신처럼 보이는 옛 숫자"다.
같은 이유로 화면 상단에 마지막 적재 시각을 항상 띄우고, 36시간이 넘으면 빨갛게 경고한다.

---

## 10. 알려진 한계와 미해결 사항

### 10-1. 복구 불가능한 유실 창 (server 쪽 사안)

`archive-audit.sh` 는 export 하는 `SELECT` 와 `DELETE FROM audit_log WHERE id <= cutoff`
가 **별개 psql 세션**이다. bigserial 은 커밋 순서가 아니라 채번 순서라, 그 사이에 커밋된
행은 익스포트 없이 삭제된다. 예전 설계의 야간 재스윕이 메우던 갭인데 재스윕이 없다.

5분 랙이 완화할 뿐 없애지 못한다. → `reconcile.sh` 가 **탐지만** 한다.
막으려면 server 쪽에서 export 와 DELETE 를 한 세션으로 묶거나 DELETE 조건을 SELECT 와
일치시켜야 한다.

### 10-2. 365일 뒤 정본이 뒤집힌다

`audit/` 프리픽스의 lifecycle 은 365일이다. 그 뒤로는 **웨어하우스가 유일한 사본**이
되는데, `/srv/warehouse` 는 단일 소비자 디스크에 이중화가 없다.

그리고 복구 절차의 "전량 재구축"(`rm *.duckdb && run.sh`)이 그 시점부터
**1년 넘은 데이터를 영구 삭제하는 명령**이 된다.

1년 되기 전에 셋 중 하나: ① lifecycle 연장(가장 쌈, 하루 10–24MB) ② `.duckdb` 정기 백업
③ 오래된 구간 Parquet 반출.

### 10-3. `pg/` 와 버킷 공유

R2 API 토큰은 **버킷 단위로만** 스코프가 걸린다(프리픽스 단위 불가). `audit/` 와 `pg/` 가
한 버킷에 있는 이상 미니 PC 의 읽기 전용 토큰은 pg_dump 도 읽을 수 있다.

세션 토큰은 덤프에서 제외됐지만 **계정 비밀번호 해시는 남아 있다.**
선택지: 수용 / 버킷 분리(아카이브가 적은 지금이 가장 쌈) / `account` 도 덤프 제외.

### 10-4. 마스터 미적재

server 레포에 `push-master.sh` 가 아직 없어 `master/` 프리픽스가 비어 있다.
→ `pokemon_dim` 이 빈 스텁이라 **포켓몬 이름 조인이 안 된다.** 지표 4종은 마스터 없이도
전부 나온다.

### 10-5. 아직 안 만든 것

- **접속 세션 길이** — `SOCKET_CONNECT`/`SOCKET_DISCONNECT` + `ownedSlot` 로 지금도 가능
- **어뷰징 탐지 자동화** — 실제 어뷰징 1건이 확인되기 전까지는 수동 쿼리로 충분
- **중앙 로그 수집 / Parquet 전환 / 메트릭·APM** — 전부 트리거 조건이 붙어 있고 미달

---

## 부록 — 이 파이프라인이 견디는 함정

| 함정 | 조치 |
| --- | --- |
| **`pokedex_id` 형식 2종** | 정규형 = **패딩 문자열**. 정수 캐스팅 금지. 마스터 CSV 의 id 는 평문 정수(`1`)와 패딩 합성 id(`0058_hisui`)가 섞여 있고 스폰 소스는 전부 패딩이다. 정수로 정규화하면 변종 폼이 NULL 이 되어 조인이 조용히 사라진다 |
| **`created_at` 타임존** | `TIMESTAMPTZ` 로 캐스팅 후 `AT TIME ZONE 'UTC'` → `TIMESTAMP` 저장. 컬럼을 `TIMESTAMPTZ` 로 두면 조회 때마다 세션 TZ(KST)로 재해석되어 **9시간 밀린다** |
| **빈 글롭** | `glob()` 으로 먼저 세고 셸이 분기. `read_json` 은 0개 파일에 매칭되면 에러 |
| **hive 파티션 부재** | 경로에서 `YYYY/MM/DD` 정규식 추출 |
| **아카이브일 ≠ 이벤트일** | 스캔 창 7일로 넉넉히 |
| **타입 추론 갈림** | `columns` 명시 |
| **`detail` 무보증** | `json_extract_string` + `TRY_CAST`. 객체가 아닌 값과 NULL 이 온다 |
| **CRLF 마스터** | `rtrim(col, chr(13))` |
| **`status` 대부분 NULL** | 그대로 받는다. 포획·입장·거래가 전부 여기 해당 |
| **티켓은 건수가 아니라 장수** | `sum(detail.claimed)`. 한 건이 최대 3장 |
| **`load_log` 카운트** | 적재 전/후 차분 |
| **`ticketConsumed`** | 하드코딩 리터럴 `true` 라 신호가 0. 신호로 쓰지 않는다 |
