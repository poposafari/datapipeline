# PopoSafari — 데이터 파이프라인 계획서 v2

> **v1(2026-08-06) 전면 재작성.** 기준 문서: `data-engineering-onboarding.md`(2026-08-07), `mini_pc.md`.
> v1은 온보딩 문서를 보지 않고 코드만 읽고 작성됐다. 그 결과 **인프라 전제가 틀렸고, 이미 있는 자산을 다시 만들려 했고, 이미 고쳐진 버그를 리스크로 올렸다.** 이 문서가 v1을 대체한다.
>
> ⚠️ 이 문서는 계획서다. 코드는 수정하지 않았다.

---

## 0. v1에서 무엇이 바뀌었나

읽는 사람이 v1을 기억한다는 전제로, 바뀐 것만 먼저 적는다.

### 0-1. 틀렸던 것 — 삭제 또는 정정

| v1 주장                                                              | 실제                                                                                                                                 | 조치                                                  |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- |
| "Lightsail 단일 인스턴스, 컨테이너 각 1GB"                           | **4GB / 2 vCPU 버스터블**, us-east-1. 앞단에 Cloudflare(mTLS origin pull)                                                            | 전제 교체. 버스터블 크레딧 고갈이 v1이 놓친 실질 제약 |
| **B9** "prune이 24h `setInterval`이라 잦은 배포 시 영영 안 돈다"     | **이미 수정됨.** `dailyPrune`은 24h 주기 + **부팅 시 1회**                                                                           | 항목 삭제                                             |
| "`item.service` audit detail에 잔액 정보가 없다. 반드시 넣어야"      | **이미 있다.** `ITEM_BUY`/`ITEM_SELL`의 `detail.money` = **거래 후 잔고**. 유저별 잔고 시계열이 `user.money` 스냅샷 없이도 복원 가능 | 항목 삭제. 오히려 자산으로 재분류                     |
| "Prometheus/Grafana 스택이 이미 있는데 안 쓰고 있다"                 | 메트릭은 **4GB 박스 마진 때문에 의도적으로 미도입**. 현재 = `docker stats` + Healthchecks.io dead-man's switch                       | v1 Phase 4 통째로 보류(§6)                            |
| "볼륨 최대 430MB/일 → BQ 무료 10GB를 23일에 소진"                    | 압축 후 기준으로 재계산하면 **상한에서도 10~24MB/일**(§5). 현 트래픽에선 0.1MB/일 수준                                               | 리스크 등급 하향. 착수를 막을 이유가 아니다           |
| `event_id` UNIQUE + `export_cursor` 테이블 + MERGE dedupe (3단 방어) | 결정적 객체명 + 조회 시점 dedupe로 **동일한 보장을 prod 스키마 변경 0으로** 달성                                                     | 설계 교체(§3-3)                                       |
| "`audit_log`에 이메일 없음 = PII 안전"                               | `LOGIN_FAILED.detail.body.username`(실패 시도 아이디 평문), `REQUEST_REJECTED.detail.url`(OAuth code 실릴 수 있음)이 샌다            | §4로 승격                                             |

### 0-2. 몰랐던 자산 — 다시 만들지 말 것

v1은 아래를 전부 신규 구축 대상으로 잡았다. 이미 있다.

- **`audit_log_ro` 뷰** — `ip` 제외 컬럼 목록. 이미 정의돼 있음
- **`docs/audit-log-readonly-access.md`** — 마스킹 근거·CSV export·읽기전용 롤·Tailscale 접근의 **정본 절차**. 부록 A에 8개 검증 항목까지 있음
- **R2 + `scripts/ops/backup-pg.sh`** — `aws --profile r2` 자격증명, 6시간 주기 `pg_dump`, 30일 lifecycle. **익스포터가 재활용할 경로가 이미 뚫려 있다**
- **Healthchecks.io dead-man's switch** — 익스포터 정지 감지에 그대로 쓴다(§3-4)
- **Tailscale** — 미니 PC ↔ prod 연결 수단이 이미 있음
- **`docs/runbook-restore.md`, `runbook-alerts.md`, `deployment_record.md`**

### 0-3. 새로 들어온 것 — 미니 PC

`mini_pc.md`의 `poposafari` 박스(172.30.1.13)가 **분석·적재 전용 박스**로 확정됐다.

|          | 값                                                              | 파이프라인 관점                                                                               |
| -------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| CPU      | Celeron N3150, 4C/4T @1.6–2.08GHz                               | 싱글스레드가 느리다. JVM 기반 BI(Metabase 등)는 부담. **DuckDB가 이 박스에 정확히 맞는 도구** |
| RAM      | 7.7GB (사용 1.0GB, 여유 6.6GB) + swap 4GB                       | prod 4GB 박스보다 분석 여유가 크다                                                            |
| 디스크   | LVM 루트 54.9G 중 **37G 여유** (물리 111.8G — LV 확장 여지 55G) | 상한 볼륨으로도 수년치. 단 **단일 소비자 디스크, 이중화 없음** → 정본은 R2에 둔다             |
| 네트워크 | RTL8111 GbE + Tailscale                                         | 가정용 회선. 끊겨도 커서 기반이라 재개 안전                                                   |
| 가상화   | VT-x                                                            | Docker 가속 OK                                                                                |

