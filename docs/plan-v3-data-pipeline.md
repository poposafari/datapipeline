# PopoSafari 데이터 파이프라인 v3 — **data-pipeline 레포 작업 명세**

> 짝 문서: `plan-v3-server.md` (prod / 게임 서버 레포)
> 상위 문서: `data-pipeline-plan-v2.md` — 설계 근거와 트레이드오프는 그쪽에 있다.
>
> ⚠️ 계획서다. 이 레포는 아직 존재하지 않는다.

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

**이 절은 `plan-v3-server.md` §1의 사본이다. 한쪽만 바꾸면 깨진다.**

### 1-1. R2 레이아웃

```
s3://poposafari-analytics/
  raw/dt=YYYY-MM-DD/audit_<from>_<to>.csv.gz     증분 (15분)
  backfill/dt=YYYY-MM-DD/resweep.csv.gz          야간 재스윕 (1일)
  master/v=<git-sha>/{item.csv,pokemon.csv,map-entry.json,map/*.json}
  master/LATEST                                  한 줄 텍스트, 현재 sha

s3://poposafari-backups/    ← 절대 읽지 않는다. pg_dump 원본에는 session.id(살아있는 인증 토큰)가 있다
```

### 1-2. CSV 스키마 — 8컬럼 고정, `ip` 없음

```
id BIGINT, account_id INTEGER, action VARCHAR, status SMALLINT,
detail VARCHAR(JSON 문자열), user_agent VARCHAR, source VARCHAR, created_at TIMESTAMPTZ
```

### 1-3. 상대편이 보장하는 것 / 이쪽이 보장하는 것

| server 레포가 보장 | 이 레포가 보장 |
| --- | --- |
| `ip` 컬럼 부재 | **중복을 흡수한다** (id 안티조인) |
| `REQUEST_REJECTED.detail.url`에 `?` 없음 | 재실행이 안전하다 |
| `LOGIN_FAILED.detail.body.username` 부재 | 마스킹 위반을 **검증하고 알린다** |
| 유실 없음 (겹쳐 보낼 수는 있음) | prod에 접근하지 않는다 |

**멱등성의 근거는 이쪽 안티조인이다.** 상대편 객체명은 결정적이지 않을 수 있다(재실행 시 상한이 갱신되어 상위집합이 하나 더 생긴다). v2 §3-1의 *"같은 이름으로 덮어쓴다"*는 부정확하며, 결과는 같지만 근거를 여기 적어둔다.

### 1-4. `detail` 스키마는 무보증

server 레포가 `detail`에 Zod 표준화를 하지 않기로 했다(v2 §Phase 2 각주). **방어적 파싱은 이 레포의 책임이다.** 모든 뷰에서 `try_cast` / `json_extract` 실패를 NULL로 흡수하고, 절대 예외로 죽지 않게 한다.

---

## 2. 레포 구조

```
poposafari-data-pipeline/
├── README.md                   부트스트랩 + 일상 운영
├── bootstrap/
│   ├── install.sh              DuckDB 설치, /srv/warehouse 준비, cron 등록
│   ├── secrets.sql.example     R2 자격증명 템플릿 (실물은 비커밋)
│   └── cron.d/poposafari       cron 정의
├── load/
│   ├── 00_schema.sql           테이블 DDL (멱등)
│   ├── 10_load_audit.sql       R2 → wh.audit 안티조인 적재
│   ├── 20_load_master.sql      master/LATEST → wh.master_*
│   └── run.sh                  위 3개 순서 실행 + 실패 시 Discord
├── views/
│   ├── 00_audit.sql            방어적 파싱 뷰
│   ├── 10_master_join.sql      pokedex_id 정규화 조인
│   └── 20_metrics.sql          체류시간·포획률·DAU 등 파생 뷰
├── recipes/
│   ├── onboarding_8.sql        온보딩 §8의 5개 쿼리 이식
│   └── abuse/*.sql             어뷰징 탐지 (수동 실행)
├── checks/
│   ├── reconcile.sh            일별 카운트 대사 → Discord
│   └── assertions.sql          마스킹·중복·PII 검증
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
# 04:00 KST = 19:00 UTC. prod 재스윕(03:10 UTC)이 끝난 뒤여야 한다.
0 19 * * *  poposafari  /opt/poposafari-data-pipeline/load/run.sh      >> /var/log/poposafari/load.log 2>&1
30 19 * * * poposafari  /opt/poposafari-data-pipeline/checks/reconcile.sh >> /var/log/poposafari/check.log 2>&1
```

> **순서가 중요하다.** prod 재스윕이 03:10 UTC에 `backfill/dt=<오늘>/resweep.csv.gz`를 쓴다. 적재를 그보다 앞서 돌리면 그날 갭 보충분을 하루 늦게 받는다. 19:00 UTC면 충분히 뒤다.

---

## 4. D2 — 적재

### D2-1. `load/00_schema.sql`

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

### D3-1. `views/00_audit.sql` — 방어적 파싱

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

