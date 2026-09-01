# PopoSafari 데이터 파이프라인 v3 — **data-pipeline 레포 작업 명세**

> 짝 문서: `plan-v3-server.md` (prod / 게임 서버 레포)
> 상위 문서: `data-pipeline-plan-v2.md` — 설계 근거와 트레이드오프는 그쪽에 있다.
>
> ⚠️ **이 문서는 계획서다. §1(계약)만은 계획이 아니라 실물로 다시 썼다.**
>    server 레포가 실제로 배포한 것이 계획과 달랐기 때문이다(2026-08-20, 커밋
>    `a8aa06d`·`9f00595`·`8e0d189`). 나머지 절의 설계 근거는 그대로 유효하되,
>    구현이 계획과 갈린 곳은 각 절에 **[실물]** 표시로 적어두었다.
>    현재 동작의 정본은 `README.md` 와 코드다.

---

## 0. 이 레포의 역할

**미니 PC `poposafari`(172.30.1.13)에서 도는 것 전부.** prod 박스에는 이 레포의 코드가 한 줄도 올라가지 않는다.

| | |
| --- | --- |
| 하드웨어 | Celeron N3150 4C/4T @1.6–2.08GHz, 7.7GB RAM(여유 6.6GB) + swap 4GB, LVM 루트 54.9G 중 37G 여유 |
| 도구 선택 | **DuckDB.** 싱글스레드가 느려 JVM 기반 BI(Metabase)는 부담. DuckDB가 이 박스에 정확히 맞는다 |
| 정본 | **R2.** 미니 PC 디스크는 단일 소비자 디스크, 이중화 없음. `poposafari.duckdb`는 언제든 재구축 가능한 파생물 |
| 입력 | R2 버킷 `poposafari-analytics` **하나뿐** |
| prod 접근 | **정기 파이프라인은 prod에 접근하지 않는다.** Tailscale은 ad-hoc 디버깅 전용 |

### 왜 pull이 아니라 push를 받는가

미니 PC가 Tailscale로 prod PG를 직접 pull하는 구성도 가능하다. 그런데도 R2 경유를 택한 이유:

- **신규 네트워크 노출 0.** pull은 5432를 Tailscale 대역에 바인딩 + 읽기전용 롤 생성이 선행 조건이다. push는 기존 R2 자격증명만 쓴다.
- **가정용 회선에 의존하지 않는다.** 미니 PC가 꺼져 있어도 prod 추출은 계속된다. 이 레포는 밀린 만큼 나중에 따라잡으면 된다.
- **버스터블 CPU 크레딧.** prod는 4GB/2vCPU 버스터블이다. 분석 쿼리가 거기 닿으면 게임 전체가 느려진다.

---

## 1. 인터페이스 계약 (server 레포와 공유)

**이 절은 계획이 아니라 [실물]이다.** 원래는 `plan-v3-server.md` §1 의 사본이었는데,
server 레포가 실제로 배포한 것이 그 사본과 전부 달랐다. 아래는 코드를 읽고 다시 쓴 것이다.

무엇을 근거로 하는지: `server/scripts/ops/archive-audit.sh` (커밋 `a8aa06d`),
`server/lib/schema/audit-log.ts`, `server/lib/utils/audit.ts`, `server/apps/api/app.ts`.

### 1-1. R2 레이아웃

```
s3://poposafari-analytics/
  audit/YYYY/MM/DD/audit-<UTC stamp>-<cutoff>.jsonl.gz   gzip JSONL

s3://poposafari-backups/    ← 읽지 않는다 (§8)
```

- `<cutoff>` 는 그 배치가 가져간 **max id**. 파일명이 곧 배치 경계라 대사에 쓴다.
- 경로의 날짜는 **아카이브일**이지 이벤트일이 아니다. 자정 근처 행은 다음 날 배치에
  실린다. hive 파티션(`dt=`)이 아니므로 정규식으로 뽑아 스캔 창을 자른다.
- **없는 것: `backfill/`(야간 재스윕), `master/`(마스터 푸시), `meta/`(일별 카운트).**
  계획서 원본은 셋 다 있다고 적었지만 어느 것도 만들어지지 않았다.
  `master/` 는 server 레포에 `push-master.sh` 가 생기면 채워진다.

> 계획서 원본은 `raw/dt=…/audit_<from>_<to>.csv.gz` + 야간 재스윕이었다.
> 그런 익스포터는 작성되지 않았고, 대신 **아카이브(=옮기고 지우는) 잡**이 생겼다.
> 이 차이가 §1-5 의 정본 뒤집힘과 §D5-2 의 대사 방식 변경을 낳았다.

### 1-2. 행 스키마 — 9컬럼, `ip` **있음**, `detail` 은 중첩 객체

`archive-audit.sh` 가 `SELECT row_to_json(t) FROM (SELECT * FROM audit_log …) t` 로 뽑는다.
`SELECT *` 이므로 테이블 컬럼이 그대로 나온다:

```
id BIGINT, account_id INTEGER, action VARCHAR, status SMALLINT,
detail JSON(중첩 객체), ip VARCHAR, user_agent VARCHAR, source VARCHAR,
created_at "2026-08-20T12:34:56.789+00:00"
```

- `detail` 은 jsonb 라 **진짜 JSON 객체**로 중첩된다. CSV 시절처럼 따옴표로 감싼
  문자열이 아니다 → 적재에서 `TRY_CAST(VARCHAR AS JSON)` 단계가 사라졌다.
- `created_at` 은 오프셋이 박힌 ISO 문자열이다 (postgres:15-alpine 에 TZ 미설정 → UTC).
  `TRY_CAST(… AS TIMESTAMPTZ) AT TIME ZONE 'UTC'` 로 받으면 세션 TZ 와 무관하게 결정적이다.
- `status` 는 **대부분 NULL** 이다. 채우는 건 `apps/api/app.ts` 의 onResponse/onError
  훅뿐이고, 그건 `request.audit` 를 쓴 액션에만 붙는다. `auditTx`/`auditAsync` 를 직접
  부르는 경로(포획·사파리 입장·거래·소켓)는 전부 NULL 이다.
- `source` 는 `'api' | 'socket' | 'worker'`. `worker` 는 게임루프가 남긴다.

### 1-3. 마스킹 — **이쪽 책임이다**

계획서 원본은 아래 3종을 "server 레포가 보장"으로 적었다. **셋 다 보장되지 않는다.**

