# poposafari-data-pipeline

미니 PC `poposafari`(172.30.1.13)에서 도는 DuckDB 웨어하우스. **prod 박스에는 이 레포의 코드가 한 줄도 올라가지 않는다.**

| | |
| --- | --- |
| 입력 | R2 버킷 `poposafari-db-backups` 의 `audit/` 프리픽스 하나뿐 |
| 정본 | **R2 아카이브.** prod 는 업로드 직후 `audit_log` 를 비운다 (§정본이 뒤집혔다) |
| prod 접근 | **없다.** 대사도 R2 객체끼리 한다. Tailscale 은 ad-hoc 디버깅 전용 |
| 도구 | DuckDB (정적 단일 바이너리). Celeron N3150 에 JVM 기반 BI 는 부담 |
| 대시보드 | 정적 JSON + Chart.js. 상시 프로세스는 파일 서버 하나뿐 |

설계 근거는 `docs/plan-v3-data-pipeline.md`, 그 상위는 `docs/data-pipeline-plan-v2.md`.

---

## 계약 — server 레포가 실제로 올리는 것

`poposafari-db-backups` 가 **유일하게 운영 중인 버킷**이고, 두 스크립트가 프리픽스로
나눠 쓴다. lifecycle 규칙도 프리픽스별로 다르다.

```
s3://poposafari-db-backups/
├── pg/       backup-pg.sh, 6시간마다 (UTC 00/06/12/18). lifecycle 7일
│             ※ audit_log·session 은 --exclude-table-data (정의만, 데이터 없음)
└── audit/    archive-audit.sh. 올린 뒤 DB 에서 DELETE → **여기가 유일 원본**
    └── YYYY/MM/DD/audit-<UTC stamp>-<cutoff>.jsonl.gz
              날짜는 로그가 찍힌 날이 아니라 **스크립트가 돈 UTC 시각**이다
              lifecycle 365일
```

계획서가 말한 별도 `poposafari-analytics` 버킷은 **만들어지지 않았다.**
§보안 경계의 미해결 판단이 거기에 걸려 있다.

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
두 번째 사본이다.**

### ⚠️ 365일이 지나면 이 관계가 뒤집힌다

`audit/` 프리픽스의 lifecycle 은 **365일**이다. 그 뒤로는 아카이브가 삭제되므로
**웨어하우스가 그 데이터의 유일한 사본이 된다.** 그런데 `/srv/warehouse` 는 단일
소비자 디스크에 이중화가 없다(§보안 경계).

당장은 문제가 아니다 — 아카이브가 쌓이기 시작한 지 얼마 안 됐다. 다만 **1년이 되기
전에** 셋 중 하나를 정해야 한다:

1. `audit/` lifecycle 을 늘린다 (가장 싸다. R2 저장비는 하루 10–24MB 수준)
2. `poposafari.duckdb` 를 정기 백업한다
3. 365일 넘은 구간을 Parquet 으로 떠서 별도 보관한다

**그때까지는 아래 복구 절차 중 "전량 재구축"이 안전하다.** 그 뒤로는 아니다.

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
# 1. /srv/warehouse/secrets.sql 에 R2 자격증명 입력
#    (읽기 전용 + poposafari-db-backups 버킷 스코프)
# 2. 첫 적재 — 빈 테이블이면 scan_from 이 자동으로 전량으로 넓어진다
./load/run.sh && ./dashboard/build.sh
```

`install.sh` 가 하는 일: DuckDB 버전 고정 설치, `/srv/warehouse` 0700,
`secrets.sql` 0600, `/etc/cron.d/poposafari`, logrotate, 대시보드 systemd 유닛.


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

적재는 체크포인트 후 DB를 **독립 사본** `.prev`로 복사한다. 하드링크가 아니므로
적재 후에도 이전 DB 내용이 보존된다. DB 한 개 크기만큼 추가 공간이 필요하다.
복원 전에는 cron과 수동 작업을 멈추고, 실패한 DB와 `.wal`이 있다면 별도로 보관해
복원한 DB에 이전 WAL이 적용되지 않게 한다. 복원 뒤에는 대시보드도 다시 빌드한다.

```bash
# 작업을 멈춘 뒤 독립 사본에서 복원
cp /srv/warehouse/poposafari.duckdb.prev /srv/warehouse/poposafari.duckdb
./dashboard/build.sh