**이게 설계를 통째로 바꾼다.** v1이 BigQuery로 간 이유는 "게임 서버 박스에 분석 부하를 얹을 수 없다"였다. 미니 PC가 그 부하를 전부 흡수하므로, **신규 클라우드 벤더·자격증명·국외이전 검토가 전부 불필요해진다.**

---

## 1. 설계 원칙

온보딩 문서 §10의 원칙을 그대로 따른다 — _"가장 단순한 충분조건으로 간다. 1인 운영 + 4GB 단일 박스. 큐·워커·dead-letter 같은 조기 인프라는 경계하고, 승격 경로만 명시해두는 쪽을 선호."_

1. **prod에 신규 컴포넌트를 두지 않는다.** 익스포터는 컨테이너가 아니라 **cron 스크립트 한 개**다. v1의 `poposerver_exporter`(192MB 컨테이너)는 4GB 박스에서 정당화되지 않는다.
2. **prod 스키마를 바꾸지 않는다.** 이 프로젝트는 versioned migration 없이 수동 `drizzle-kit push`다(온보딩 §3-5 경고). 적재를 위해 `audit_log`를 건드리는 건 비용 대비 위험이 크다. §3의 설계는 스키마 변경 0으로 성립한다.
3. **신규 벤더 0.** Cloudflare R2는 이미 쓰고 있다. 접점은 R2 하나뿐 — prod는 던지기만, 미니 PC는 받기만.
4. **불완전해도 지금 남긴다.** 계측 갭(포획 실패, 세션 이벤트)을 고치는 걸 기다리지 않는다. 온보딩 §10-③: _"이건 안 하면 지금 지나가는 데이터가 영영 사라진다."_ → **추출이 Phase 1**이고, 계측 개선이 Phase 2다. v1은 순서가 반대였다.
5. **두 채널을 섞지 않는다.** (v1에서 유지) 이벤트는 웨어하우스, 진단 로그는 별개. 단 v1의 Loki/Alloy는 과잉이므로 §6으로 보류.

---

## 2. 아키텍처

```
Cloudflare 엣지
   │
   ▼
Lightsail 4GB / 2vCPU  (us-east-1)                    ┌── 기존 ──┐
   ├─ nginx / server / postgres                       │ pg_dump  │ 6h, 30일 lifecycle
   └─ cron: export-audit.sh  ─────────────┐           └────┬─────┘
        · id 커서 증분 · 추출 시점 마스킹  │                │
        · CSV.gz · 결정적 객체명           │                │
                                           ▼                ▼
                            ┌──────────────────────────────────────┐
                            │  Cloudflare R2                        │
                            │   poposafari-analytics/  ← 신규 버킷   │
                            │     raw/dt=…/audit_<from>_<to>.csv.gz │
                            │     backfill/dt=…/resweep.csv.gz      │
                            │   poposafari-backup/     (기존, 30일)  │
                            └──────────────────┬───────────────────┘
                                               │ pull (일 1회)
                                               ▼
                      미니 PC  poposafari (172.30.1.13, 4C/7.7GB/37G)
                        └─ DuckDB  /srv/warehouse/poposafari.duckdb
                             · id 안티조인 적재 (중복 무해)
                             · 마스터 CSV 조인 (포맷 정규화)
                             · SQL 레시피 = 온보딩 §8 재활용
```

**계층은 3개가 아니라 2개다.** v1의 `raw → stg → mart`는 BigQuery 과금 구조(뷰는 무료, 스캔은 유료)에 최적화된 형태다. DuckDB에는 스캔 과금이 없으므로 **raw 테이블 + 뷰**로 충분하다. mart를 물리화할 이유가 생기면 그때 `CREATE TABLE AS`를 하면 된다.

### 왜 익스포터가 미니 PC가 아니라 prod에 있나

미니 PC가 Tailscale로 prod PG를 직접 pull하는 구성도 가능하고, 온보딩 §7-3에 절차가 있다. 그런데도 push를 택한 이유:

- **신규 네트워크 노출 0.** pull은 5432를 Tailscale 대역에 바인딩 + 읽기전용 롤 생성 + 8개 검증 통과가 선행 조건이다. push는 기존 R2 자격증명만 쓴다.
- **가정용 회선에 의존하지 않는다.** 미니 PC가 꺼져 있어도 추출은 계속된다.
- **prod 비용이 무시할 수준이다.** 커서 기반 증분은 PK 인덱스 범위 스캔 + 수천 행 gzip이다. 온보딩 §7-1이 경고한 건 *"무거운 집계의 반복 실행"*이지 좁은 PK 범위 읽기가 아니다.

Tailscale 실시간 접근은 **ad-hoc 디버깅용으로 남겨둔다**(온보딩 §7-3 그대로). 정기 파이프라인이 거기 의존하지 않게 한다.

---

## 3. 추출 설계

### 3-1. prod 측 — `scripts/ops/export-audit.sh` (신규, cron 15분)