| 항목 | 원본 계약 | 실물 | 이쪽 조치 |
| --- | --- | --- | --- |
| `ip` | 컬럼 부재 | `SELECT *` 라 실려 온다 | `load/10_load_audit.sql` 이 적재에서 드롭 |
| `REQUEST_REJECTED.detail.url` | `?` 없음 | `app.ts:150` 이 `request.url` 그대로 | `views/00_audit.sql` 이 `split_part(…,'?',1)` |
| `LOGIN_FAILED.detail.body.username` | 부재 | `REDACT_KEYS` 에 `username` 이 없다 | 뷰가 컬럼으로 꺼내지 않는다 |

따라서 `checks/assertions.sql` 의 목적도 바뀌었다 — "상대편 계약이 깨졌나"가 아니라
**"우리 마스킹이 동작하나"** 다. 소스가 여전히 그런 상태인지는
`checks/contract_drift.sql` 이 보고하며, 그건 매일 돌지 않는다.
매일 걸리는 알림은 죽은 알림이다.

**멱등성의 근거는 여전히 이쪽 안티조인이다.** 아카이브 객체는 보통 겹치지 않지만
`archive-audit.sh` 재실행 시 겹칠 수 있고, 그때도 행 수가 늘면 안 된다.

### 1-4. `detail` 스키마는 무보증

server 레포가 `detail`에 Zod 표준화를 하지 않기로 했다(v2 §Phase 2 각주).
**방어적 파싱은 이 레포의 책임이다.** 모든 뷰에서 `try_cast` / `json_extract` 실패를
NULL로 흡수하고, 절대 예외로 죽지 않게 한다.

jsonb 라 **문법이 깨진 JSON 은 올 수 없다**(그 함정은 사라졌다). 대신 여전히 온다:
`detail` 이 NULL 인 행, 그리고 객체가 아닌 값(문자열·배열). 둘 다 행을 죽이면 안 되고
필드 추출은 NULL 이어야 한다.

### 1-5. 정본이 뒤집혔다 — 그리고 복구 불가능한 유실 창

`archive-audit.sh` 는 업로드 뒤 `DELETE FROM audit_log` 를 하고,
`backup-pg.sh` 는 `--exclude-table-data=audit_log` 다(커밋 `8e0d189`).
→ **R2 아카이브가 유일본이고 이 웨어하우스가 두 번째 사본이다.**
`poposafari.duckdb` 를 "언제든 재구축 가능한 파생물"이라고 부를 수는 있지만,
그건 R2 객체가 살아 있는 동안만이다. R2 객체 자체에는 이중화가 없다.

그리고 export 하는 `SELECT` 와 `DELETE … WHERE id <= cutoff` 가 **별개 psql 세션**이다.
bigserial 은 커밋 순서가 아니라 채번 순서라, 그 사이에 커밋된 행은 익스포트 없이
삭제된다. 예전 설계에서는 야간 재스윕이 메웠지만 **재스윕이 없다.**
5분 랙(`AUDIT_LAG_MINUTES`)이 완화할 뿐 없애지 못한다.

→ `checks/reconcile.sh` 가 아카이브 자체의 id 갭으로 **탐지만** 한다.
   되찾을 수는 없다. server 쪽 수정이 필요한 사안이라 여기서는 기록만 한다.

### 1-6. 버킷 — prod ops 1회가 필요하다

`archive-audit.sh` 의 버킷은 `$R2_BUCKET` 이고, 그건 `.env.backup` 이 세팅한다
(기본 `poposafari-backups`). 그대로 두면 감사로그가 백업 버킷에 쌓이고
미니 PC 토큰 스코프를 그쪽으로 넓혀야 해서 §8 의 경계가 무너진다.

스크립트가 `BACKUP_ENV` 를 지원하므로 **server 코드 변경 없이** 갈린다:

```
# prod cron
BACKUP_ENV=/home/ubuntu/poposafari/server/docker/prod/.env.audit  …/archive-audit.sh
# .env.audit — .env.backup 사본에서 이 줄만 교체
R2_BUCKET=poposafari-analytics
```

이쪽은 `R2_BASE` 를 환경변수로 받으므로 어느 쪽이든 동작한다.

---

## 2. 레포 구조

```
poposafari-data-pipeline/
├── README.md                   부트스트랩 + 일상 운영
├── bootstrap/
│   ├── install.sh              DuckDB 설치, /srv/warehouse 준비, cron 등록
│   ├── secrets.sql.example     R2 자격증명 템플릿 (실물은 비커밋)
│   └── cron.d/poposafari       cron 정의
├── load/                       [실물] 파일이 늘었다 — §D2 참고
│   ├── 00_schema.sql           테이블 DDL (멱등)
│   ├── 05_scan.sql             읽을 객체 목록 → wh.scan_plan  ← 신규
│   ├── 10_load_audit.sql       R2 → wh.audit 안티조인 적재
│   ├── 15_load_log.sql         적재 이력 (건너뛴 실행도 남긴다)  ← 신규
│   ├── 20_load_master.sql      master/LATEST → wh.master_*
│   ├── 21_master_stub.sql      마스터 부재 시 빈 테이블          ← 신규
│   └── run.sh                  순서 실행 + 분기 + 실패 시 Discord
├── views/
│   ├── 00_audit.sql            방어적 파싱 뷰
│   ├── 10_master_join.sql      pokedex_id 정규화 조인
│   └── 20_metrics.sql          체류시간·포획률·DAU 등 파생 뷰
├── recipes/
│   ├── onboarding_8.sql        온보딩 §8의 5개 쿼리 이식
│   └── abuse/*.sql             어뷰징 탐지 (수동 실행)
├── checks/
│   ├── reconcile.sh            아카이브 ↔ 웨어하우스 대사 → Discord
│   ├── assertions.sql          우리 마스킹·중복·조인 자기점검 (적재 후 자동)
│   └── contract_drift.sql      소스 현재 상태 보고 (수동)        ← 신규
├── dashboard/                  [실물] 계획에 없던 것 — §12          ← 신규
│   ├── queries/*.sql           지표 뷰 → 90일 일별 시계열
│   ├── build.sh                duckdb -json → public/data/*.json
│   ├── check.sh                차트 컬럼 ↔ JSON 컬럼 대조
│   ├── public/                 index.html + app.js + Chart.js(벤더링)
│   └── serve/                  systemd 유닛 (정적 파일 서버)
└── docs/                       ← server 레포에서 이관 (plan-v3-server.md §S0-2)
    ├── audit-log-readonly-access.md
    └── data-engineering-onboarding.md
```