# 전량 재구축 — 빈 테이블이면 scan_from 이 자동으로 2026-01-01 부터로 넓어진다.
rm /srv/warehouse/poposafari.duckdb && ./load/run.sh
```

### 증분 처리와 잠금

- `wh.loaded_objects`에 성공적으로 읽은 객체 경로를 기록한다. 로그 적재·객체 이력·
  적재 로그는 한 트랜잭션으로 커밋하므로 실패한 객체는 다음 실행에서 다시 읽는다.
- 완료된 R2 객체는 불변으로 취급한다. 일반 실행은 최근 7일의 미처리 객체만 읽고,
  장기간 중단되면 마지막 성공 적재일 7일 전까지 스캔 범위를 넓힌다.
- 기존 DB에도 새 테이블이 자동 생성된다. 최초 전환에서 스캔 창의 객체를 다시 읽어
  처리 이력을 채우며 기존 ID가 중복 삽입되지는 않는다.
- `FORCE_RELOAD=1 ./load/run.sh`는 **현재 스캔 창 안**의 객체를 다시 읽는다.
  기존 ID의 필드도 갱신하고 빠진 행을 복구하지만, 소스에서 사라진 ID를 삭제하지는 않는다.
- `load/run.sh`는 `${DB}.lock`에 배타 잠금, `dashboard/build.sh`와 `checks/reconcile.sh`는
  공유 잠금을 건다. 충돌하면 기다리며 중첩 실행하지 않고 종료 코드 **75**를 반환한다.
  수동 SQL 쓰기와 복원도 작업 중단 후 수행한다. 잠금 파일은 실행 중 삭제하지 않는다.
- 서버 아카이브 자체의 유실은 이 변경으로 복구할 수 없다. 대사는 강제 재처리와 무관하게
  R2 원본을 다시 확인하므로 로컬 누락을 탐지할 수 있다.

> ⚠️ **전량 재구축은 R2 에 남아 있는 것만 되살린다.** `audit/` lifecycle 이 365일이므로,
> 아카이브 시작일로부터 1년이 지난 뒤에는 이 명령이 **1년 넘은 데이터를 영구 삭제**한다.
> 위 §365일 절의 조치를 하기 전에는 `.duckdb` 를 지우기 전에 반드시 사본을 떠 둘 것.

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

운영에 Node나 프런트엔드 빌드 도구는 필요 없다. Python 표준 라이브러리와 DuckDB CLI로
단일 연결·동일 읽기 스냅샷에서 JSON을 만들고 단일 HTML이 그린다.
데이터가 하루 1회 갱신되므로 요청마다 쿼리할 이유가 없고, 그 덕에 상시 프로세스가
`python3 -m http.server` 하나로 끝난다.

토글(기간 7/30/90, 차트 표시, 카드별 모드·시리즈)은 전부 클라이언트에서 처리하고
`localStorage` 에 남는다. 90일치를 한 번에 받아 브라우저가 잘라 쓴다.

- 상단에 **마지막 적재 시각**을 항상 띄운다. 36시간이 넘으면 빨갛게 경고한다 —
  정적 대시보드의 가장 흔한 사고가 낡은 숫자를 최신으로 착각하는 것이다.
- 데이터가 없는 지표는 빈 차트가 아니라 **"데이터 없음" 문구**가 뜬다.
- `data/snapshot.json`은 `schema_version: 1`, UTC `built_at`, 한 행 배열 `meta`,
  `bait_rock`, `dau`, `catch_rate`, `safari_session` 배열을 담는다. 기존 지표 필드명은 동일하다.
  모든 쿼리·검증 성공 후 같은 파일시스템에서 원자적으로 교체한다. 실패하면 이전 게시본을 유지한다.
  개별 JSON과 `built_at.txt`도 호환용으로 생성하지만 새 화면은 단일 스냅샷만 사용한다.
- 화면이 보일 때 **60초마다 새 빌드를 확인**하고, 숨겨진 탭은 중단했다가 복귀 시 확인한다.
  원본 적재는 여전히 하루 한 번이다. 이 기능은 실시간 로그 수집이 아니다.
- 요청 실패 시 마지막 정상 숫자를 유지한다. 0은 0으로 표시하고, 계산 불가인 NULL과
  데이터 없음·시리즈 전체 숨김을 구분한다. 차트 인스턴스는 재사용한다.
- 요약은 데이터가 제공된 날짜의 평균 DAU, 신규 가입 합계, 포획 시도 합계,
  역산 성공 합계 ÷ 시도 합계다. 최근 기간의 끝은 네 지표 중 가장 최근 날짜로 통일한다.
- 모바일·시스템 다크 모드·키보드 조작을 지원하고 각 차트의 일별 데이터 표를 제공한다.
- 차트에 마우스를 올리면 관련 유저 수와 최대 10개의 `account_id`를 표시한다. 클릭·탭하거나
  일별 데이터 표의 **유저 보기**를 누르면 ID와 관련 건수 전체 목록을 연다.
  관련 건수 내림차순·ID 오름차순이며 ID 검색과 50명 단위 페이지 이동을 지원한다.
- 비율은 분모에 참여한 계정, 중앙값·p90은 완료 세션의 계정을 표시한다. DAU의 관련 건수는
  로그 수, 가입은 가입 기록 수, 도구 사용은 사용 수, 포획은 시도 수, 체류시간은 세션 수다.
  포획 성공은 기존 역산 기준을 유지한다. 계정 ID가 없는 기록은 식별 불가 건수로 별도 표시한다.
- `snapshot.json`의 선택적 `drilldown`은 빌드 ID와 날짜·지표별 미리보기·전체 인원수·경로를 담는다.
  전체 목록은 `data/details/<build_id>/<metric>/<YYYY-MM-DD>.json`에 저장하며 패널을 열 때만 읽는다.
  상세 JSON은 `build_id`, `metric`, `date`, `groups`를 담고 각 그룹에
  `users: [{account_id: "문자열 ID", count: 관련건수}]`, `unidentified_records`가 있다.
- 상세 파일을 먼저 게시한 뒤 스냅샷을 교체한다. 상세 패널은 열었던 빌드를 유지하며,
  이전 파일은 최소 7일 및 최근 두 빌드를 보관한다. 현재 게시된 빌드는 항상 유지한다.
  만료 시 패널을 닫고 새로고침 후 다시 연다. 구형 스냅샷은 숫자 툴팁만 지원한다.
- **화면과 JSON 모두 계정 ID를 포함한다.** 기존 LAN/Tailscale 운영자 전용 접근을 유지하고,
  IP·인증정보·요청 본문은 상세 파일에 내보내지 않는다.

유저 상세 추가 후 같은 소규모 로컬 픽스처의 빌드 시간 중앙값은 0.158초, 최대 RSS는
107.2MiB였다. 지표 값은 기존과 같으며, 42일·4지표 기준 스냅샷 197,646바이트,
상세 파일 168개 합계 62,998바이트(파일당 최대 2,228바이트)다. 계정 수가 늘면
상세 파일과 빌드 메모리도 늘어나므로 실제 운영 데이터에서 다시 측정한다.
- `check.sh` 가 없으면 SQL 컬럼명을 바꿨을 때 **에러 없이 빈 차트**가 된다.
  `fixtures/run-local.sh` 가 이걸 매번 돌린다.

---

## 검증

```bash
POPOSAFARI_SERVER=/path/to/server ./fixtures/run-local.sh
```

기존 검사에 객체 증분·강제 재처리·실패 후 재시도·장기 중단·잠금·독립 백업·게시 실패
회귀 검사가 이어서 실행된다. 테스트 산출물은 임시 디렉터리에 생성한다.

개발 환경에서 Playwright와 Chrome을 사용할 수 있다면 브라우저 회귀도 실행할 수 있다.
운영 머신에 이를 설치할 필요는 없다.

```bash
POPO_TEST_WORK=$(mktemp -d)
WORK="$POPO_TEST_WORK" ./fixtures/run-local.sh
DATA_DIR="$POPO_TEST_WORK/dash" node dashboard/browser-test.cjs
python3 fixtures/benchmark.py
```

각 검증에는 비어 있는 `WORK` 디렉터리를 사용한다. Playwright가 별도 위치에 설치되어 있으면
`PLAYWRIGHT_MODULE`에 해당 모듈 경로를 지정한다. 스크린샷은 기본 `/tmp/popo-browser`에 저장한다.
벤치마크는 Python 3.12 이상에서 `BASELINE_REF`(기본 `HEAD`)의 코드와 현재 코드를 같은 로컬
픽스처로 비교하고, 반복 적재·빌드 각 3회의 시간 중앙값과 프로세스 최대 RSS를 출력한다.
네 지표 JSON의 값도 비교한다. 로컬 결과는 R2 전송량이나 미니 PC 성능을 대신하지 않는다.

2026-09-08 개발 머신의 소규모 로컬 픽스처 측정 예시(각 3회, 시간 중앙값):

| 항목 | 변경 전 | 변경 후 |
| --- | ---: | ---: |
| 반복 적재의 실제 읽은 객체 | 14 | 0 |
| 반복 적재 시간 | 0.174초 | 0.232초 |
| 반복 적재 최대 RSS | 50.6MiB | 41.3MiB |
| 대시보드 빌드 시간 | 0.163초 | 0.133초 |
| 대시보드 빌드 최대 RSS | 67.9MiB | 78.3MiB |

독립 백업·잠금과 게시 검증 비용 때문에 모든 항목이 개선되지는 않는다. 반복 적재의
핵심 이득은 완료된 아카이브의 다운로드·압축 해제를 생략하는 것이다. 최초 적재와
대용량 DB 백업 비용, R2 지연은 운영 미니 PC에서 추가 측정해야 한다.

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
| R2 토큰 | 읽기 전용 + `poposafari-db-backups` 스코프. `backup-pg.sh` 의 쓰기 토큰 재사용 금지 |
| `pg/` 프리픽스 | **읽지 않는다.** 다만 R2 토큰은 **버킷 단위로만** 스코프를 걸 수 있고 프리픽스 단위로는 못 건다 — 즉 미니 PC 의 읽기 전용 토큰은 기술적으로 `pg/` 도 읽을 수 있다. `pg_dump` 에서 `session`·`audit_log` **데이터**는 빠져 있어(server `8e0d189`) 살아있는 인증 토큰은 없지만, **계정 비밀번호 해시는 남아 있다.** 아래 §미해결 판단 참고 |
| `ip` | 소스에는 있다. **적재에서 버린다.** 웨어하우스에 영구 보존되지 않게 |
| `url` 쿼리스트링 | 뷰에서 자른다. OAuth code 가 그대로 실려 온다 |
| `body.username` | 뷰가 컬럼으로 꺼내지 않는다. 원본 `detail` 을 직접 봐야 보인다 |
| `/srv/warehouse` | 0700. LVM plain 이라 디스크 암호화 없음 — **물리 도난 시 노출된다.** 1인 가정 환경에서 수용 가능으로 판단하되 명시해 둔다 |
| `secrets.sql` | 0600, 레포 밖, `.gitignore` |
| 대시보드 | 인증 없음. 집계값과 **`account_id`·관련 건수**를 제공하는 운영자 전용 화면이다. `0.0.0.0`이 아니라 LAN/Tailscale 주소에만 바인드하며, 신뢰할 수 있는 운영자만 접근한다 |
| `account_id` | 가명 식별자. 로컬 분석이라 해싱 실익 없음. 외부 공유 시에만 `md5(account_id ‖ salt)` |
| `LOGIN_OAUTH.detail.providerId` | 직접 식별자. 1차 적재는 유지 — 계정 매핑 디버깅에 실사용 가치. 뷰가 안정된 뒤 판단 |
| 국외이전 | 해당 없음. 자체 호스팅 |

> `pg_dump` 에서 `session`·`audit_log` 데이터가 빠졌으므로(server `8e0d189`),
> "백업 버킷에 살아있는 `session.id` 가 있다"는 예전 근거는 더 이상 유효하지 않다.
> 그래도 백업 버킷을 읽지 않는 원칙은 유지한다 — 계정 비밀번호 해시가 남아 있고,
> 분석에 필요하지도 않다.

### 미해결 판단 — `pg/` 와 같은 버킷을 읽는 문제

R2 API 토큰은 **버킷 단위로만** 스코프가 걸린다. 프리픽스별 제한이 없다.
`audit/` 와 `pg/` 가 한 버킷에 있는 이상, 미니 PC 의 읽기 전용 토큰은
pg_dump 도 읽을 수 있다. 파이프라인은 읽지 않지만 **읽을 수 있다는 사실 자체**가
남는다. 미니 PC 는 LVM plain(디스크 암호화 없음)이고 물리 도난 시 토큰도 함께 나간다.

노출 범위는 **계정 비밀번호 해시**다. 세션 토큰은 `8e0d189` 이후 덤프에 없다.

선택지 셋:

| | 내용 | 대가 |
| --- | --- | --- |
| **A. 수용** | 지금 그대로. 1인 가정 환경 + 해시만 노출 | 아무것도 안 함 |
| **B. 버킷 분리** | `archive-audit.sh` cron 에 `BACKUP_ENV=…/.env.audit` (`R2_BUCKET=poposafari-analytics`). server 코드 변경 0 | **이미 쌓인 아카이브는 옛 버킷에 남는다** → 이전 기간은 여전히 옛 버킷 토큰이 필요하거나, 객체를 옮겨야 함 |
| **C. 비밀번호 해시도 덤프에서 제외** | `backup-pg.sh` 에 `--exclude-table-data=account` 추가 | 복구 시 계정 테이블을 따로 챙겨야 함 — 권하지 않는다 |

B 를 택한다면 **아카이브가 적게 쌓인 지금이 가장 싸다.** 시간이 갈수록 옮길 객체가 늘어난다.

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