`backup-pg.sh`와 같은 디렉터리·같은 `.env.backup`·같은 `aws --profile r2`를 쓴다.

```bash
#!/usr/bin/env bash
set -euo pipefail
source /home/ubuntu/.env.backup          # backup-pg.sh와 동일

CURSOR=/var/lib/poposafari/audit_cursor
BUCKET=poposafari-analytics
mkdir -p "$(dirname "$CURSOR")"
LAST=$(cat "$CURSOR" 2>/dev/null || echo 0)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

docker exec -i poposerver_postgres psql -U "$DB_USERNAME" -d "$DB_DATABASE" \
  -v ON_ERROR_STOP=1 -c "
COPY (
  SELECT id, account_id, action, status,
         CASE
           -- REQUEST_REJECTED.url 쿼리스트링 절단 (OAuth code 유출 차단)
           WHEN action = 'REQUEST_REJECTED' AND detail ? 'url'
             THEN jsonb_set(detail, '{url}', to_jsonb(split_part(detail->>'url','?',1)))
           -- LOGIN_FAILED 실패 아이디 평문 제거
           WHEN action = 'LOGIN_FAILED'
             THEN detail #- '{body,username}'
           ELSE detail
         END AS detail,
         user_agent, source, created_at
  FROM audit_log
  WHERE id > $LAST
    AND created_at < now() - interval '5 minutes'   -- ★ 3-2
  ORDER BY id
) TO STDOUT WITH CSV HEADER" > "$TMP/b.csv"

MAX=$(tail -n +2 "$TMP/b.csv" | tail -1 | cut -d, -f1)
[ -z "$MAX" ] && { curl -fsS -m 10 "https://hc-ping.com/$HC_AUDIT_EXPORT" >/dev/null; exit 0; }

gzip -9 "$TMP/b.csv"
OBJ=$(printf 'audit_%012d_%012d.csv.gz' "$((LAST+1))" "$MAX")
aws --profile r2 s3 cp "$TMP/b.csv.gz" "s3://$BUCKET/raw/dt=$(date -u +%F)/$OBJ"
echo "$MAX" > "$CURSOR"
curl -fsS -m 10 "https://hc-ping.com/$HC_AUDIT_EXPORT" >/dev/null
```

**멱등성이 어디서 나오는가**: 객체명이 `(LAST+1, MAX)`로 **결정적**이다. 업로드 후 커서 기록 전에 죽으면 다음 실행이 같은 이름으로 같은 내용을 덮어쓴다. `event_id` UNIQUE도, MERGE도, `export_cursor` 테이블도 필요 없다 — **prod 스키마 변경 0.**

`\copy`가 아니라 `COPY ... TO STDOUT`을 쓴 이유: `\copy`는 psql 메타명령이라 개행으로 끝나 여러 줄 쿼리를 못 쓴다. `TO STDOUT`은 superuser가 필요 없고 스트리밍된다.

### 3-2. ⚠️ 함정 ① — bigserial 커밋 순서 갭

온보딩 §3-1은 *"`id`는 bigserial 단조 증가라 `WHERE id > :last_id`가 가장 싸고 안전하다"*고 쓰지만, **이건 절반만 맞다.** 시퀀스는 **커밋 전에** 할당된다.

```
t1  tx A 시작 → id=100 할당
t2  tx B 시작 → id=101 할당
t3  tx B 커밋            ← 익스포터 폴링. 101만 보임 → 커서=101
t4  tx A 커밋            ← 100은 영원히 커서 뒤. 조용히 유실
```

`created_at` 커서에도 같은 문제가 있다(문서가 지적한 대로). 어느 쪽 커서든 **커밋 순서 ≠ 키 순서**라는 성질은 남는다.

**2단 방어** (v1의 3단에서 하나 줄임 — dedupe가 공짜라 재스윕이 곧 두 번째 방어를 겸한다):

1. **`AND created_at < now() - interval '5 minutes'`** — 최장 트랜잭션보다 긴 유예. 현 코드의 tx는 전부 짧다(도메인 변이 1건 단위).
2. **야간 재스윕** — 매일 03:10 UTC, 직전 2일치를 `created_at` 기준으로 통째 재추출해 `backfill/dt=…/resweep.csv.gz`에 덮어쓴다. 조회 계층이 `id`로 dedupe하므로 겹쳐도 무해하고, 갭이 있었다면 여기서 메워진다.

```sql
-- resweep (같은 스크립트, --resweep 플래그)
WHERE created_at >= date_trunc('day', now()) - interval '2 days'
  AND created_at <  date_trunc('day', now())
```

### 3-3. ⚠️ 함정 ② — R2 lifecycle 30일

**기존 `pg_dump` 백업 버킷에 분석 데이터를 같이 넣으면 30일 뒤 조용히 사라진다.** `janitor.ts`의 60일 하드 컷을 피하려고 만든 파이프라인이 다른 계층에서 똑같은 실수를 반복하는 형태다.