**계층은 3개가 아니라 2개다.** v2 §2 그대로 — `raw → stg → mart`는 BigQuery 과금 구조(뷰 무료, 스캔 유료)에 최적화된 형태다. DuckDB에는 스캔 과금이 없으므로 **raw 테이블 + 뷰**로 충분하다. mart를 물리화할 이유가 생기면 그때 `CREATE TABLE AS`.

---

## 3. D1 — 부트스트랩

### D1-1. `bootstrap/install.sh`

- [ ] DuckDB CLI 설치 (정적 바이너리 → `/usr/local/bin/duckdb`). apt 패키지는 버전이 낡음
- [ ] `/srv/warehouse` 생성, 소유자 지정, **퍼미션 0700**
      → §6의 PII 판단(디스크 암호화 없음)이 유효하려면 최소한 파일 권한은 조여야 한다
- [ ] `/srv/warehouse/secrets.sql` 배치 (0600, **레포 밖**)
- [ ] cron 등록
- [ ] 로그 디렉터리 + logrotate

### D1-2. `bootstrap/secrets.sql.example`

```sql
-- 실물은 /srv/warehouse/secrets.sql (0600). 레포에 커밋 금지.
-- R2 API 토큰은 poposafari-analytics 버킷 '읽기 전용'으로 발급할 것.
--   → 미니 PC가 침해돼도 prod 백업 버킷과 분석 원본을 건드릴 수 없다.
CREATE OR REPLACE PERSISTENT SECRET r2 (
  TYPE r2,
  ACCOUNT_ID '<CLOUDFLARE_ACCOUNT_ID>',
  KEY_ID     '<R2_ACCESS_KEY_ID>',
  SECRET     '<R2_SECRET_ACCESS_KEY>'
);
```

> ⚠️ **v2 §7에 없던 요구사항**: 미니 PC용 R2 토큰은 **읽기 전용 + 버킷 스코프**로 새로 발급한다. `backup-pg.sh`가 쓰는 쓰기 토큰을 재사용하면, 미니 PC 한 대가 prod 백업 전체의 삭제 권한을 갖게 된다. v2 §0-2의 *"R2 자격증명이 이미 뚫려 있다"*를 그대로 받으면 이 함정에 빠진다.

### D1-3. cron

```cron
# /etc/cron.d/poposafari
# 04:00 KST = 19:00 UTC.
# [실물] "prod 재스윕(03:10 UTC) 뒤여야 한다"는 조건은 사라졌다 — 재스윕이 없다.
#        지켜야 할 조건은 하나뿐이다: 스캔 창(7일)이 아카이브 주기보다 넓을 것.
0 19 * * *  poposafari  /opt/poposafari-data-pipeline/load/run.sh      >> /var/log/poposafari/load.log 2>&1
30 19 * * * poposafari  /opt/poposafari-data-pipeline/checks/reconcile.sh >> /var/log/poposafari/check.log 2>&1
```

> **[실물] 시각은 자유롭다.** 재스윕이 존재하지 않으므로 "그 뒤에 돌려야 한다"는
> 제약이 없다. `archive-audit.sh` 는 짧은 주기로 계속 돌며 `audit_log` 를 옮긴다.
> 하루 1회 + 7일 창이면 미니 PC 가 엿새 꺼져 있어도 따라잡는다.
> 대신 대시보드 빌드를 `&&` 로 잇는다 — 적재 실패한 날 낡은 JSON 을 덮어쓰지 않게.

---

## 4. D2 — 적재

### D2-1. `load/00_schema.sql`

> **[실물]** `created_at` 은 `TIMESTAMPTZ` 가 아니라 **`TIMESTAMP`(UTC 벽시계)** 로 담는다.
> `TIMESTAMPTZ` 컬럼으로 두면 조회할 때마다 세션 TZ(미니 PC = KST)로 재해석되어
> 9시간 밀린다. 소스 문자열에 `+00:00` 이 박혀 있으므로 적재에서 한 번만 정규화한다.
> 그리고 테이블이 셋 늘었다 — `scan_plan`(읽을 객체 목록), `scan_state`(스캔 창·적재 전
> 행 수), `src_shape`(소스 컬럼 스냅샷). 아래 DDL 은 초안이고 정본은 코드다.

```sql
INSTALL httpfs; LOAD httpfs;
INSTALL json;   LOAD json;

ATTACH IF NOT EXISTS '/srv/warehouse/poposafari.duckdb' AS wh;

CREATE TABLE IF NOT EXISTS wh.audit (
  id         BIGINT PRIMARY KEY,
  account_id INTEGER,
  action     VARCHAR,
  status     SMALLINT,
  detail     JSON,
  user_agent VARCHAR,
  source     VARCHAR,
  created_at TIMESTAMPTZ
);

-- 적재 이력 — "언제 어디까지 넣었나"를 남긴다. 대사(§7)와 장애 조사에 쓴다.
CREATE TABLE IF NOT EXISTS wh.load_log (
  run_at      TIMESTAMPTZ,
  scanned_from DATE,
  rows_inserted BIGINT,
  max_id      BIGINT
);
```

### D2-2. `load/10_load_audit.sql`

> **[실물] 아래 SQL 은 CSV 시절 초안이다. 실제 구현은 다르다.** 요지만 옮기면:
>
> | 초안 | 실물 | 이유 |
> | --- | --- | --- |
> | `read_csv('…/{raw,backfill}/dt=*/*.csv.gz')` | `read_json(<파일 리스트>, format='newline_delimited')` | 소스가 JSONL 이다 |
> | hive `dt=` 파티션 | 경로 `audit/YYYY/MM/DD/` 를 정규식으로 파싱 | 파티션 키가 없다 |
> | 글롭을 바로 전달 | `glob()` 으로 먼저 세어 `wh.scan_plan` 에 적고 셸이 분기 | **`read_json` 은 0개 파일에 매칭되면 에러다.** R2 가 빈 첫날에도 성공해야 한다 |
> | `TRY_CAST(detail AS JSON)` | `detail` 을 `'JSON'` 으로 직접 받음 | jsonb 라 중첩 객체로 온다 |
> | `ORDER BY id, filename LIKE '%/backfill/%' DESC` | `ORDER BY id` | 재스윕이 없어 우선순위 규칙이 무의미하다 |
> | (해당 없음) | `ip` 를 SELECT 하지 않음 | 마스킹 책임이 이쪽으로 넘어왔다 (§1-3) |
>
> 아래 표의 ①②는 지금도 유효한 판단이고, ③④는 소스 변경으로 무의미해졌다.

v2 §7에서 **두 곳을 바꿨다.** 이유는 아래.