server 레포 S2가 배포된 뒤에 의미가 생긴다. **S2 배포 전에 만들면 전부 빈 뷰다.**

| 뷰 | 필요한 선행 계측 | 정의 |
| --- | --- | --- |
| `safari_session` | `SAFARI_ENTER` + **`SAFARI_EXIT`(S2-1)** | account별 enter→exit 페어링, 체류시간 |
| `catch_rate` | **`POKEMON_CATCH_ATTEMPT`(S2-2)** | `result` 분포. 분모가 여기서 생긴다 |
| `dau` / `session_len` | **`SESSION_START`/`SESSION_END`(S2-3)** | `isOwner=true`만. 킥 경로 중복 제외 |
| `money_series` | 기존 `ITEM_BUY`/`ITEM_SELL` | `money_after` 시계열. **지금 바로 가능** |

**페어링 주의**: enter/exit, session start/end 모두 **짝이 안 맞는 경우가 정상적으로 발생한다**(크래시, 킥, 배포 중 종료). `LEAD() OVER (PARTITION BY account_id ORDER BY created_at)` 로 다음 이벤트를 붙이고, 짝 없는 건 NULL 체류시간으로 두되 **비율을 지표로 노출한다**. 그 비율이 튀면 그 자체가 서버 이상 신호다.

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
| 시간당 포획 시도 z-score | **S2-2 배포 후.** 지금은 분모가 없다 |
| `money` 급증 | **지금 가능.** `money_after` 시계열의 1차 차분 |
| 티켓 소모 없는 `SAFARI_ENTER` | 지금 가능 |
| **임의 좌표 이동** | **S4-1 수정 후.** `MAP_CHANGE.detail.rejected=true` 가 신호원 |
| ~~볼 소모 대비 성공률~~ | **작성 보류.** server 레포 S4-3 — 현재 볼이 성공 시에만 소모되므로 항상 1:1이라 신호가 없다 |
| ~~`item.buy` 잔액 레이스~~ | **제외.** `ck_user_money` CHECK 제약이 막는다. 어뷰징이 아니라 500 에러 문제 (server 레포 S4-2) |

> v2 §8이 "미검증"으로 남긴 두 항목은 server 레포에서 코드 확인이 끝났다. 하나는 실재(좌표), 하나는 오판(잔액)이다. **탐지 룰을 짜기 전에 수정이 먼저**라는 v2의 결론은 좌표 쪽에 대해 옳았다.

---

## 7. D5 — 검증과 대사

### D5-1. `checks/assertions.sql` — 매 적재 후 자동

전부 **0행이어야** 한다. 하나라도 걸리면 Discord.

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

> ③의 갭 임계(1000)는 임시값이다. 첫 2주 실측으로 조정한다. **커밋 순서 갭(v2 §3-2)은 재스윕이 다음날 메우므로, 3일 넘게 남아 있는 갭만이 진짜 유실이다.**

### D5-2. `checks/reconcile.sh` — 일별 카운트 대사

v2 §3-5. **이게 유일하게 prod에 닿는 정기 작업이다.**

```sql
-- prod (Tailscale ad-hoc psql). 14일치 일별 카운트
SELECT created_at::date d, count(*) FROM audit_log
WHERE created_at > now() - interval '14 days' GROUP BY 1 ORDER BY 1;

-- 미니 PC
SELECT created_at::date d, count(*) FROM wh.audit
WHERE created_at > now() - INTERVAL 14 DAY GROUP BY 1 ORDER BY 1;
```

- 불일치 행이 있으면 Discord webhook
- **당일과 전일은 제외**한다 — 5분 유예 + 재스윕 타이밍 때문에 정상적으로 어긋난다. D-2 이전만 비교
- ⚠️ prod `audit_log`는 60일 컷이 있다(`janitor.ts:19`). 웨어하우스가 더 많이 갖고 있는 건 **정상**이다. **웨어하우스 < prod 인 경우만** 알린다
- ⚠️ 단, server 레포 S5 — 현재 `dailyPrune`이 부팅 시 돌지 않아 실제로는 60일이 넘어도 안 지워지고 있다. 어느 날 갑자기 prod 쪽 카운트가 줄면 그건 prune이 처음 돈 것이다. **오탐으로 처리하지 말고 기록할 것**

> 대사가 prod에 붙는 빈도는 **하루 1회, 14행 집계**다. 버스터블 크레딧에 무해하다. 온보딩 §7-1이 경고한 건 *"무거운 집계의 반복 실행"*이다.

### D5-3. 수용 기준

| Phase | 기준 |
| --- | --- |
| D1–D2 | 첫 적재 후 `wh.audit` 행 수 > 0, assertions 전부 0행, `load_log` 기록됨 |
| D2 재실행 | 같은 잡을 2회 연속 실행 → **행 수 변화 0** |
| D2 복구 | `poposafari.duckdb` 삭제 → `scan_from`을 전량으로 → 원래 행 수 복원 |
| D3 | `pokemon_dim` 조인 고아 0행, CRLF 잔재 0행 |
| D5-2 | D-2 이전 14일 대사 불일치 0 |
| D4-1 | 온보딩 §8 5개 쿼리가 prod 직접 실행분과 **동일 결과** |

