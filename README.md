# PopoSafari Data Pipeline

PopoSafari 게임 서버의 감사 로그를 Cloudflare R2에서 읽어 DuckDB에 적재하고, 운영 지표와 유저별 상세를 정적 대시보드로 제공한다. 미니 PC 한 대에서 일일 배치로 실행하며, 게임 서버나 운영 PostgreSQL에 직접 접속하지 않는다.

```text
게임 서버 → R2 감사 아카이브 → DuckDB 테이블·뷰 → JSON → Chart.js 대시보드
                              load/run.sh       dashboard/build.sh
                    └──── checks/reconcile.sh ────┘
                          아카이브와 적재 결과 대사
```

운영에는 Bash, Python 표준 라이브러리, DuckDB CLI를 사용한다. 상시 프로세스는 정적 파일을 제공하는 Python HTTP 서버 하나다. Node.js는 선택적인 개발 검증에만 사용한다.

## 빠른 시작: 로컬 검증

저장소 루트에서 실행한다. Linux 또는 macOS에 `duckdb`와 `python3`가 필요하며, DuckDB 버전은 설치 스크립트가 고정한 **v1.5.5**를 기준으로 맞춘다. 최초 실행에는 DuckDB의 `httpfs`·`json` 확장 설치를 위한 네트워크 접근이 필요할 수 있다.

```bash
# R2 자격증명 없이 픽스처 생성 → 적재 → 대사 → 대시보드 검증
POPO_TEST_WORK=$(mktemp -d)
WORK="$POPO_TEST_WORK" ./fixtures/run-local.sh
```

테스트용 DB와 대시보드 JSON은 `$POPO_TEST_WORK`에, 합성 아카이브는 `fixtures/out/`과 `fixtures/out-dirty/`에 생성된다. 실행할 때마다 비어 있는 `WORK` 디렉터리를 사용한다.

게임 서버 저장소가 있으면 `POPOSAFARI_SERVER=/path/to/server`를 함께 지정해 실제 마스터 CSV로 검증할 수 있다. 없으면 합성 마스터를 사용한다.

로컬 대시보드를 보려면 검증에서 만든 DB로 데이터를 빌드한 뒤 서버를 실행한다.

```bash
DB="$POPO_TEST_WORK/w.duckdb" ./dashboard/build.sh
./dashboard/check.sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory dashboard/public
```

브라우저에서 `http://127.0.0.1:8080`에 접속한다. 이 빌드는 `dashboard/public/data/`를 갱신하므로 운영 배포용 체크아웃에서는 로컬 미리보기를 실행하지 않는다.

## 데이터와 적재 방식

기본 입력은 `r2://poposafari-db-backups` 아래의 감사 아카이브다.

```text
poposafari-db-backups/
├── audit/YYYY/MM/DD/audit-<UTC stamp>-<cutoff>.jsonl.gz
└── pg/                          # PostgreSQL 백업: 파이프라인에서 읽지 않음
```

- 입력은 **gzip JSONL**이다. 소스 필드는 `id`, `account_id`, `action`, `status`, `detail`, `ip`, `user_agent`, `source`, `created_at`이며, `detail`은 중첩 JSON이다.
- 경로의 날짜는 이벤트 발생일이 아닌 **UTC 아카이브 생성일**이다. 파일명 끝의 `cutoff`는 배치가 가져간 최대 ID다.
- `ip`는 적재에서 제외한다. `created_at`은 UTC 기준 `TIMESTAMP`로 저장하고, 뷰에서 KST 시각을 제공한다. 일별 지표는 KST 기준이다.
- 분석 데이터는 `audit` 테이블과 SQL 뷰로 구성한다. `audit_v`가 JSON 추출과 타입 변환을 담당하고, 그 위에 마스터 조인과 지표 뷰를 둔다.
- 마스터는 `master/LATEST`를 통해 별도 적재를 시도한다. 실패하면 스텁 또는 기존 마스터를 유지하며 감사 로그 적재는 계속한다. 현재 저장소의 운영 기록상 마스터 업로드 잡은 없다.