```sql
SET VARIABLE scan_from = (
  -- 평소엔 7일. 첫 실행(빈 테이블)이면 전량.
  SELECT CASE WHEN (SELECT count(*) FROM wh.audit) = 0
              THEN DATE '2026-01-01'
              ELSE current_date - 7 END
);

INSERT INTO wh.audit
SELECT s.id, s.account_id, s.action, s.status,
       TRY_CAST(s.detail AS JSON),        -- ★ 변경 ②
       s.user_agent, s.source, s.created_at
FROM (
  SELECT DISTINCT ON (id) *
  FROM read_csv(
        'r2://poposafari-analytics/{raw,backfill}/dt=*/*.csv.gz',
        hive_partitioning = true,
        header = true,
        -- ★ 변경 ① 타입 명시. auto-detect에 맡기면 파일마다 추론이 갈린다
        columns = {
          'id':'BIGINT', 'account_id':'INTEGER', 'action':'VARCHAR', 'status':'SMALLINT',
          'detail':'VARCHAR', 'user_agent':'VARCHAR', 'source':'VARCHAR',
          'created_at':'TIMESTAMPTZ'
        })
  WHERE dt >= getvariable('scan_from')::VARCHAR
  ORDER BY id, dt DESC          -- 겹치면 재스윕(backfill) 쪽을 채택
) s
WHERE NOT EXISTS (SELECT 1 FROM wh.audit a WHERE a.id = s.id);

INSERT INTO wh.load_log
SELECT now(), getvariable('scan_from')::DATE,
       (SELECT count(*) FROM wh.audit) , (SELECT max(id) FROM wh.audit);
```

**v2 §7에서 바꾼 것**

| | v2 | v3 | 이유 |
| --- | --- | --- | --- |
| ① 타입 | auto-detect | `columns` 명시 | 어떤 날 `status`가 전부 비면 그 파일만 VARCHAR로 추론되고, `union_by_name`이 타입 충돌을 일으킨다. **가장 흔한 조용한 실패** |
| ② `detail` | 그대로 | `VARCHAR` 읽고 `TRY_CAST(... AS JSON)` | PG의 `jsonb`가 CSV에선 따옴표 감싼 문자열이다. 바로 JSON으로 읽으면 파싱 실패 시 **행 전체가 죽는다**. `TRY_CAST`는 NULL로 흡수(§1-4) |
| ③ 경로 | `'…/*/dt=*/*.csv.gz'` | `'…/{raw,backfill}/dt=*/*.csv.gz'` | `*`는 미래에 추가될 `master/` 까지 긁는다 |
| ④ 중복 우선순위 | `DISTINCT ON (id)` | `ORDER BY id, dt DESC` 추가 | 증분과 재스윕에 같은 id가 있을 때 **어느 쪽을 택할지 결정적**으로. 재스윕이 나중 데이터라 우선 |

**성질**: 재실행 안전(안티조인), 파일 겹침 안전(`DISTINCT ON`), 스캔 7일 고정 → Celeron에서도 초 단위. R2가 정본이므로 `poposafari.duckdb`가 깨지면 `scan_from`만 넓혀 전체 재구축 — **미니 PC 디스크에 이중화가 없어도 되는 이유.**

### D2-3. `load/20_load_master.sql`

> **[실물]** server 레포에 `push-master.sh` 가 **아직 없다.** `master/` 프리픽스가
> 비어 있는 게 현재의 정상 상태다. 그런데 `views/10_master_join.sql` 은 CREATE VIEW
> 시점에 컬럼을 검증하므로, 원본 테이블이 없으면 뷰 생성이 죽고 지표 뷰까지 연쇄로
> 못 만든다. → `run.sh` 가 `master/LATEST` 유무로 분기해, 없으면
> `21_master_stub.sql` 로 빈 테이블을 세운다. 어서션의 조인 손실 검사도
> 마스터가 비었으면 건너뛴다(전건 오탐이 되므로).

server 레포 `push-master.sh`가 올린 마스터를 읽는다. **복사본을 이 레포에 두지 않는다** — 밸런스 커밋마다 바뀌므로 조용히 낡는다.

```sql
SET VARIABLE mver = (SELECT content FROM read_text('r2://poposafari-analytics/master/LATEST'));

CREATE OR REPLACE TABLE wh.master_pokemon AS
SELECT * FROM read_csv(
  'r2://poposafari-analytics/master/v=' || getvariable('mver') || '/pokemon.csv',
  header = true, all_varchar = true);   -- 타입은 뷰에서. CSV 스키마 변동에 내성

CREATE OR REPLACE TABLE wh.master_item AS
SELECT * FROM read_csv(
  'r2://poposafari-analytics/master/v=' || getvariable('mver') || '/item.csv',
  header = true, all_varchar = true);

CREATE OR REPLACE TABLE wh.master_version AS SELECT getvariable('mver') AS sha, now() AS loaded_at;
```

> ⚠️ `pokemon.csv`는 **CRLF**다(v2 §Phase 4). DuckDB가 `\r\n`을 처리하지만 마지막 컬럼에 `\r`이 남는 경우가 있다. 뷰에서 `rtrim(col, chr(13))`으로 방어하고, 적재 직후 아래로 확인:
> ```sql
> SELECT count(*) FROM wh.master_pokemon WHERE columns(*)::VARCHAR LIKE '%' || chr(13) || '%';
> ```

### D2-4. `load/run.sh`

- [ ] `secrets.sql` → `00_schema` → `10_load_audit` → `20_load_master` 순서 실행
- [ ] `set -euo pipefail`, 어느 단계든 실패 시 **Discord webhook** (server 레포 `.env.backup`의 `DISCORD_WEBHOOK_ALERTS`와 같은 채널)
- [ ] 실행 전 `duckdb` 파일을 **하드링크 스냅샷**으로 백업(`poposafari.duckdb.prev`) — 적재 중 크래시로 파일이 깨져도 즉시 롤백. R2 재구축(수분~수십분)보다 싸다
- [ ] 성공 시 Healthchecks.io ping (**server 익스포터와 다른 체크**. period 1d / grace 6h)

---

## 5. D3 — 뷰 계층

### D3-1. `views/00_audit.sql` — 방어적 파싱 **그리고 마스킹**

