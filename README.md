# poposafari-data-pipeline

미니 PC `poposafari`(172.30.1.13)에서 도는 DuckDB 웨어하우스. **prod 박스에는 이 레포의 코드가 한 줄도 올라가지 않는다.**

| | |
| --- | --- |
| 입력 | R2 버킷 `poposafari-analytics` 하나뿐 |
| 정본 | **R2.** `poposafari.duckdb` 는 언제든 재구축 가능한 파생물 |
| prod 접근 | **없다.** 대사도 R2 의 `meta/counts.csv.gz` 로 한다. Tailscale 은 ad-hoc 디버깅 전용 |
| 도구 | DuckDB (정적 단일 바이너리). Celeron N3150 에 JVM 기반 BI 는 부담 |

설계 근거는 `docs/plan-v3-data-pipeline.md`, 그 상위는 `docs/data-pipeline-plan-v2.md`.

---

## 지금 상태 — server S1 이 없다

**server 레포의 S1(`export-audit.sh` / `push-master.sh`)이 아직 구현되지 않았다.**
R2 에 객체가 하나도 없으므로 실제 적재는 0행이다.

그래서 이 레포는 **픽스처 위에서 전부 검증되도록** 만들어져 있다. 계약(§1-2)대로
가짜 R2 레이아웃을 만들고 파이프라인 전체를 돌린다:

```bash
brew install duckdb          # 또는 bootstrap/install.sh (리눅스)
./fixtures/run-local.sh
```

S1 이 배포되는 날 바뀌는 것은 **`R2_BASE` 하나**다.

---

## 부트스트랩 (미니 PC, 1회)

```bash
sudo ./bootstrap/install.sh
# 1. /srv/warehouse/secrets.sql 에 R2 자격증명 입력
# 2. 첫 적재 — 빈 테이블이면 scan_from 이 자동으로 전량으로 넓어진다
./load/run.sh
```

`install.sh` 가 하는 일: DuckDB 버전 고정 설치, `/srv/warehouse` 0700,
`secrets.sql` 0600, `/etc/cron.d/poposafari`, logrotate.

> ⚠️ **R2 토큰은 `poposafari-analytics` 버킷 읽기 전용으로 새로 발급할 것.**
> `backup-pg.sh` 의 쓰기 토큰을 재사용하면 미니 PC 한 대가 prod 백업 전체의
> 삭제 권한을 갖게 된다. 그 버킷의 `pg_dump` 에는 살아있는 인증 토큰(`session.id`)이 있다.

## 일상 운영

| | |
| --- | --- |
| 적재 | 19:00 UTC (04:00 KST) — prod 재스윕(03:10 UTC) 뒤여야 한다 |
| 대사 | 19:30 UTC (04:30 KST) |
| 로그 | `/var/log/poposafari/{load,check}.log` |
| 알림 | `DISCORD_WEBHOOK_ALERTS` (server 레포 `.env.backup` 과 같은 채널) |

```bash
duckdb /srv/warehouse/poposafari.duckdb
D .read /opt/poposafari-data-pipeline/recipes/onboarding_8.sql
```

### 복구

```bash
# 적재 중 크래시로 파일이 깨졌을 때 — 즉시 롤백 (하드링크 스냅샷)
cp /srv/warehouse/poposafari.duckdb.prev /srv/warehouse/poposafari.duckdb

# 전량 재구축 — R2 가 정본이므로 파일을 지우면 된다.
# 빈 테이블이면 scan_from 이 자동으로 2026-01-01 부터로 넓어진다.
rm /srv/warehouse/poposafari.duckdb && ./load/run.sh
```

---

## 구조

```
bootstrap/   install.sh, secrets.sql.example, cron.d/
load/        00_schema → 10_load_audit → 20_load_master, run.sh
views/       00_audit(방어적 파싱) → 10_master_join(정규화) → 20_metrics
recipes/     onboarding_8.sql, abuse/*.sql   ← 수동 실행
checks/      assertions.sql(적재 후 자동), reconcile.sh(일 1회)
fixtures/    gen.py, run-local.sh            ← S1 없이 검증
docs/        설계 문서
```

계층은 3개가 아니라 **2개**다 — raw 테이블 + 뷰. `raw→stg→mart` 는 BigQuery
과금 구조(뷰 무료, 스캔 유료)에 맞춘 형태이고 DuckDB 에는 스캔 과금이 없다.
mart 를 물리화할 이유가 생기면 그때 `CREATE TABLE AS`.

---

## 이 파이프라인이 견디는 함정

`fixtures/gen.py` 가 전부 의도적으로 심고, `run-local.sh` 가 회귀로 잡는다.