`load/run.sh`는 먼저 객체 목록을 만들고, 읽을 객체가 있을 때만 로그 적재를 실행한다. 빈 아카이브는 정상 경로다.

| 상황 | 동작 |
| --- | --- |
| 최초 적재 또는 빈 `audit` | 2026-01-01 이후 아카이브를 스캔 |
| 일반 실행 | 최근 7일 범위에서 아직 처리하지 않은 객체를 읽음 |
| 장기간 중단 후 실행 | 마지막 성공 적재일의 7일 전까지 스캔 범위를 확장 |
| 같은 객체 재실행 | `loaded_objects`의 경로 이력으로 읽기를 생략 |
| `FORCE_RELOAD=1` | 현재 스캔 범위의 처리 완료 객체도 다시 읽고 기존 ID의 필드를 갱신 |

로그 행·객체 처리 이력·적재 로그는 한 트랜잭션으로 커밋한다. 실패한 객체는 다음 실행에서 다시 시도한다. 완료된 객체는 불변으로 가정하며, 강제 재처리도 소스에서 사라진 ID를 DB에서 삭제하지는 않는다.

## 지표와 대시보드

| SQL 뷰 | 내용 | 대시보드 |
| --- | --- | --- |
| `dau_daily` | 로그를 남긴 활성 계정 수, 신규 가입 | DAU·가입 |
| `bait_rock_daily` | 미끼·돌 사용량, 포획 시도 대비 점유율, 잔류율 | 미끼·돌 |
| `catch_attempt`, `catch_rate_daily` | 포획 시도, 역산 성공, 도주·탈출, 도구별 세그먼트 | 포획률 |
| `safari_session`, `safari_session_daily` | 입장·퇴장으로 계산한 체류시간, 미완결 비율 | 사파리 세션 |
| `money_series`, `economy_daily` | 관측 잔고와 재화 유입·유출 | SQL 조회 |

지표를 해석할 때 다음 제한을 고려한다.

- **포획 성공은 역산값이다.** 성공 이벤트에는 `wildUid`가 없어 시도와 직접 연결할 수 없다. 같은 계정·야생 개체의 시도와 실패를 순서대로 짝지어 실패가 없는 시도를 성공으로 본다. `caught_gap`으로 실제 성공 이벤트 수와의 차이를 확인한다.
- 튜토리얼 `s000`의 강제 성공은 포획 분석에서 제외한다. 미끼·돌 이벤트에는 `mapId`가 없어 해당 잔류율에서는 튜토리얼을 완전히 분리할 수 없다.
- 브라우저 종료 등으로 퇴장 이벤트가 없을 수 있다. 체류시간과 함께 `unclosed_rate`를 확인한다.
- 티켓 획득량은 이벤트 건수가 아니라 `detail.claimed`의 합이다. `pokedex_id`는 `0058_hisui` 같은 변종을 보존하는 문자열이며 정수로 변환하지 않는다.

대시보드는 지표별 최신 데이터 기준 최대 90일을 빌드하고, 브라우저에서 7·30·90일을 선택한다. 차트 모드와 시리즈 표시 설정은 `localStorage`에 저장된다. 모바일, 다크 모드, 키보드 조작과 일별 데이터 표를 지원한다.

차트의 툴팁에는 관련 유저 수와 최대 10개 계정 ID가 표시된다. 차트나 표의 **유저 보기**를 누르면 전체 계정 목록을 검색하고 50명씩 조회할 수 있다. 비율은 분모에 참여한 계정, 체류시간 중앙값·p90은 완료 세션 계정을 보여준다. 계정 ID가 없는 기록은 식별 불가 건수로 구분한다.

빌드는 하나의 읽기 스냅샷에서 쿼리와 검증을 마친 뒤 `data/snapshot.json`을 원자적으로 교체한다. 상세 파일은 `data/details/<build_id>/`에 먼저 게시하며, 이전 상세는 최소 7일 및 최근 두 빌드를 보관한다. 개별 지표 JSON도 호환용으로 생성한다.