> **[실물]** 이 뷰가 PII 경계를 겸한다 (§1-3). `req_url` 은 `split_part(…,'?',1)` 로
> 자르고, `body.username` 은 편의 컬럼으로 꺼내지 않는다. `ip` 는 그 앞 단계(적재)에서
> 이미 떨어졌다. 아래 초안에 없는 컬럼도 여럿 늘었다 — `wild_uid`, `used_bait`,
> `used_rock`, `catch_reason`, `flee_result`, `ticket_claimed` 등. 8/20 에 늘어난
> 액션들을 위한 것이고 정본은 코드다.
>
> `AT TIME ZONE 'Asia/Seoul'` 은 쓰지 않는다 — `created_at` 이 이미 UTC 벽시계
> `TIMESTAMP` 라 `+ INTERVAL 9 HOUR` 가 맞다. 초안대로 하면 9시간 밀린다.

`detail` 무보증(§1-4)을 여기서 한 번만 흡수하고, 상위 뷰는 이 뷰만 본다.

```sql
CREATE OR REPLACE VIEW wh.audit_v AS
SELECT
  id, account_id, action, status, user_agent, source, created_at,
  created_at AT TIME ZONE 'Asia/Seoul'            AS created_at_kst,
  detail,
  -- 자주 쓰는 필드만 안전 추출. 없으면 NULL, 타입 안 맞으면 NULL
  TRY_CAST(json_extract_string(detail, '$.mapId')     AS VARCHAR)  AS map_id,
  TRY_CAST(json_extract_string(detail, '$.pokedexId') AS INTEGER)  AS pokedex_id,
  TRY_CAST(json_extract_string(detail, '$.isShiny')   AS BOOLEAN)  AS is_shiny,
  TRY_CAST(json_extract_string(detail, '$.result')    AS VARCHAR)  AS catch_result,
  TRY_CAST(json_extract_string(detail, '$.money')     AS BIGINT)   AS money_after,
  coalesce(TRY_CAST(json_extract_string(detail, '$.isS000Starter') AS BOOLEAN), false)
                                                                    AS is_starter
FROM wh.audit;
```

> `money_after`가 핵심 자산이다. `ITEM_BUY`/`ITEM_SELL`의 `detail.money`는 **거래 후 잔고**이므로, `user.money` 스냅샷 없이도 **유저별 잔고 시계열이 복원된다**(v2 §0-1). 잔고 스냅샷 잡(v2 §Phase 5)이 보류인 이유.

### D3-2. `views/10_master_join.sql` — `pokedex_id` 정규화

**v2 §Phase 4가 지목한 최대 함정.** 서버 CSV는 `1`, 클라이언트/`map.json`은 `0001`. SQL 직접 조인은 안 맞는다.

```sql
CREATE OR REPLACE VIEW wh.pokemon_dim AS
SELECT
  TRY_CAST(rtrim(pokedex_id, chr(13)) AS INTEGER)          AS pokedex_id,     -- 정규형: 정수
  lpad(rtrim(pokedex_id, chr(13)), 4, '0')                 AS pokedex_id_4,   -- map.json 조인용
  rtrim(name, chr(13))                                     AS name,
  rtrim(type1, chr(13))                                    AS type1,
  rtrim(tier,  chr(13))                                    AS tier,
  TRY_CAST(rtrim(rate_capture, chr(13)) AS DOUBLE)         AS rate_capture,
  TRY_CAST(rtrim(rate_flee,    chr(13)) AS DOUBLE)         AS rate_flee
FROM wh.master_pokemon;
```

- [ ] **정규형을 정수로 고정한다.** `audit_v.pokedex_id`도 정수다. `map.json` 조인이 필요할 때만 `pokedex_id_4`를 쓴다
- [ ] 실제 컬럼명은 `lib/master/pokemon.csv` 헤더로 확인 후 확정 (위는 추정)
- [ ] 조인 손실 검증을 assertion으로:
      ```sql
      SELECT count(*) FROM wh.audit_v a
      LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
      WHERE a.pokedex_id IS NOT NULL AND p.pokedex_id IS NULL;   -- 0 이어야 함
      ```

### D3-3. `views/20_metrics.sql` — 파생 지표

> **[실물] S2 는 이미 배포됐다** (커밋 `9f00595`, 2026-08-20). 이 절이 "BLOCKED"로
> 적어둔 것 중 셋이 지금 만들어져 있다.

| 뷰 | 필요한 계측 | 상태 |
| --- | --- | --- |
| `money_series` / `economy_daily` | 기존 `ITEM_BUY`/`ITEM_SELL` | 구현됨 |
| `dau_daily` | (없음) + `CREATE_USER` | 구현됨 — **지표2** |
| `bait_rock_daily` | `SAFARI_BAIT`/`SAFARI_ROCK` + `POKEMON_CATCH_ATTEMPT` | 구현됨 — **지표1** |
| `catch_attempt` / `catch_rate_daily` | `POKEMON_CATCH_ATTEMPT`/`_FAIL` | 구현됨 |
| `safari_session` / `_daily` | `SAFARI_ENTER` + `SAFARI_EXIT` | 구현됨 |
| 접속 세션 길이 | `SOCKET_CONNECT`/`SOCKET_DISCONNECT` | 미착수 (지금도 가능) |

계획서가 `SESSION_START`/`SESSION_END`(S2-3) 라고 부른 것은 실제로는
**`SOCKET_CONNECT`/`SOCKET_DISCONNECT`** 이고, 소유권 플래그도 `isOwner` 가 아니라
**`ownedSlot`** 이다 (`apps/socket/app.ts:322`, `718`). 이름이 다르니 코드를 볼 것.

읽을 때 알아야 할 세 가지:

- **포획 성공은 관측이 아니라 역산이다.** `POKEMON_CATCH` 에 `wildUid` 가 없어
  시도↔성공을 직접 이을 수 없다. 같은 `(account_id, wild_uid)` 안에서 시도와 실패를
  순번으로 짝짓고 실패가 안 붙은 시도를 성공으로 본다. `caught_gap` 이 그 역산과
  실제 `POKEMON_CATCH` 행 수의 차이다.
- **s000(튜토리얼)은 제외한다.** `isS000Starter` 로 성공이 강제되고 도주가 꺼져 있다.
  단 `SAFARI_BAIT`/`ROCK` 의 detail 에는 `mapId` 가 없어 잔류율만은 못 거른다.
- **분모가 분자보다 헐겁다.** ATTEMPT/FAIL 은 `auditAsync`(트랜잭션 밖),
  CATCH 는 `auditTx`(안)다. 롤백·유실이 양방향으로 오차를 만든다.

**페어링 주의**: 짝이 안 맞는 경우가 **정상적으로 발생한다**(크래시, 킥, 배포 중 종료).
`LEAD() OVER (PARTITION BY account_id ORDER BY created_at)` 로 다음 이벤트를 붙이고,
짝 없는 건 NULL 체류시간으로 두되 **비율을 지표로 노출한다**(`unclosed_rate`).
그 비율이 튀면 그 자체가 서버 이상 신호다.