→ **버킷을 분리한다.** `poposafari-analytics`는 신규 버킷, **lifecycle 규칙 없음**. `poposafari-backup`의 30일 규칙은 그대로 둔다.
→ 착수 시 검증: `aws --profile r2 s3api get-bucket-lifecycle-configuration --bucket poposafari-analytics` 가 `NoSuchLifecycleConfiguration`을 반환해야 한다.

### 3-4. 익스포터 감시 — dead-man's switch로 충분

v1은 `export_cursor` 테이블을 만들고 `janitor.pruneAuditLog()`가 워터마크 뒤로만 삭제하도록 고치자고 했다. **과잉이다.**

- 익스포터 정상 지연은 15분이다. prune은 **60일** 뒤에 지운다. 유예가 5,760배다.
- 익스포터가 60일 동안 죽어 있어야만 유실이 발생한다. 그건 **알림으로 잡는 문제**지 스키마로 잡는 문제가 아니다.
- Healthchecks.io dead-man's switch가 **이미 운영 중**이다. 체크 하나 추가(`HC_AUDIT_EXPORT`, grace 2시간)면 끝난다.

→ `janitor.ts`와 `audit_log` 스키마는 **손대지 않는다.**

### 3-5. 정합성 대사 (일 1회, 미니 PC)

```sql
-- prod (Tailscale ad-hoc 또는 재스윕 스크립트가 같이 출력)
SELECT created_at::date d, count(*) FROM audit_log
WHERE created_at > now() - interval '14 days' GROUP BY 1 ORDER BY 1;
-- 미니 PC
SELECT created_at::date d, count(*) FROM wh.audit
WHERE created_at > now() - interval '14 days' GROUP BY 1 ORDER BY 1;
```

불일치 행이 있으면 Discord webhook. (`.github/workflows/deploy.yml`이 이미 Discord webhook을 쓰므로 시크릿 패턴 재활용.)

---

## 4. PII — 60일 컷이 사실상의 개인정보 최소화 장치였다

**이 파이프라인의 가장 큰 부작용은 볼륨도 비용도 아니다.** `janitor.ts`의 60일 하드 컷은 의도가 무엇이었든 **자동 개인정보 최소화 장치로 작동하고 있었다.** 무기한 적재는 그 장치를 해제한다. 온보딩 §3-5가 *"`audit_log`는 이 프로젝트에서 PII 밀도가 가장 높은 테이블"*이라 쓴 대상을, 이제 영구 보관하겠다는 뜻이다.

| 항목                                | 조치                                               | 근거                                                                                                                         |
| ----------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `ip`                                | **추출 컬럼에서 제외**                             | `audit_log_ro` 뷰와 동일한 컬럼 목록. v1의 HMAC 해시 + /24 절삭은 불필요한 복잡도 — 1인 운영에서 IP 재식별 유즈케이스가 없다 |
| `LOGIN_FAILED.detail.body.username` | **추출 시점 제거** (`detail #- '{body,username}'`) | 실패 시도 아이디 평문. `redactBody()`는 비밀번호만 가린다                                                                    |
| `REQUEST_REJECTED.detail.url`       | **추출 시점 쿼리스트링 절단**                      | OAuth 콜백이 GET이라 authorization code가 실릴 수 있음(일회용·단명이지만 영구 보관은 별개 문제)                              |
| `LOGIN_OAUTH.detail.providerId`     | **1차 적재는 유지, 필요 시 해싱**                  | 직접 식별자. 다만 계정 매핑 디버깅에 실사용 가치가 있어 즉시 제거는 보류 — Phase 4에서 판단                                  |
| `user_agent`                        | **유지**                                           | 온보딩 §3-5가 *"알고서 포함하기로 결정됨"*이라 명시. 기존 결정을 뒤집지 않는다                                               |
| `account_id`                        | **유지**                                           | 가명 식별자. 미니 PC 로컬 분석이라 해싱 실익 없음. 외부 공유 시에만 `md5(account_id \|\| salt)`                              |
| `session.id`                        | **절대 추출 대상 아님**                            | 살아있는 인증 토큰. `audit_log`엔 없지만 `pg_dump` 백업엔 **있다** → 분석 버킷과 백업 버킷을 섞지 말아야 할 또 하나의 이유   |

**저장 위치 리스크**: R2 버킷은 비공개 + 미니 PC/운영자 자격증명만. 미니 PC의 `/srv/warehouse`는 디스크 암호화가 없으므로(LVM plain) 물리 도난 시 노출된다. 1인 가정 환경에서 수용 가능한 리스크로 판단하되, 명시해둔다.

**국외이전 이슈는 사라졌다.** v1은 BigQuery 리전을 `asia-northeast3`로 지정해야 한다고 썼는데, 자체 호스팅이라 해당 없음. (R2는 이미 백업에 쓰고 있어 새로 발생하는 판단이 아니다.)

---

## 5. 볼륨 재계산 — v1의 최대 리스크는 리스크가 아니었다

v1은 "최대 430MB/일, BQ 무료 10GB를 23일에 소진"이라며 이걸 Phase 2 착수 차단 조건으로 걸었다. 압축을 계산에 넣지 않았다.

**상한 시나리오** (`SLOT_CAPACITY`=50 만석, 전원이 5초에 1회 포획 시도 — 현실성 없는 최악값):