화면이 보이는 동안 60초마다 새 빌드를 확인한다. 수집 주기는 여전히 하루 한 번이며, 마지막 적재가 36시간을 넘으면 경고한다. 요청 실패 시 마지막 정상 데이터를 유지하고, 0·계산 불가·데이터 없음을 구분한다.

## 운영 설치

`bootstrap/install.sh`는 **Debian/Ubuntu 계열 Linux amd64**, SSE4.2 지원 CPU, `apt-get`, systemd와 cron을 전제로 한다. Python 3와 cron·logrotate를 준비하고, 서비스가 읽을 수 있는 경로(예: `/opt/poposafari-data-pipeline`)에 저장소를 둔다. systemd 유닛은 `ProtectHome=yes`이므로 홈 디렉터리 배포는 피한다.

```bash
sudo ./bootstrap/install.sh
```

설치 스크립트는 DuckDB 설치, 웨어하우스·로그 디렉터리, 자격증명 템플릿, cron, logrotate, 대시보드 서비스를 구성한다. 최초 적재 전에는 초기 대시보드 빌드를 건너뛸 수 있다.

1. `/srv/warehouse/secrets.sql`에 R2 계정 ID와 **대상 버킷 읽기 전용** 자격증명을 입력한다. 서버 백업용 쓰기 토큰을 재사용하지 않는다.
2. 설치 시 지정된 실행 사용자로 아래 명령을 실행한다.

   ```bash
   ./load/run.sh && ./dashboard/build.sh
   ./checks/reconcile.sh
   ./dashboard/check.sh
   ```

3. `/etc/default/poposafari-dashboard`의 `BIND_ADDR`와 `PORT`를 확인하고 해당 주소로 접속한다. 자동 선택 순서는 Tailscale → LAN → 루프백이며, 기본 포트는 8080이다.

> 설치 스크립트와 자격증명 템플릿 일부 주석에는 과거 계획의 `poposafari-analytics`·`poposafari-backups` 이름이 남아 있다. 실행 코드의 기본 버킷은 **`poposafari-db-backups`**다. 별도 버킷을 사용한다면 실제 아카이브 위치와 `R2_BASE`를 함께 맞춘다.

### 설정

| 환경변수 | 기본값 | 용도 |
| --- | --- | --- |
| `WH_DIR` | `/srv/warehouse` | 웨어하우스 기본 디렉터리 |
| `DB` | `$WH_DIR/poposafari.duckdb` | 적재·빌드·대사 대상 DB |
| `DUCKDB` | `duckdb` | DuckDB CLI 경로 |
| `R2_BASE` | `r2://poposafari-db-backups` | 아카이브 루트; 로컬 디렉터리도 가능 |
| `SECRETS` | `$WH_DIR/secrets.sql` | R2 자격증명 SQL |
| `SKIP_SECRETS` | `0` | 로컬 픽스처 실행 시 `1` |
| `FORCE_RELOAD` | `0` | 현재 스캔 범위 강제 재처리 |
| `OUT` | `dashboard/public/data` | 대시보드 빌드 출력 경로 |
| `DATA_DIR` | `dashboard/public/data` | 대시보드 검사 입력 경로 |
| `WINDOW_DAYS` | `14` | 대사할 아카이브 날짜 범위 |
| `GAP_THRESHOLD` | `1000` | 대사에서 경고할 인접 ID 차이 기준 |
| `DISCORD_WEBHOOK_ALERTS` | 미설정 | 적재 실패·어서션 위반·대사 불일치 알림 |
| `HC_LOAD` | 미설정 | 적재 상태를 전송할 Healthchecks UUID |

설치 전용 옵션은 `RUN_USER`, `LOG_DIR`, `DUCKDB_VERSION`, `DUCKDB_URL`, `DASH_BIND`, `DASH_PORT`다. 사용자 지정 `WH_DIR`나 알림 환경변수는 생성된 cron에 자동으로 전달되지 않으므로 실행 환경에도 설정해야 한다. 서버 저장소의 `.env.backup`을 자동으로 읽지는 않는다.

### 일상 운영과 조회