> **[실물] 구조적으로도 안 맞는다.** `SAFARI_ENTER` 는 plaza→safari 이고 mapId 가
> s000 이 아닐 때만 발행되는데(`safari.service.ts:96` — 티켓 소모 경로에만 달려 있다),
> `SAFARI_EXIT` 는 모든 사파리 이탈에서 발행된다(`safari.controller.ts:44`).
> → **튜토리얼(s000)은 EXIT 만 남는다.** 남겨두면 바로 앞 세션의 종료로 잘못 붙어
> 체류시간을 늘리므로 s000 을 페어링에서 통째로 제외한다.
> 사파리→사파리 이동도 ENTER 를 새로 남기지 않아, 한 쌍이 여정 전체를 덮는다.

---

## 6. D4 — 레시피

### D4-1. `recipes/onboarding_8.sql`

온보딩 §8의 5개 쿼리를 DuckDB 문법으로 이식. **주석을 그대로 옮긴다** — 특히 `isS000Starter=true` 제외 규칙 같은 도메인 지식.

- [ ] prod 직접 실행분과 결과 대조 (§7 V4)
- [ ] PG↔DuckDB 문법 차이 주의: `interval '30 days'` → `INTERVAL 30 DAY`, `detail->>'x'` → `json_extract_string(detail,'$.x')`, `count(*) FILTER (WHERE …)`는 양쪽 동일

### D4-2. `recipes/abuse/` — 인프라가 아니라 쿼리

v2 §8 그대로: 유저 수가 붙기 전 스케줄 쿼리 + 알림 파이프라인은 과잉이다. **주 1회 사람이 돌린다.**

```sql
-- shiny_binomial.sql
-- 샤이니 비율 이항검정 — rollSafariShiny = 1/4096 고정 (server: lib/utils/rng.ts)
-- 조작 시 통계적으로 즉시 드러난다. 튜토리얼 강제 포획(isS000Starter)은 제외.
SELECT account_id,
       count(*)                                     AS catches,
       count(*) FILTER (WHERE is_shiny)             AS shiny,
       count(*) / 4096.0                            AS expected
FROM wh.audit_v
WHERE action = 'POKEMON_CATCH' AND NOT is_starter
  AND created_at > now() - INTERVAL 30 DAY
GROUP BY 1
HAVING catches >= 200 AND shiny > expected * 4
ORDER BY shiny - expected DESC;
```

**나머지 룰 — 착수 조건이 있다:**

| 룰 | 상태 |
| --- | --- |
| 시간당 포획 시도 z-score | **[실물] S2-2 는 배포됐다.** `POKEMON_CATCH_ATTEMPT` 로 분모가 생겼다 |
| `money` 급증 | **지금 가능.** `money_after` 시계열의 1차 차분 |
| 티켓 소모 없는 `SAFARI_ENTER` | 지금 가능. ⚠️ **획득은 건수가 아니라 장수로 세야 한다** — `SAFARI_TICKET_CLAIM` 한 건이 최대 3장이다(`detail.claimed`). 건수로 세면 전원이 오탐으로 걸린다 |
| **임의 좌표 이동** | **S4-1 수정 후.** `MAP_CHANGE.detail.rejected=true` 가 신호원 |
| ~~볼 소모 대비 성공률~~ | **작성 보류.** server 레포 S4-3 — 현재 볼이 성공 시에만 소모되므로 항상 1:1이라 신호가 없다 |
| ~~`item.buy` 잔액 레이스~~ | **제외.** `ck_user_money` CHECK 제약이 막는다. 어뷰징이 아니라 500 에러 문제 (server 레포 S4-2) |

> v2 §8이 "미검증"으로 남긴 두 항목은 server 레포에서 코드 확인이 끝났다. 하나는 실재(좌표), 하나는 오판(잔액)이다. **탐지 룰을 짜기 전에 수정이 먼저**라는 v2의 결론은 좌표 쪽에 대해 옳았다.

---

## 7. D5 — 검증과 대사

### D5-1. `checks/assertions.sql` — 매 적재 후 자동

전부 **0행이어야** 한다. 하나라도 걸리면 Discord.

> **[실물] 이 파일의 목적이 바뀌었다.** 아래 ②(마스킹 위반)는 상대편 계약이 깨졌는지를
> 탐지하려던 것인데, 그 계약은 **처음부터 지켜진 적이 없다**(§1-3). 그대로 두면 매일
> 걸려서 알림이 죽는다.
> → 마스킹은 이쪽에서 하고, 어서션은 **우리 마스킹이 동작하는지**를 본다:
>   `wh.audit` 에 `ip` 컬럼이 없는가 / `audit_v.req_url` 에 `?` 가 없는가 /
>   `audit_v` 에 username 컬럼이 없는가.
> 소스의 현재 상태는 `checks/contract_drift.sql` 이 따로 보고하며 자동 실행되지 않는다.
>
> 아래 ⑤(`DESCRIBE wh.audit` 에 ip 가 없어야 함)는 원문 그대로는 **죽은 코드**였다 —
> 우리가 만든 DDL 을 우리가 검사하는 것이라 영원히 0행이다. 지금은 "누군가 적재 SQL 에
> ip 를 되살렸는지"를 잡는 회귀 가드로 의미를 다시 붙였다.

```sql
-- ① 중복
SELECT 'dup' AS check, id::VARCHAR AS v FROM wh.audit GROUP BY id HAVING count(*) > 1
UNION ALL
-- ② 마스킹 위반 — 상대편 계약(§1-3) 파기 탐지
SELECT 'unmasked_url', id::VARCHAR FROM wh.audit_v
WHERE action = 'REQUEST_REJECTED' AND json_extract_string(detail,'$.url') LIKE '%?%'
UNION ALL
SELECT 'unmasked_username', id::VARCHAR FROM wh.audit_v
WHERE action = 'LOGIN_FAILED' AND json_extract_string(detail,'$.body.username') IS NOT NULL
UNION ALL
-- ③ id 연속성 — 갭이 크면 유실 의심 (커밋 순서 갭은 재스윕이 메우므로 다음날 사라져야 함)
SELECT 'gap', (prev || '→' || id) FROM (
  SELECT id, lag(id) OVER (ORDER BY id) AS prev FROM wh.audit
  WHERE created_at > now() - INTERVAL 3 DAY
) WHERE id - prev > 1000
UNION ALL
-- ④ 마스터 조인 손실
SELECT 'orphan_pokedex', a.pokedex_id::VARCHAR FROM wh.audit_v a
LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
WHERE a.pokedex_id IS NOT NULL AND p.pokedex_id IS NULL;
```