|                                                                                       | 값                               |
| ------------------------------------------------------------------------------------- | -------------------------------- |
| 행 수                                                                                 | 864,000 행/일                    |
| PG 저장 (행 오버헤드 포함 ~400B)                                                      | ~346 MB/일                       |
| **CSV.gz** (논리 280B, gzip ~5x)                                                      | **~48 MB/일**                    |
| **Parquet+zstd** (딕셔너리 인코딩 — `action`/`source`/`user_agent`가 반복, `id` 델타) | **~10–24 MB/일 · 연 3.5–8.8 GB** |

**현실 시나리오** (정식 출시 전, DAU 30, 계정당 200 이벤트): **~0.1 MB/일 · 연 40 MB.**

→ **볼륨은 착수를 막을 이유가 못 된다.** 미니 PC 여유 37GB, R2 무료 10GB. 상한이 몇 년을 버틴다. Phase 1 실측 후 정책을 정하자던 v1의 게이트를 **제거하고, 계측 개선(Phase 2)을 볼륨 실측과 병렬로 진행한다.**

단, 두 가지는 실측 대상으로 남긴다:

- `POKEMON_SELL`은 판매 항목마다 행이 생긴다(루프 안 `auditTx`). 일괄 판매 UX가 붙으면 행 수가 튄다.
- 포획 시도 계측(§Phase 2)을 켜면 이게 단일 최대 볼륨 드라이버가 된다. 켠 뒤 1주 실측.

---

## 6. Phase — v1의 5단계를 4단계로, 순서를 뒤집었다

**v1은 Phase 0(로깅 위생)을 선행 필수로 걸었다. 순서가 틀렸다.** 로깅 위생은 미루면 불편하지만, 추출은 미루면 **데이터가 영영 사라진다**(온보딩 §10-③). 되돌릴 수 없는 것을 먼저 한다.

### Phase 1 — 추출 시작 (0.5일) · 코드 변경 0

되돌릴 수 없는 손실을 지금 멈춘다. 애플리케이션 코드를 한 줄도 건드리지 않는다.

- [ ] R2 신규 버킷 `poposafari-analytics` 생성 — **lifecycle 규칙 없음 확인** (§3-3)
- [ ] `audit_log_ro` 뷰 존재 확인 (`drizzle-kit push`로 사라졌을 수 있음 — 온보딩 §3-5)
- [ ] `scripts/ops/export-audit.sh` 작성, `.env.backup`에 `HC_AUDIT_EXPORT` 추가
- [ ] cron 등록: 증분 `*/15 * * * *`, 재스윕 `10 3 * * *`
- [ ] Healthchecks.io 체크 생성 (period 15m, grace 2h) → Discord
- [ ] 미니 PC: DuckDB 설치, R2 secret 설정, `/srv/warehouse` 준비, 일 1회 pull cron

### Phase 2 — 계측 갭 (반나절 + 반나절)

각 항목이 독립 배포 가능하다. 온보딩 §10 백로그 ①②를 그대로 따른다.

- [ ] **주석 3줄 해제** — `SAFARI_EXIT`(`safari.controller.ts:46`), `POKEMON_ARRANGE`(`pokemon.controller.ts:54`), `PET_CHANGE`(`apps/socket/app.ts:582`).
      `SAFARI_EXIT` 하나만 켜도 "사파리 체류시간" 지표가 통째로 생긴다. **비용 대비 효과 최대.**
- [ ] **세션 이벤트** — 소켓 `connect`/`disconnect`에 감사 기록. `disconnect` 핸들러엔 이미 flush 호출이 있어 붙이기 쉽다. DAU·세션 길이·동접 이력이 전부 여기서 나온다
- [ ] **포획 시도 계측** — `safari.service.ts:299,400`. `auditTx`가 `result === 'caught'` 분기 안에만 있다. 분기 밖으로 빼고 `detail.result: 'caught'|'fail'|'flee'`.
      온보딩 §9-0이 *"밸런스 분석 최대 공백"*으로 지목. **포획률의 분모가 여기서 생긴다.** 켠 뒤 1주 볼륨 실측(§5)
- [ ] **`redactBody()` 보강** — `REDACT_KEYS`에 `idToken`/`code` 추가, 중첩 재귀 처리 (`lib/utils/audit.ts`). §4의 추출 시점 마스킹은 사후 방어일 뿐이고, 이게 저장 시점 근본 대응

> **하지 않는 것**: v1의 `event_id`/`schema_version`/`session_id` 컬럼 추가, `export_cursor` 테이블, `lib/types/audit-payload.ts` Zod 페이로드 표준화. 전부 prod 스키마·타입 계층을 건드리는데 §3의 설계가 그것 없이 성립한다. `detail` 스키마 무보증(온보딩 §9-5)은 **조회 계층에서 방어적으로 파싱**해 대응한다.

### Phase 3 — 로깅 위생 (1일) · 진단 채널

이벤트 파이프라인과 독립이다. Phase 1과 병렬 진행 가능.