cron 템플릿은 `CRON_TZ=UTC`로 적재·빌드를 19:00 UTC(다음 날 04:00 KST), 대사를 19:30 UTC(04:30 KST)에 예약한다. 설치한 cron 구현이 `CRON_TZ`를 지원하는지 확인하고, 지원하지 않으면 호스트 시간대에 맞춰 시간을 조정한다.

```bash
# 적재 성공 후에만 대시보드 갱신
./load/run.sh && ./dashboard/build.sh

# 최근 아카이브와 DB 비교
./checks/reconcile.sh

# 정적 파일 서버 상태
systemctl status poposafari-dashboard
journalctl -u poposafari-dashboard -n 50
```

대사 출력은 기본 `/var/log/poposafari/check.log`에 기록된다. 현재 cron 줄의 리다이렉션은 `dashboard/build.sh`에만 적용되므로 `load.log`에는 빌드 출력이 기록된다. 적재 출력까지 함께 보관하려면 cron 명령을 `{ load/run.sh && dashboard/build.sh; } >> ... 2>&1` 형태로 묶고 각 경로를 절대 경로로 지정한다.

수동 SQL은 저장소 루트에서 DB를 `wh`라는 이름으로 연결해 실행한다.

```bash
duckdb <<'SQL'
ATTACH '/srv/warehouse/poposafari.duckdb' AS wh (READ_ONLY);
USE wh;
SELECT * FROM wh.load_log ORDER BY run_at DESC LIMIT 5;
.read recipes/onboarding_8.sql
.read checks/contract_drift.sql
SQL
```

`checks/assertions.sql`은 적재 후 자동 실행한다. 위반을 알리지만 이미 적재된 데이터를 롤백하거나 빌드를 막지는 않는다. `contract_drift.sql`은 수동으로 소스 형식 변화를 조사할 때 사용한다. 어뷰징 쿼리는 [recipes/abuse](recipes/abuse/README.md)에 있으며 수동 검토용이다.

### 재처리와 복구

적재는 `${DB}.lock`의 배타 잠금, 빌드·대사는 공유 잠금을 사용한다. 충돌하면 기다리지 않고 **종료 코드 75**로 끝난다. 실행 중 잠금 파일을 삭제하지 않는다. 수동 SQL과 파일 복원은 이 잠금을 자동으로 따르지 않으므로 배치 작업을 멈춘 뒤 수행한다.

- **R2에는 있는데 DB에 없는 행:** `FORCE_RELOAD=1 ./load/run.sh`로 재처리한다. 대사 기본 범위는 14일, 일반 적재 범위는 7일이므로 누락된 객체가 `scan_state.scan_from` 이후인지 먼저 확인한다. 강제 재처리는 스캔 기간을 넓히지 않는다.
- **DB 파일 복원:** 적재 전 `CHECKPOINT` 후 만들어 둔 `${DB}.prev`를 사용한다. 독립 사본이므로 DB 하나만큼의 추가 디스크 공간이 필요하다. 작업을 중지하고 실패한 DB와 `.wal`을 별도 보관한 뒤 사본을 복원하고 대시보드를 다시 빌드한다.
- **전량 재구축:** 기존 DB를 보관하고 새 `DB` 경로로 적재한다. 빈 DB는 전체 스캔을 수행하지만 **R2에 남아 있는 데이터만** 복원할 수 있다. 대사와 검증을 마친 뒤 운영 DB를 교체한다.

저장소에 기록된 서버 아카이브 방식은 업로드 후 `audit_log`를 삭제하며, `audit/` 보존 기간은 365일이다. 그 기간이 지난 데이터는 웨어하우스가 유일한 사본이 될 수 있다. `.prev`는 직전 적재 사본이므로 장기 백업을 대신하지 않는다. 장기 보존이 필요하면 R2 보존 기간 연장 또는 별도 DB·Parquet 백업을 마련한다.

대사의 `GAP`은 아카이브 내부의 ID 공백을 뜻한다. 서버의 export와 DELETE 사이 유실 가능성을 조사하는 신호지만, 트랜잭션 롤백도 ID를 소모하므로 **유실의 확정 증거는 아니다**. 아카이브에 없는 행은 이 파이프라인의 재처리로 복구할 수 없다.