```sql
-- ⑤ ip 컬럼 부재 — DESCRIBE 결과에 ip가 없어야 함
DESCRIBE wh.audit;
```

> ③의 갭 임계(1000)는 임시값이다. 첫 2주 실측으로 조정한다.
>
> ⚠️ **[실물] "재스윕이 다음날 메운다"는 더 이상 사실이 아니다.** 재스윕이 없다.
> 여기 걸린 갭은 롤백된 트랜잭션이 번호만 소모한 것이거나, §1-5 의 유실 창에서
> 사라진 행이다. 후자라면 **영구 유실**이고 되찾을 수 없다.

### D5-2. `checks/reconcile.sh` — 아카이브 대사

> **[실물] 대사 대상이 통째로 바뀌었다.** 원안은 prod 가 재스윕 때 올리는
> `meta/counts.csv.gz`(일별 카운트 14일)를 읽는 것이었는데 그런 객체는 만들어지지 않는다.
> prod 에 psql 로 붙어도 소용이 없다 — `archive-audit.sh` 가 업로드 직후
> `DELETE FROM audit_log` 를 해서 prod 테이블은 상시 거의 비어 있다.
> **아카이브가 정본이고 웨어하우스가 사본이므로, 대사는 그 둘 사이에서만 뜻이 있다.**
> prod 접근 0 이라는 §0 원칙은 그대로 지켜진다(오히려 더 확실히).

성격이 다른 두 가지를 보고 따로 알린다.

| | 무엇 | 누구 잘못 | 복구 |
| --- | --- | --- | --- |
| **A** | 아카이브에 있는데 웨어하우스에 없는 id | 이쪽 (적재 유실) | `load/run.sh` 재실행이 안티조인으로 메운다 |
| **B** | 아카이브 자체의 id 갭 | 저쪽 (§1-5 유실 창) | **불가능** |

- 최근 14일 아카이브 객체에서 **id 만** 읽는다. 전 컬럼을 읽으면 적재와 같은 비용이 든다.
- B 는 롤백된 트랜잭션이 번호만 소모한 경우와 모양이 같으므로 `GAP_THRESHOLD`(기본 1000)를
  넘는 것만 알린다. 첫 2주 실측으로 조정할 것.
- 창 안에 객체가 하나도 없으면(첫 배포일) 조용히 통과한다.
  `read_json` 이 빈 입력에 에러를 내므로 개수를 먼저 센다.

> ⚠️ **prod 60일 컷(`janitor.ts`)은 이제 논점이 아니다.** `archive-audit.sh` 가 5분 랙으로
> 계속 비우므로 60일까지 살아남는 행이 없다. 그리고 `dailyPrune` 이 부팅 시 돌지 않던
> 문제는 server 커밋 `f2611d4` 가 고쳤다(`janitor.ts:83`, `runOnStart=true`).
> **"어느 날 갑자기 prod 카운트가 줄면 prune 이 처음 돈 것"이라는 예전 경고는 폐기한다.**

### D5-3. 수용 기준

| Phase | 기준 |
| --- | --- |
| D1–D2 | 첫 적재 후 `wh.audit` 행 수 > 0, assertions 전부 0행, `load_log` 기록됨 |
| D2 재실행 | 같은 잡을 2회 연속 실행 → **행 수 변화 0** |
| D2 복구 | `poposafari.duckdb` 삭제 → `scan_from`이 자동으로 전량 → 원래 행 수 복원 |
| D2 빈 입력 | R2 에 객체 0개 → **정상 종료**하고 `load_log` 에 이력이 남는다 |
| D2 마스킹 | `wh.audit` 에 `ip` 컬럼 없음, `audit_v.req_url` 에 `?` 없음 |
| D3 | `pokemon_dim` 조인 고아 0행, CRLF 잔재 0행, 마스터 없어도 뷰 전부 컴파일 |
| D5-2 | 아카이브 ↔ 웨어하우스 불일치 0 |
| D4-1 | 온보딩 §8 6개 쿼리가 prod 직접 실행분과 **동일 결과** |
| 대시보드 | `build.sh` 성공, `check.sh` 의 시리즈 키 불일치 0 |

**[실물]** 이 전부를 `fixtures/run-local.sh` 가 R2 없이 자동으로 돌린다(59건).
prod 에 붙기 전에 여기가 초록이어야 한다.

---

## 8. 보안·PII 경계

이 레포가 지켜야 할 것 (v2 §4에서 이 레포에 해당하는 부분 + 추가분):

| 항목 | 조치 |
| --- | --- |
| R2 토큰 | **읽기 전용 + `poposafari-analytics` 스코프**로 신규 발급 (D1-2). 백업 버킷 토큰 재사용 금지 |
| `poposafari-backups` | **읽지 않는다.** ⚠️ [실물] 근거가 바뀌었다 — server 커밋 `8e0d189` 가 `pg_dump` 에서 `session`·`audit_log` **데이터**를 뺐으므로 "살아있는 `session.id`" 는 더 이상 없다. 그래도 계정 비밀번호 해시가 남아 있고 분석에 필요하지도 않으므로 원칙은 유지한다. 단 §1-6 의 ops 를 안 하면 감사로그가 이 버킷에 쌓여 원칙 자체가 성립하지 않는다 |
| `ip` | [실물] 소스에 실려 온다. **적재에서 버린다** — 안 버리면 웨어하우스에 영구 보존된다 |
| `url` 쿼리스트링 / `body.username` | [실물] 뷰에서 막는다. server 가 보장하지 않는다 (§1-3) |
| 대시보드 | [실물] 인증 없음. **집계값만** 있고 `account_id` 조차 나가지 않는다. 대신 `0.0.0.0` 이 아니라 LAN/Tailscale 주소에만 바인드한다 |
| `/srv/warehouse` | 0700. LVM plain이라 디스크 암호화 없음 — 물리 도난 시 노출. 1인 가정 환경에서 수용 가능으로 판단하되 **명시해둔다** |
| `secrets.sql` | 0600, 레포 밖, `.gitignore`에 `*.duckdb`·`secrets.sql` |
| `account_id` | 가명 식별자. 로컬 분석이라 해싱 실익 없음. **외부 공유 시에만** `md5(account_id \|\| salt)` |
| `LOGIN_OAUTH.detail.providerId` | 1차 적재는 유지. 직접 식별자지만 계정 매핑 디버깅에 실사용 가치 → §9-1에서 판단 |
| 국외이전 | **해당 없음.** 자체 호스팅. v2 §4 그대로 |