- [ ] winston PROD 파일 트랜스포트 제거 → **stdout 단일화** (`lib/utils/logger.ts:35-64`). 배포마다 로그가 사라지는 문제가 원천 해소됨
- [ ] compose 전 서비스에 `logging: { driver: json-file, options: { max-size: 50m, max-file: 5 } }` — 호스트 디스크 고갈 차단. **stdout 단일화보다 먼저 해야 한다**(단일화하면 stdout 볼륨이 늘어난다)
- [ ] `logger.error('msg', err)` 18곳 → `logger.error('msg', { err: serializeError(err) })`. winston은 2번째 인자를 meta로 취급하고 `Error`의 프로퍼티는 non-enumerable이라 **스택이 통째로 유실된다**
- [ ] `uncaughtException` / `unhandledRejection` 핸들러 + winston `handleExceptions`. 지금은 `main.ts:55-56`이 SIGTERM/SIGINT만 처리 — **프로세스가 죽는 순간의 스택이 어디에도 안 남는다**
- [ ] **OAuth 토큰 엔드포인트 응답 본문 로깅 제거** — `oauth.provider.ts:49-50, 123-124`. status만 남긴다. 응답 형태에 따라 `code`/`client_secret` 에코가 평문으로 남을 수 있음
- [ ] `setErrorHandler`(`apps/api/app.ts:187-217`)에서 5xx `AppError`도 로깅. 현재 비-`AppError`만 로깅해 실패 대부분이 관측 불가
- [ ] `console.log` 제거 (`item.service.ts:201`)
- [ ] `LOG_LEVEL` 환경변수 (`lib/utils/env.ts`) — 현재 런타임 조절 불가
- [ ] `.gitignore`에 `logs/` 추가, 데드 의존성 9종 제거(express·morgan·passport 등 — 특히 `morgan`이 남아 있어 "요청 로깅이 있다"는 오해를 부른다)

> **하지 않는 것**: v1의 Grafana Cloud Loki + Alloy 컨테이너(128MB). 1인 운영에서 `docker logs --since` grep이 충분하고, 컨테이너 하나가 4GB 박스에서 공짜가 아니다. **승격 트리거**: "로그를 찾느라 SSH를 붙는 일이 주 3회 이상" 또는 "동시 조사해야 할 컨테이너가 3개 이상". 그때는 Alloy를 **미니 PC 쪽에** 두고 Tailscale로 `docker logs`를 tail하면 prod 부하 0으로 해결된다.
>
> `requestId`(AsyncLocalStorage 전파)도 보류. 단일 프로세스·저트래픽에서 타임스탬프로 상관이 가능하다. 승격 트리거: 동시 요청이 섞여 로그를 못 읽는 순간.

### Phase 4 — 조회 계층 (0.5일)

- [ ] 미니 PC DuckDB 적재 잡 (§7)
- [ ] `audit` 뷰 + 마스터 데이터 조인 뷰 (`item.csv`, `pokemon.csv`, `map/*.json`)
      **`pokedex_id` 포맷 정규화 필수** — 서버 CSV는 `1`, 클라이언트/`map.json`은 `0001`. SQL 직접 조인은 안 맞는다(온보딩 §6). `pokemon.csv`는 CRLF
- [ ] SQL 레시피 이식 — 온보딩 §8의 5개 쿼리를 DuckDB 문법으로. `isS000Starter=true` 제외 규칙 등 주석 유지
- [ ] `LOGIN_OAUTH.providerId` 해싱 여부 판단 (§4)

### Phase 5 — 승격 경로 (착수 금지 · 조건부)

v1이 Phase 3/4/5로 잡았던 것들. **전부 트리거 조건을 만족할 때까지 착수하지 않는다.**

| 항목                                         | 착수 트리거                                                                                                                 |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **어뷰징 탐지 자동화**                       | 실제 어뷰징 1건 확인. 그전까지는 **인프라가 아니라 쿼리 한 개**로 둔다(§8)                                                  |
| **BI GUI** (Evidence.dev / Metabase)         | DuckDB CLI로 답을 못 찾는 질문이 반복될 때. Celeron N3150에는 JVM 기반 Metabase보다 **정적 사이트 생성형(Evidence)**이 맞다 |
| **중앙 로그 수집** (Loki/Alloy)              | 위 Phase 3 각주의 트리거                                                                                                    |
| **메트릭/APM** (prom-client, Netdata)        | **정식 출시 후.** 온보딩 §10-⑦이 4GB 마진 때문에 의도적으로 미도입이라 명시했고, 그 판단이 아직 유효하다                    |
| **게임 월드 팩트 로깅** (날씨/게임시간/스폰) | 밸런스 분석을 실제로 시작할 때. 온보딩 §10-⑤                                                                                |
| **잔고 스냅샷 잡**                           | `detail.money`로 부분 복원이 안 되는 질문이 생길 때(거래 없는 유저). 온보딩 §10-⑥                                           |

---

## 7. 미니 PC 적재 잡