| 함정 | 조치 | 근거 |
| --- | --- | --- |
| **`pokedex_id` 형식 2종** | 정규형 = **패딩 문자열**. 정수 캐스팅 금지 | `user_pokemon.pokedex_id` 는 `varchar(20)`, `map/*.json` 스폰 id 는 전부 패딩. 정수로 정규화하면 변종 폼(`0058_hisui`)이 전부 NULL 이 되어 조인이 조용히 사라진다 |
| **`created_at` 타임존** | `TIMESTAMP` 로 읽고 UTC 로 취급. KST 는 `+ INTERVAL 9 HOUR` | 익스포터가 `AT TIME ZONE 'UTC'` 로 뽑아 tz 가 없다. `TIMESTAMPTZ` 로 읽으면 세션 TZ(KST)로 재해석되어 **9시간 밀린다** |
| **`{raw,backfill}` 글롭** | 리스트 형태로 나열 | DuckDB 1.5 는 중괄호 확장을 지원하지 않는다 — **0개 파일에 매칭되고 조용히 빈 결과**가 된다 |
| **중복 우선순위** | 경로(`filename LIKE '%/backfill/%'`)로 판정 | `dt` 로는 안 된다. raw 의 dt 는 *추출일*, backfill 의 dt 는 *이벤트일*이라 익스포트가 자정을 넘기면 raw 쪽 dt 가 오히려 크다 |
| **타입 추론 갈림** | `columns` 명시 | 어떤 날 `status` 가 전부 비면 그 파일만 VARCHAR 로 추론되어 타입 충돌. 가장 흔한 조용한 실패 |
| **`detail` 무보증** | `TRY_CAST(… AS JSON)` + `json_extract_string` | 깨진 JSON 이 와도 행 전체가 죽으면 안 된다 (계약 §1-4) |
| **CRLF 마스터** | `rtrim(col, chr(13))` | `pokemon.csv`/`item.csv` 는 CRLF, EOF 개행 없음 |
| **`load_log` 카운트** | 적재 전/후 차분 | 총 행수를 넣으면 "이번에 몇 행 들어왔나"를 영영 알 수 없다 |

### 계획서와 달랐던 것 (실물 확인)

- `POKEMON_CATCH.detail` 에 **`result` 가 없다.** `auditTx` 가 `result='caught'`
  분기 안에만 있어서 성공만 기록된다 → **포획률은 현재 데이터로 구할 수 없다.**
  server S2-2(`POKEMON_CATCH_ATTEMPT`) 대기.
- `MAP_CHANGE.detail` 은 `{from,to,x,y}` 다 — `mapId` 키가 없다.
- `SAFARI_ENTER.detail.ticketConsumed` 는 하드코딩 리터럴 `true` 라 신호가 0이다.
  `recipes/abuse/ticketless_enter.sql` 은 대신 수지를 맞춘다.
- 온보딩 §8 은 5개가 아니라 **6개** 쿼리다.

---

## server 레포와의 계약

`docs/plan-v3-data-pipeline.md` §1 은 `plan-v3-server.md` §1 의 사본이다.
**한쪽만 바꾸면 깨진다.**

### 미반영 변경 1건 — `meta/` 프리픽스

대사를 prod 접근 없이 하기 위해 R2 레이아웃에 아래가 추가되어야 한다:

```
meta/counts.csv.gz    일별 카운트 14일, 재스윕 때 갱신 (컬럼: d DATE, n BIGINT)
```

초안 `export-audit.sh` 에 이미 구현되어 있으므로 server 쪽은 **명세만** 맞추면 된다.
양쪽 §1 을 모두 고칠 것.

### S1 배포 전에는 어서션 ②가 반드시 걸린다

계약 §1-3 의 마스킹 3종(`ip` 부재 / url 쿼리스트링 절단 / `body.username` 제거)은
**전부 "아직 없는 익스포터"의 성질**이다. 현재 prod DB 에는 `ip` 값이 있고,
`request.url` 은 쿼리스트링을 포함하며, `username` 은 `REDACT_KEYS` 에 없어 평문이다.

어서션의 목적은 "지금 깨끗한가"가 아니라 **계약이 깨졌는가를 탐지**하는 것이다.

### 60일 prune 이 휴면 상태다

`janitor.ts` 의 `setInterval` 에 즉시 `tick()` 이 없어 60일 컷이 실질적으로 돌지 않는다.
60일 초과 데이터가 아직 prod 에 남아 있고, **업타임이 24h 를 넘는 첫 순간 한 번에 삭제된다.**
→ S1 배포(첫 백필)를 서두를 근거이자, 대사에서 prod 카운트가 갑자기 줄면
오탐으로 처리하지 말아야 할 이유.

---

## 보안 · PII 경계

| 항목 | 조치 |
| --- | --- |
| R2 토큰 | 읽기 전용 + `poposafari-analytics` 스코프. 백업 버킷 토큰 재사용 금지 |
| `poposafari-backups` | **읽지 않는다.** `pg_dump` 에 `session.id`(살아있는 인증 토큰)가 있다 |
| `/srv/warehouse` | 0700. LVM plain 이라 디스크 암호화 없음 — **물리 도난 시 노출된다.** 1인 가정 환경에서 수용 가능으로 판단하되 명시해 둔다 |
| `secrets.sql` | 0600, 레포 밖, `.gitignore` |
| `account_id` | 가명 식별자. 로컬 분석이라 해싱 실익 없음. 외부 공유 시에만 `md5(account_id ‖ salt)` |
| `LOGIN_OAUTH.detail.providerId` | 직접 식별자. 1차 적재는 유지 — 계정 매핑 디버깅에 실사용 가치. 뷰가 안정된 뒤 판단 |
| 국외이전 | 해당 없음. 자체 호스팅 |

---

## 승격 경로 (착수 금지 · 조건부)

| 항목 | 트리거 |
| --- | --- |
| BI GUI | CLI 로 답을 못 찾는 질문이 반복될 때. Celeron 에는 Metabase 보다 **Evidence.dev**(정적 생성형) |
| 어뷰징 탐지 자동화 | 실제 어뷰징 1건 확인 |
| 중앙 로그 수집 | "로그 찾느라 SSH 주 3회 이상". 그때도 Alloy 는 **미니 PC 쪽에** |
| Parquet 전환 | CSV.gz 스캔이 느려질 때. 상한 시나리오에서도 10–24MB/일이라 수년은 CSV 로 충분 |
| 잔고 스냅샷 잡 | `money_after` 로 복원이 안 되는 질문이 생길 때(거래 없는 유저) |