---

## 9. 결정이 필요한 사항

1. **`LOGIN_OAUTH.detail.providerId` 해싱** — 직접 식별자. 1차 유지 후, D3 뷰가 안정된 뒤 판단. 해싱하면 계정 매핑 디버깅이 불가능해지므로 **원본을 별도 제한 뷰에 두고 일반 뷰는 해시**가 절충안.
2. ~~**`audit_log` 원본 60일 보존 단축**~~ — **[실물] 논점이 사라졌다.**
   `archive-audit.sh` 가 5분 랙으로 계속 비우므로 60일까지 살아남는 행이 없다.
   `dailyPrune` 이 부팅 시 안 돌던 문제도 server 커밋 `f2611d4` 가 고쳤다.
   대신 새 논점이 생겼다: **§1-5 의 유실 창을 server 쪽에서 막을 것인가.**
   export 와 DELETE 를 한 트랜잭션/한 세션으로 묶거나 DELETE 조건을 SELECT 와
   일치시키면 된다. 이 레포는 탐지만 할 수 있다.
3. **운영 문서 이관 범위** — `plan-v3-server.md` §S0-2. `audit-log-readonly-access.md`·`data-engineering-onboarding.md`는 이쪽으로, `runbook-restore.md`는 server 레포에 남기는 안을 권장.

---

## 10. 승격 경로 (착수 금지 · 조건부)

v2 §Phase 5 그대로. **전부 트리거를 만족할 때까지 착수하지 않는다.**

| 항목 | 트리거 |
| --- | --- |
| ~~**BI GUI**~~ | **[실물] 착수됨.** 다만 Evidence.dev 가 아니라 **정적 JSON + Chart.js** 로 갔다(§12). 지표 2개를 위해 Node 20 + node_modules 를 미니 PC 에 들이는 건 과했다. 지표가 10개를 넘어 정적 HTML 이 손에 부치면 그때 Evidence 로 옮긴다 |
| **어뷰징 탐지 자동화** | 실제 어뷰징 1건 확인. 그전까지 §6의 수동 쿼리 |
| **중앙 로그 수집** (Loki/Alloy) | "로그 찾느라 SSH 주 3회 이상". 그때도 **Alloy는 미니 PC 쪽에** 두고 Tailscale로 tail → prod 부하 0 |
| **Parquet 전환** | CSV.gz 스캔이 느려질 때. 상한 시나리오에서도 10–24MB/일이라 수년은 CSV로 충분 |
| **메트릭/APM** | 정식 출시 후. prod 4GB 마진 판단이 아직 유효 |
| **게임 월드 팩트 로깅** (날씨/게임시간/스폰) | 밸런스 분석을 실제로 시작할 때 — **server 레포 작업**이다 |
| **잔고 스냅샷 잡** | `money_after`로 복원이 안 되는 질문이 생길 때(거래 없는 유저) |

---

## 11. 순서와 의존

**[실물] 이 그래프는 완료됐다.** server S1(아카이브)·S2(계측 확장)가 모두 배포되어
있어 대기 중인 항목이 없다.

```
[server S1 = archive-audit.sh]  배포됨 (a8aa06d)
[server S2 = 감사로그 확장]      배포됨 (9f00595)
        │
        ▼
D1 부트스트랩 ─→ D2 적재 ─→ D5-1 어서션 ─→ D5-2 대사
                   │
                   ├─→ D3-1 audit_v ─→ D4-1 온보딩 §8
                   │                 └─→ money_series / economy_daily
                   ├─→ D3-3 지표: bait_rock_daily, dau_daily,
                   │              catch_rate_daily, safari_session
                   │                 └─→ §12 대시보드
                   └─→ D3-2 pokemon_dim   ← [server push-master 대기, 스텁으로 우회]
```

남은 의존은 둘뿐이다:

- **`push-master.sh`** (server) — 없으면 `pokemon_dim` 이 빈 스텁이라 포켓몬 이름 조인이
  안 된다. 지표 4종은 마스터 없이도 전부 나온다.
- **§1-6 버킷 ops** (prod) — 안 하면 R2_BASE 를 백업 버킷으로 돌려야 한다.

---

## 12. 대시보드 (계획에 없던 것)

지표를 CLI 로만 보는 게 불편해져서 만들었다. §10 의 "BI GUI" 승격 경로에 해당하지만
거기 적힌 Evidence.dev 대신 **정적 JSON + Chart.js** 로 갔다.

**왜 Evidence 가 아닌가.** 지표 2개(+2개)를 위해 Node 20 과 수백 MB node_modules 를
Celeron N3150 에 들이고 매일 수 분짜리 빌드를 도는 건 과했다. `duckdb -json` 이 이미
JSON 배열을 뱉으므로 굽는 쪽은 셸 스크립트 한 장이면 되고, 그리는 쪽은 벤더링한
Chart.js 하나로 끝난다. **상시 프로세스가 정적 파일 서버 하나로 유지된다** —
`install.sh` 머리말의 "상시 컴포넌트가 두 개째 생기면 compose 로 승격" 조건을
아직 건드리지 않는다.

| | |
| --- | --- |
| 굽기 | `dashboard/build.sh` — cron 에서 `load/run.sh && dashboard/build.sh`. 적재 실패한 날 낡은 JSON 을 덮어쓰지 않으려고 `&&` 로 잇는다 |
| 범위 | 항상 90일치. 기간 토글(7/30/90)은 클라이언트가 잘라 쓴다 — 90일 x 4지표가 수십 KB 라 다시 굽는 것보다 싸다 |
| 서빙 | `python3 -m http.server`, systemd. **`0.0.0.0` 금지** — 인증이 없다 |
| 상태 | 토글은 `localStorage`. 접근 자체가 던지는 환경이 있어 try/catch 로 감싼다 |
| 회귀 | `dashboard/check.sh` — 차트가 읽는 컬럼과 JSON 컬럼을 대조한다 |

**`check.sh` 가 있는 이유**: SQL 컬럼명을 바꾸면 차트가 **에러 없이 빈 채로** 뜬다.
정적 대시보드에서 가장 발견이 늦는 고장이라 회귀로 박아뒀고 `run-local.sh` 가 매번 돈다.

**낡은 데이터 방어**: 상단에 마지막 적재 시각을 항상 띄우고, 36시간을 넘으면 빨갛게
경고한다. 데이터가 없는 지표는 빈 차트가 아니라 "데이터 없음" 문구를 띄운다 —
0 인 것과 아직 안 들어온 것은 다르다.