```sql
-- /srv/warehouse/load.sql  (매일 04:00 KST, duckdb -c ".read load.sql")
INSTALL httpfs; LOAD httpfs;
CREATE SECRET IF NOT EXISTS r2 (
  TYPE r2, ACCOUNT_ID '…', KEY_ID '…', SECRET '…'
);

ATTACH '/srv/warehouse/poposafari.duckdb' AS wh;

CREATE TABLE IF NOT EXISTS wh.audit (
  id BIGINT PRIMARY KEY, account_id INTEGER, action VARCHAR, status SMALLINT,
  detail JSON, user_agent VARCHAR, source VARCHAR, created_at TIMESTAMPTZ
);

-- 최근 7일치 객체만 스캔(hive dt=) → id 안티조인. 재스윕 중복도, 커서 갭 보충분도 여기서 흡수
INSERT INTO wh.audit
SELECT s.* EXCLUDE (dt) FROM (
  SELECT DISTINCT ON (id) *
  FROM read_csv('r2://poposafari-analytics/*/dt=*/*.csv.gz',
                 hive_partitioning = true, union_by_name = true)
  WHERE dt >= (current_date - 7)::VARCHAR
) s
WHERE NOT EXISTS (SELECT 1 FROM wh.audit a WHERE a.id = s.id);
```

**성질**: 재실행해도 안전(안티조인), 파일이 겹쳐도 안전(`DISTINCT ON`), 스캔 범위가 7일로 고정돼 Celeron에서도 초 단위. R2가 정본이므로 `poposafari.duckdb`가 깨져도 `dt` 범위만 넓혀 전체 재구축하면 된다 — **미니 PC 디스크에 이중화가 없어도 되는 이유.**

첫 실행 시에만 `dt >= '2026-01-01'`로 전량 적재.

---

## 8. 어뷰징 탐지 — 인프라가 아니라 쿼리다

v1은 이걸 Phase 5(1주)로 잡고 스케줄 쿼리 + Cloud Function + Discord 알림 파이프라인을 설계했다. **유저 수가 붙기 전에는 과잉이다.** 룰 자체는 유용하니 **DuckDB 레시피로 두고 사람이 주 1회 돌린다.**

가장 값싸고 강력한 것 하나만 예시로:

```sql
-- 샤이니 비율 이항검정 — rollSafariShiny = 1/4096 고정(lib/utils/rng.ts)
-- 조작 시 통계적으로 즉시 드러난다. 튜토리얼 강제 포획은 제외
SELECT account_id,
       count(*)                                                   AS catches,
       count(*) FILTER (WHERE (detail->>'isShiny')::BOOLEAN)      AS shiny,
       count(*) / 4096.0                                          AS expected
FROM wh.audit
WHERE action = 'POKEMON_CATCH'
  AND coalesce((detail->>'isS000Starter')::BOOLEAN, false) = false
  AND created_at > now() - INTERVAL 30 DAY
GROUP BY 1 HAVING catches >= 200 AND shiny > expected * 4
ORDER BY shiny - expected DESC;
```

나머지 룰(시간당 포획 시도 z-score, `money` 급증, 티켓 소모 없는 `SAFARI_ENTER`, 볼 소모 대비 성공률)은 같은 파일에 쿼리로 적어두고, **Phase 2의 포획 시도 계측이 들어온 뒤** 임계치를 잡는다.

> ⚠️ **미검증 항목**: v1이 근거로 든 두 취약점 — `isValidChangeMapTarget` 주석 처리로 인한 임의 좌표 이동(`socket/app.ts:~430`), `item.service.buy`의 트랜잭션 밖 잔액 읽기 레이스 — 은 v1의 코드 리딩에만 근거하며 **온보딩 문서에 대응 기술이 없다.** 탐지 룰을 짜기 전에 코드에서 재확인할 것. 사실이면 탐지보다 **수정**이 먼저다.

---

## 9. 검증

**Phase 1** — 유실 0, 중복 0, PII 0

```sql
-- ① 일별 카운트 대사 (prod vs 미니 PC) — 불일치 0행
-- ② 중복 — 0행이어야 함
SELECT id, count(*) c FROM wh.audit GROUP BY 1 HAVING c > 1;
-- ③ IP 미유출 — 컬럼 자체가 없어야 함
DESCRIBE wh.audit;
-- ④ 마스킹 — 0행이어야 함
SELECT count(*) FROM wh.audit
WHERE (action='REQUEST_REJECTED' AND detail->>'url' LIKE '%?%')
   OR (action='LOGIN_FAILED'     AND detail->'body' ? 'username');
```

```bash
# ⑤ R2 lifecycle 부재 확인 — NoSuchLifecycleConfiguration 이어야 함
aws --profile r2 s3api get-bucket-lifecycle-configuration --bucket poposafari-analytics
# ⑥ 커서 갭 재현 (dev, docker/dev의 postgres-test tmpfs 활용)
#    장기 tx를 열어둔 채 짧은 tx를 커밋 → 익스포터 1사이클 → 장기 tx 커밋
#    → 증분 배치엔 없고, 야간 재스윕 후 wh.audit엔 있어야 한다
# ⑦ dead-man's switch — cron 정지 후 2시간 내 Discord 알림 도착
```

**Phase 2** — 분모가 생겼는가