## 데이터 접근 경계

대시보드에는 인증이 없고 화면과 JSON에 `account_id`가 포함된다. 신뢰할 수 있는 운영자만 접근하는 LAN/Tailscale 주소에 바인드한다.

웨어하우스 디렉터리는 0700, `secrets.sql`은 0600으로 설치한다. 자격증명은 저장소에 커밋하지 않는다. 템플릿은 `PERSISTENT SECRET`을 사용하므로 실행 사용자의 `~/.duckdb/stored_secrets/`에도 자격증명이 저장된다.

`ip`는 적재에서 버리지만, **`detail` 전체가 익명화되는 것은 아니다.** 뷰의 편의 URL 컬럼만 쿼리스트링을 제거하며 원본 `detail`은 테이블과 `audit_v`에 남는다. 요청 본문·OAuth 식별자 등이 포함될 수 있으므로 원본 조회 권한을 제한한다. 대시보드 상세에는 계정 ID와 관련 건수를 내보내며 IP·요청 본문·인증정보는 내보내지 않는다.

파이프라인은 `pg/`를 읽지 않지만 감사 아카이브와 DB 백업이 같은 버킷에 있다. 자격증명의 실제 접근 범위와 백업 데이터 노출 범위는 별도로 관리해야 한다.

## 개발 검증

`fixtures/run-local.sh`는 입력 형식, UTC 변환, 마스터 ID 정규화, 빈 입력, 중복 적재, 지표·레시피, 대사와 대시보드 계약을 확인한다. 이어서 증분 처리, 강제 재처리, 실패 후 재시도, 장기 중단, 잠금, 독립 백업과 게시 실패 회귀 검사도 실행한다.

브라우저 검증에는 Node.js, Playwright와 Chrome이 추가로 필요하다. 앞서 생성한 테스트 데이터를 사용한다.

```bash
DATA_DIR="$POPO_TEST_WORK/dash" node dashboard/browser-test.cjs
```

Playwright가 별도 위치에 설치되어 있으면 `PLAYWRIGHT_MODULE`로 모듈 경로를 지정한다. 스크린샷 기본 경로는 `/tmp/popo-browser`다.

성능 비교는 픽스처 생성 후 Python 3.12 이상에서 실행한다.

```bash
BASELINE_REF=HEAD python3 fixtures/benchmark.py
```

지정 Git ref와 작업 디렉터리의 코드를 같은 데이터로 비교한다. 반복 적재·빌드 각 3회의 시간 중앙값, 최대 RSS, 실제 읽은 객체 수와 네 지표 JSON의 일치 여부를 확인한다. 로컬 측정은 운영 장비 성능이나 R2 전송 비용을 대신하지 않는다.

## 저장소 안내

| 경로 | 역할 |
| --- | --- |
| [bootstrap/](bootstrap/) | Linux 설치, R2 자격증명 템플릿, cron |
| [load/](load/) | 스키마, 스캔 계획, 로그·마스터 적재, 실행 잠금 |
| [views/](views/) | 파싱, 마스터 조인, 지표 SQL |
| [dashboard/](dashboard/) | JSON 빌드·검증, 정적 화면, systemd 유닛 |
| [checks/](checks/) | 적재 후 어서션, 소스 계약 점검, R2 대사 |
| [recipes/](recipes/) | 분석 예제와 수동 어뷰징 탐지 SQL |
| [fixtures/](fixtures/) | 합성 데이터, 회귀 검사, 벤치마크 |
| [docs/](docs/) | 아키텍처, 설계 이력, 서버 데이터 조사 |

설계 배경은 [아키텍처](docs/architecture.md), [v3 설계](docs/plan-v3-data-pipeline.md), [v2 설계](docs/data-pipeline-plan-v2.md)를 참고한다. [데이터 엔지니어 온보딩](docs/data-engineering-onboarding.md)은 서버 데이터 구조를 조사한 과거 시점의 문서다. 이들 문서의 배포 현황·보존 정책·미구현 계획은 현재 실행 코드 및 운영 설정과 구분해서 읽는다.