---

## 8. 보안·PII 경계

이 레포가 지켜야 할 것 (v2 §4에서 이 레포에 해당하는 부분 + 추가분):

| 항목 | 조치 |
| --- | --- |
| R2 토큰 | **읽기 전용 + `poposafari-analytics` 스코프**로 신규 발급 (D1-2). 백업 버킷 토큰 재사용 금지 |
| `poposafari-backups` | **읽지 않는다.** `pg_dump`에는 `session.id`(살아있는 인증 토큰)가 있다 |
| `/srv/warehouse` | 0700. LVM plain이라 디스크 암호화 없음 — 물리 도난 시 노출. 1인 가정 환경에서 수용 가능으로 판단하되 **명시해둔다** |
| `secrets.sql` | 0600, 레포 밖, `.gitignore`에 `*.duckdb`·`secrets.sql` |
| `account_id` | 가명 식별자. 로컬 분석이라 해싱 실익 없음. **외부 공유 시에만** `md5(account_id \|\| salt)` |
| `LOGIN_OAUTH.detail.providerId` | 1차 적재는 유지. 직접 식별자지만 계정 매핑 디버깅에 실사용 가치 → §9-1에서 판단 |
| 국외이전 | **해당 없음.** 자체 호스팅. v2 §4 그대로 |

---

## 9. 결정이 필요한 사항

1. **`LOGIN_OAUTH.detail.providerId` 해싱** — 직접 식별자. 1차 유지 후, D3 뷰가 안정된 뒤 판단. 해싱하면 계정 매핑 디버깅이 불가능해지므로 **원본을 별도 제한 뷰에 두고 일반 뷰는 해시**가 절충안.
2. **`audit_log` 원본 60일 보존 단축** — 웨어하우스가 생기면 30일로 줄여 prod PG 부담을 덜 수 있다. **파이프라인이 1개월 무사고로 돈 뒤에** 판단. 단 server 레포 S5(부팅 시 prune 미실행)를 먼저 정리해야 의미가 있다.
3. **운영 문서 이관 범위** — `plan-v3-server.md` §S0-2. `audit-log-readonly-access.md`·`data-engineering-onboarding.md`는 이쪽으로, `runbook-restore.md`는 server 레포에 남기는 안을 권장.

---

## 10. 승격 경로 (착수 금지 · 조건부)

v2 §Phase 5 그대로. **전부 트리거를 만족할 때까지 착수하지 않는다.**

| 항목 | 트리거 |
| --- | --- |
| **BI GUI** | DuckDB CLI로 답을 못 찾는 질문이 반복될 때. Celeron N3150엔 JVM 기반 Metabase보다 **정적 사이트 생성형(Evidence.dev)** |
| **어뷰징 탐지 자동화** | 실제 어뷰징 1건 확인. 그전까지 §6의 수동 쿼리 |
| **중앙 로그 수집** (Loki/Alloy) | "로그 찾느라 SSH 주 3회 이상". 그때도 **Alloy는 미니 PC 쪽에** 두고 Tailscale로 tail → prod 부하 0 |
| **Parquet 전환** | CSV.gz 스캔이 느려질 때. 상한 시나리오에서도 10–24MB/일이라 수년은 CSV로 충분 |
| **메트릭/APM** | 정식 출시 후. prod 4GB 마진 판단이 아직 유효 |
| **게임 월드 팩트 로깅** (날씨/게임시간/스폰) | 밸런스 분석을 실제로 시작할 때 — **server 레포 작업**이다 |
| **잔고 스냅샷 잡** | `money_after`로 복원이 안 되는 질문이 생길 때(거래 없는 유저) |

---

## 11. 순서와 의존

```
[server S1 배포 — R2에 객체가 쌓이기 시작] ────┐
                                              ▼
D1 부트스트랩 ──→ D2 적재 ──→ D5-1 assertions ──→ D5-2 대사
                    │
                    ├─→ D3-1 audit_v ──→ D4-1 온보딩 §8 이식 (지금 가능)
                    │                 └─→ money_series, 잔고 룰 (지금 가능)
                    │
                    └─→ D3-2 pokemon_dim  ← [server S1-3 push-master 필요]

[server S2 배포] ──→ D3-3 metrics (safari_session / catch_rate / dau)
                 └─→ D4-2 나머지 어뷰징 룰
[server S4-1 수정] ──→ D4-2 좌표 이동 탐지 룰
```

**server S1 없이는 이 레포가 할 일이 없다.** D1은 미리 해둘 수 있지만, D2 이후는 R2에 객체가 있어야 한다.

**반대로 D3-3·D4-2 대부분은 server S2를 기다린다.** 계측이 없으면 빈 뷰다. 그 사이에 할 수 있는 건 `money_series`와 온보딩 §8 이식 — **기존 `ITEM_BUY`/`ITEM_SELL`만으로 성립하는 것들**이다. 여기부터 하면 파이프라인이 첫날부터 답을 내놓는다.