```sql
SELECT detail->>'result', count(*) FROM audit_log
WHERE action = 'POKEMON_CATCH_ATTEMPT' AND created_at > now() - interval '1 day'
GROUP BY 1;   -- caught / fail / flee 3값이 다 나와야 한다
```

**Phase 3** — 재배포 후에도 로그가 남고, 스택이 남는가

```bash
docker compose -f docker/prod/docker-compose.yml up -d --force-recreate server
docker logs poposerver_server --since 10m | jq 'select(.level=="error") | .err.stack' | head
```

**Phase 4** — 온보딩 §8의 5개 쿼리가 DuckDB에서 같은 결과를 내는가 (prod 직접 실행분과 대조)

---

## 10. 리스크

| 리스크                     | 영향                                                  | 완화                                                                                                                                                 |
| -------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **bigserial 커밋 순서 갭** | 조용한 유실                                           | 5분 유예 + 야간 재스윕 + 일별 대사 (§3-2, §3-5)                                                                                                      |
| **R2 lifecycle 오적용**    | 30일 뒤 조용한 삭제                                   | 버킷 분리 + 착수 시 검증 (§3-3)                                                                                                                      |
| **PII 영구 보관**          | 60일 자동 최소화 장치 해제                            | 추출 시점 마스킹 + 버킷 비공개 (§4)                                                                                                                  |
| **미니 PC 단일 디스크**    | 로컬 웨어하우스 손실                                  | R2가 정본. `poposafari.duckdb`는 언제든 재구축 가능 (§7)                                                                                             |
| **가정용 회선/전원**       | 적재 지연                                             | prod push라 추출 자체는 무영향. 미니 PC는 pull만 밀린다                                                                                              |
| **마이그레이션 이력 부재** | `drizzle-kit push`가 `audit_log_ro` 뷰를 날릴 수 있음 | Phase 1 체크리스트에 뷰 존재 확인 포함. 파이프라인이 prod 스키마를 안 건드리므로 그 외 노출은 없음                                                   |
| **버스터블 CPU 크레딧**    | 무거운 쿼리 반복 시 게임 전체 저하                    | 정기 파이프라인은 좁은 PK 범위 읽기뿐. **분석 쿼리는 전부 미니 PC에서** (온보딩 §7-1)                                                                |
| **테스트 부재**            | 익스포터 회귀                                         | 커서/재스윕 로직만이라도 `docker/dev`의 `postgres-test`(tmpfs, 8888)로 테스트                                                                        |
| **⚠️ 낡은 문서 참조**      | 잘못된 전제                                           | `server/docs/data-storage-strategy.md`(Redis 전제, 옛 테이블명) **참조 금지**. `load-test/out`의 2026-06-12 측정치는 구 4앱 아키텍처라 **인용 금지** |

---

## 11. 결정이 필요한 사항

v1의 4개 중 3개가 자동 해소됐다(GCP 계정 → 불필요, 진단 로그 목적지 → 보류, 볼륨 게이트 → §5로 해소).

1. **`LOGIN_OAUTH.detail.providerId`를 적재할 것인가** — 직접 식별자이지만 계정 매핑 디버깅에 쓰인다. 1차 유지 후 Phase 4에서 판단.
2. **`audit_log` 원본 60일 보존을 단축할 것인가** — 웨어하우스가 생기면 30일로 줄여 prod PG 부담을 덜 수 있다. 다만 §3-4의 유예(5,760배)도 같이 줄어든다. **파이프라인이 1개월 무사고로 돈 뒤에** 판단할 것.
3. **`docs/audit-log-readonly-access.md`를 이 문서로 갱신할 것인가** — 정본 절차 문서이므로, 파이프라인이 생기면 "정기 추출은 R2, ad-hoc은 Tailscale"로 갈래가 나뉜다는 걸 그쪽에도 반영해야 한다.

---

## 부록 — 파일 변경 범위

**신규**

- `server/scripts/ops/export-audit.sh` — 증분 + `--resweep`
- 미니 PC `/srv/warehouse/load.sql`, `/srv/warehouse/recipes/*.sql`

**수정 (Phase 2)**

- `safari.controller.ts:46`, `pokemon.controller.ts:54`, `apps/socket/app.ts:582` — 주석 해제
- `apps/api/domains/game/safari.service.ts:299,400` — 포획 시도 계측
- `apps/socket/app.ts` — 세션 시작/종료 이벤트
- `lib/types/audit.type.ts` — 액션 2종 추가
- `lib/utils/audit.ts` — `redactBody()` 재귀화 + `idToken`/`code`

**수정 (Phase 3)**

- `lib/utils/logger.ts`, `lib/utils/env.ts`, `apps/server/main.ts`, `apps/api/app.ts`
- `apps/api/domains/auth/oauth/oauth.provider.ts`, `item.service.ts:201`
- `docker/prod/docker-compose.yml` — logging 드라이버만 (**신규 서비스 없음**)
- `.gitignore`, `package.json`

**손대지 않는 것**: `lib/schema/*`, `apps/server/game-loop/janitor.ts`, `docker/prod/monitor/*`
