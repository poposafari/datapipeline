# PopoSafari — 데이터 엔지니어 온보딩

> 대상: 로그·이벤트를 다뤄본 데이터 엔지니어가 **이 프로젝트의 데이터가 어디서 생겨 어디에 쌓이고 언제 사라지는지**를 하루 안에 파악하기 위한 문서.
> 코드 기준일: **2026-08-07**. 1차 소스는 `server/lib/schema/*`, `server/lib/utils/audit.ts`, `server/apps/**`, `docs/deployment_record.md`.
>
> ⚠️ 먼저 읽고 버릴 것: `server/docs/data-storage-strategy.md`는 **낡았다**(Redis 전제 + 옛 테이블명 `users`/`user_bags`). 본 문서가 그 자리를 대체한다.

---

## 0. 60초 요약

| 질문 | 답 |
| --- | --- |
| 분석 가능한 **이벤트 스트림**이 있나? | **`audit_log` 테이블 하나뿐.** Kafka/Kinesis/S3 이벤트 레이크 없음 |
| 이벤트는 몇 종류? | `AuditAction` enum **30종 정의 / 27종 실제 발생**(3종은 미배선) |
| 보존 기간? | **60일** (`janitor.ts`가 매일 DELETE). 60일 이전 데이터는 **존재하지 않는다** |
| 저장소? | **PostgreSQL 15 단일 인스턴스** (Lightsail 4GB 박스에 게임 서버와 동거) |
| 웨어하우스/BI? | **없음.** 현재 표준 워크플로 = "prod에서 CSV export → 로컬에서 분석" |
| 메트릭·APM? | **없음.** 시계열 지표는 수집조차 안 됨(동접 스냅샷 API 1개가 전부) |
| 애플리케이션 로그? | winston → **컨테이너 안 파일**(14일/에러 30일). 중앙 수집 없음, 사실상 사후 grep용 |
| 가장 큰 함정 | ① 실패한 변이는 기록되지 않는다 ② `audit_log`가 PII 밀도 최고 테이블 ③ 3종 이벤트는 코드에 주석처리돼 있다 |

---

## 1. 시스템 전경 — 데이터가 흐르는 경로

### 1-1. 물리 구성

```
Browser (Phaser 3 클라이언트)
  │ HTTPS / WSS
  ▼
Cloudflare 엣지  (DNS·DDoS·CDN·TLS 종단, Free 플랜)
  │ Origin Pull (mTLS — 직타 차단)
  ▼
Lightsail 단일 인스턴스 (us-east-1, 4GB / 2 vCPU, Ubuntu 22.04)
  └─ docker compose
       ├─ nginx      (443 종단, 서브도메인 라우팅, 정적 서빙, 점검 flag)
       ├─ server     (9000, 4-in-1 모놀리스 — REST + WebSocket + 게임루프 + flush)
       └─ postgres   (5432, loopback 전용, /mnt/pgdata 전용 디스크)
```

핵심 세 가지:

- **단일 프로세스**다. 구 4앱(api/socket/worker/flush)과 Redis가 2026-07에 `apps/server/main.ts` 하나로 통합됐다. REST와 WebSocket이 **같은 HTTP 서버·같은 포트**를 쓰고, worker/flush는 같은 이벤트 루프의 `setInterval`이다.
- **Redis는 제거됐다.** 활성 게임 상태는 이제 **프로세스 힙**(`lib/state/*`의 `Map`/`Set`)에 있다. 재시작하면 사라진다.
- **수평 확장 불가**(현 코드 기준). state 스토어가 전부 프로세스-로컬 `Map`이라 단일 프로세스를 전제한다. 데이터 파이프라인을 설계할 때 "여러 인스턴스에서 이벤트가 온다"를 가정하지 말 것.

### 1-2. 데이터 3계층

| 계층 | 실체 | 영속성 | 분석 가치 |
| --- | --- | --- | --- |
| **힙 (ephemeral)** | `lib/state/*` — 유저 위치·동접 슬롯·야생 포켓몬·conn 토큰·OAuth state | 재시작 시 **소멸** | 없음 (스냅샷만 가능) |
| **PostgreSQL (진실)** | 10개 테이블. 계정·자산·감사로그 | ACID, 디스크, R2 백업 | **전부 여기** |
| **파일 로그** | winston → 컨테이너 `logs/%DATE%.log` | 14일 (에러 30일), 컨테이너 재생성 시 소멸 | 낮음 (구조화 약함, 배포마다 초기화) |
| **마스터 데이터** | `lib/master/*.csv`, `*.json` (아이템·포켓몬·맵) | git 관리, 이미지에 포함 | 조인용 디멘션 테이블 |

### 1-3. 쓰기 경로 — 세 갈래

```
① 도메인 변이 (아이템 구매·포획·진화…)
   클라 → REST → 서비스 tx { 자산 UPDATE + auditTx(INSERT) } → PG 커밋
   └─ 원자적. 자산 변경과 감사 로그가 같은 트랜잭션.

② 컨트롤러 태깅 (로그인·가방 등록·사파리 bait…)
   컨트롤러가 request.audit = {...} 세팅
   → Fastify onResponse hook이 statusCode < 400 일 때만 auditAsync(INSERT)
   └─ best-effort. 별도 tx. 실패해도 응답엔 영향 없음(logger.error만).

③ 실시간 위치 (write-back cache)
   소켓 move → 힙 Map 갱신 + dirty Set 추가
   → 33ms tick으로 같은 방에 브로드캐스트 (DB 안 감)
   → 180초마다 position-flush가 dirty만 PG로 write-back
   → disconnect 시 즉시 flush
   └─ 최대 3분치 위치 유실 허용. 자산은 이 경로를 안 탄다.
```

---

## 2. PostgreSQL 스키마 카탈로그

10개 테이블. 전부 `server/lib/schema/*.ts`(Drizzle) 정의.

### 2-1. 엔티티 (자산 = 현재 상태 스냅샷)

| 테이블 | PK | 성격 | 분석 포인트 |
| --- | --- | --- | --- |
| `account` | `id` (serial) | 인증 주체. `provider`+`provider_id` 유니크 | `deleted_at`으로 소프트 삭제. `last_login_at` 갱신됨 |
| `user` | `account_id` (=account 1:1) | 게임 프로필 | `money`, `playtime`(초 누적), `last_map_id/x/y`, `has_starter` |
| `user_pokemon` | `id` (serial) | **행 = 개체 하나**. 가장 큰 테이블이 될 것 | `caught_at`, `caught_location`, `tier`, `is_shiny`, `level/exp`, `box_number/grid_number/party_slot` |
| `user_item` | (`account_id`,`item_id`) | 수량 원장 | `quantity >= 0` CHECK. 변화량은 원장이 아니라 `audit_log`로만 추적 가능 |
| `user_pokedex` | (`account_id`,`pokedex_id`) | 도감 | `caught_count` 누적, `registered_at` = 최초 등록 |
| `user_costume` | (`account_id`,`costume_id`) | 코스튬 보유/장착 | 신규 부여 API가 사실상 없음 |
| `user_town_map` | (`account_id`,`map_id`) | 사파리존 방문 기록 | `visited_at` = 최초 방문. flush 경로로 기록 |
| `user_box_meta` | (`account_id`,`box_number`) | PC 박스 이름/배경 | 분석 가치 낮음 |

> **중요**: 이 테이블들은 전부 **현재 상태**다. "언제 얼마나 변했는가"의 이력은 오직 `audit_log`에만 있고, 그것도 60일치뿐이다. 잔고 시계열이 필요하면 **스냅샷을 따로 떠야 한다**(§8 백로그).

### 2-2. 인프라 테이블

| 테이블 | 용도 | 주의 |
| --- | --- | --- |
| `session` | 로그인 세션 (구 Redis `session:{uuid}` 대체) | ⛔ **`session.id`는 살아있는 인증 토큰 그 자체.** 읽는 순간 계정 탈취 가능. 어떤 export에도 절대 포함 금지 |
| `audit_log` | **유일한 이벤트 스트림** | §3 전부 |

### 2-3. 카스케이드와 고아 행

`account`를 제외한 모든 유저 테이블이 `account_id`에 `ON DELETE CASCADE` FK를 건다. 그런데 **`audit_log.account_id`에는 FK가 없다**(`integer`, nullable, 참조 없음).

→ 계정을 하드 삭제하면 자산 행은 전부 사라지지만 **감사 로그는 남는다**(60일 prune 전까지). 조인 시 `audit_log LEFT JOIN account`에서 NULL이 나올 수 있다는 뜻이고, 이건 버그가 아니라 감사 로그의 의도된 성질이다. 다만 실제 삭제 경로는 소프트 삭제(`account.deleted_at`)라 대부분의 경우엔 조인이 성립한다.

---

## 3. `audit_log` — 이 프로젝트의 이벤트 스트림

분석 업무의 90%는 이 테이블에서 나온다. 정확히 알아야 한다.

### 3-1. 스키마

```sql
audit_log (
  id          bigserial PRIMARY KEY,        -- 단조 증가. 커서 기반 증분 추출 키로 쓸 것
  account_id  integer,                      -- FK 없음, NULL 가능(로그인 실패 등)
  action      varchar(64)  NOT NULL,        -- AuditAction enum 문자열
  status      smallint,                     -- HTTP 상태 (성공 2xx / 실패 4xx)
  detail      jsonb,                        -- 액션별 페이로드 (스키마 §3-4)
  ip          varchar(45),                  -- ⛔ PII. 외부 공유 시 반드시 제외
  user_agent  varchar(512),                 -- 준식별자
  source      varchar(16)  NOT NULL,        -- 'api' | 'socket'
  created_at  timestamptz  NOT NULL DEFAULT now()
)
INDEX idx_audit_created          (created_at)
INDEX idx_audit_account_created  (account_id, created_at)
```

**증분 추출은 `id` 커서로.** `created_at`은 인덱스가 있지만 동시 트랜잭션 커밋 순서 때문에 경계에서 누락 가능성이 있고, `id`는 bigserial 단조 증가라 `WHERE id > :last_id ORDER BY id` 가 가장 싸고 안전하다.

### 3-2. 기록 경로 3종 — 신뢰도가 다르다

| 경로 | 코드 | 트랜잭션 | 실패 시 | 신뢰도 |
| --- | --- | --- | --- | --- |
| **`auditTx(tx, ...)`** | 도메인 서비스 내부 | ✅ 자산 변이와 **같은 tx** | 변이 전체 롤백 | **높음.** "자산이 바뀌었으면 로그가 반드시 있다" |
| **`request.audit` + onResponse hook** | 컨트롤러 태깅 → `apps/api/app.ts` | ❌ 별도 tx | `logger.error`만, 조용히 유실 | 중간. best-effort |
| **onError hook** | `apps/api/app.ts` | ❌ | 〃 | 중간. 실패 이벤트 전용 |

`auditTx`를 쓰는 액션(= 원장 신뢰 가능): `ITEM_BUY`, `ITEM_SELL`, `SAFARI_TICKET_CLAIM`, `POKEMON_CATCH`, `POKEMON_SELL`, `POKEMON_EVOLVE`, `POKEMON_ENHANCE`, `POKEMON_UPGRADE`, `POKEMON_LEARN_MOVE`, `FOSSIL_RESTORE`, `SAFARI_ENTER`.

나머지는 hook 경로다.

### 3-3. ⚠️ 커버리지 갭 — 반드시 알아야 할 3가지

**(1) 실패한 변이는 기록되지 않는다.**
onResponse hook은 `if (reply.statusCode >= 400) return;` 로 4xx/5xx를 버린다. `auditTx` 경로는 tx가 롤백되면서 로그도 같이 사라진다.
→ **`audit_log`는 성공 이벤트 로그다.** "돈이 부족해서 구매 실패한 횟수" 같은 지표는 이 테이블로 구할 수 없다.

예외는 딱 두 액션 — `onError` hook이 잡는 `LOGIN_FAILED`(인증 실패)와 `REQUEST_REJECTED`. 그것도 **뮤테이션 메서드(POST/PUT/PATCH/DELETE)** 이고 **에러 코드가 화이트리스트 7종**(`FAILED_ACCOUNT`, `DTO_INVALID`, `SESSION_MISSING`, `SESSION_EXPIRED`, `OAUTH_INVALID_STATE`, `POKEMON_NOT_OWNED`, `ITEM_NOT_OWNED`)에 들 때만이다.

**(2) 정의됐지만 절대 발생하지 않는 액션 3종.**

| 액션 | 상태 |
| --- | --- |
| `POKEMON_ARRANGE` | 컨트롤러에서 **주석 처리** (`pokemon.controller.ts:54`) |
| `SAFARI_EXIT` | 컨트롤러에서 **주석 처리** (`safari.controller.ts:46`) |
| `PET_CHANGE` | 소켓 핸들러에서 **주석 처리** (`apps/socket/app.ts:582`) |

→ 이 3개로 지표를 짜면 **영원히 0**이다. 특히 `SAFARI_EXIT` 부재 때문에 "사파리 체류시간"은 `SAFARI_ENTER` ~ 다음 이벤트로 **추정**할 수밖에 없다.

**(3) 소켓 이벤트는 `MAP_CHANGE` 하나뿐.**
이동(`move`)은 33ms tick으로 초당 수십 건이라 **의도적으로 감사하지 않는다**. 접속/종료(`connect`/`disconnect`)도 감사 이벤트가 아니다.
→ **세션 시작·종료 이벤트가 없다.** DAU는 `LOGIN_*`으로, 플레이 시간은 `user.playtime`(누적 초, flush가 가산)으로 대신 구해야 한다.

### 3-4. `detail` jsonb 스키마 — 액션별 실측 페이로드

`detail`은 스키마가 강제되지 않는 자유 jsonb다. 아래가 코드에서 실제로 넣는 키다.

**인증 / 계정** (`source='api'`)

| action | detail |
| --- | --- |
| `REGISTER_LOCAL` | `{ username }` |
| `LOGIN_LOCAL` | `{ username }` |
| `LOGIN_OAUTH` | `{ provider, providerId }` ⛔ providerId = 직접 식별자 |
| `LOGOUT` | `null` |
| `DELETE_AUTH` | `null` |
| `CREATE_USER` | `{ nickname, gender }` |

**아이템 / 경제**

| action | detail |
| --- | --- |
| `ITEM_BUY` | `{ item, quantity, totalCost, money }` ← `money`는 **거래 후 잔고** |
| `ITEM_SELL` | `{ item, quantity, totalGain, money }` |
| `ITEM_GIVE_HOLD` | `{ userPokemonId, heldItem }` |
| `ITEM_TAKE_HOLD` | `{ userPokemonId }` |
| `ITEM_REGISTER` / `ITEM_UNREGISTER` | `{ itemId }` |
| `SAFARI_TICKET_CLAIM` | `{ claimed, quantity }` |

**포켓몬**

| action | detail |
| --- | --- |
| `POKEMON_CATCH` | `{ userPokemonId, pokedexId, level, isShiny, mapId, isS000Starter }` |
| `POKEMON_SELL` | 판매 항목별로 **행이 여러 개** 생성됨(루프에서 `auditTx`) |
| `POKEMON_EVOLVE` | `{ userPokemonId, fromPokedexId, toPokedexId, cost }` |
| `POKEMON_UPGRADE` | `{ userPokemonId, pokedexId, fromTier, toTier, candyId, candyCost }` |
| `POKEMON_ENHANCE` | `{ userPokemonId, expGain, fromLevel, toLevel, exp }` |
| `POKEMON_LEARN_MOVE` | `{ userPokemonId, move, pokedexId }` |

**사파리 / 화석**

| action | detail |
| --- | --- |
| `SAFARI_ENTER` | `{ mapId, ticketConsumed, ballsGranted }` |
| `SAFARI_PICK_ITEM` | `{ uid, itemId }` |
| `SAFARI_BAIT` / `SAFARI_ROCK` | `{ uid, result }` |
| `FOSSIL_RESTORE` | `{ recipeId, userPokemonId, pokedexId, level, isShiny }` |

**소켓 / 실패**

| action | detail |
| --- | --- |
| `MAP_CHANGE` (`source='socket'`) | `{ from, to, x, y }` |
| `LOGIN_FAILED` | `{ method, url, errorCode, body }` — `body`는 `redactBody()` 통과본 |
| `REQUEST_REJECTED` | 동일 |

> `uid`(사파리 야생/아이템 식별자)는 **힙에만 존재하는 휘발성 ID**다. 서버 재시작 후에는 아무것도 참조하지 않는다. `SAFARI_BAIT`의 `uid`로 `POKEMON_CATCH`를 조인하려 들지 말 것 — 같은 프로세스 생애 안에서만 유효하고, `POKEMON_CATCH`의 detail엔 애초에 `uid`가 없다.

### 3-5. ⛔ PII — 작업 전 반드시 숙지

`audit_log`는 **이 프로젝트에서 PII 밀도가 가장 높은 테이블**이다. `ip` + `user_agent` + `created_at`이 한 행에 다 있어 조합하면 개인 재식별이 가능하다.

| 컬럼 | 등급 | 외부 공유 시 |
| --- | --- | --- |
| `ip` | 준식별자 (모든 행) | **항상 제외** |
| `user_agent` | 준식별자 (핑거프린팅) | 알고서 포함하기로 결정됨 |
| `detail` | 액션에 따라 **직접 식별자 포함** | 아래 두 액션 주의 |
| `account_id` | 가명 식별자 | 집계만 할 거면 `md5(account_id || salt)`로 해싱 권장 |

**`detail`에서 실제로 새는 것:**

- `LOGIN_FAILED.detail.body.username` — 로그인 **실패 시도의 아이디 평문**. `redactBody()`가 비밀번호는 가리지만 아이디는 남긴다.
- `REQUEST_REJECTED.detail.url` — 쿼리스트링 포함. OAuth 콜백이 GET이라 **authorization code**가 실릴 수 있다(일회용·단명).

`redactBody()`의 한계(`lib/utils/audit.ts`): 가리는 키는 `password / newPassword / token / accessToken / refreshToken / secret` **6개, 최상위 레벨만**. 중첩 객체 미처리, `detail.url` 미대상, `idToken`·`code` 누락.

→ 외부/공유용 추출은 **반드시 `ip`를 뺀 컬럼 목록을 명시**하거나 아래 뷰를 쓴다. `SELECT *` 금지.

```sql
CREATE VIEW audit_log_ro AS
SELECT id, account_id, action, status, detail, user_agent, source, created_at
FROM audit_log;
```

> ⚠️ 이 프로젝트는 versioned migration 없이 수동 `drizzle-kit push`로 스키마를 반영한다. push가 `audit_log`를 drop/recreate 하면 **뷰도 같이 사라진다.** "뷰가 없다"가 나오면 위 DDL 재실행.

전체 절차(마스킹 근거, CSV export, 읽기전용 롤, Tailscale 접근)는 **`docs/audit-log-readonly-access.md`** 가 정본이다.

---

## 4. 데이터 수명 — 언제 사라지는가

| 데이터 | 보존 | 삭제 주체 |
| --- | --- | --- |
| `audit_log` | **60일** | `janitor.ts` `AUDIT_RETENTION_DAYS=60`, `dailyPrune` (24h 주기 + **부팅 시 1회**) |
| `session` (만료분) | 만료 즉시 | 같은 `dailyPrune` |
| 자산 테이블 | 무기한 | 계정 삭제 시 CASCADE |
| winston `logs/*.log` | 14일 (에러 30일, gzip) | `winston-daily-rotate-file`. 컨테이너 재생성 시 소멸 |
| PG 논리 백업 (R2) | **30일** | R2 lifecycle. 6시간 주기 `pg_dump` (RPO 6h / RTO 1h) |
| Lightsail 스냅샷 | 7일 | 자동 스냅샷 (매일 04:00 KST) |
| 힙 상태 | 프로세스 수명 | 재시작/배포마다 소멸 |

**핵심 함의**: 배포는 자주 일어나고(main push → 90초 점검 배포), 배포는 컨테이너를 재생성한다. 따라서

- 애플리케이션 로그는 **배포마다 초기화**된다 → 장기 분석에 쓸 수 없다.
- `dailyPrune`은 부팅 시 1회 실행되므로, 잦은 배포 환경에서도 정상 동작한다(과거엔 24h 타이머만 있어 영영 안 돌던 버그가 있었고 수정됨).
- **60일 넘는 히스토리가 필요하면 지금부터 정기 추출을 시작해야 한다.** 아무도 안 해두면 그냥 없다.

---

## 5. 실시간 상태(힙) — 분석 대상이 아니지만 알아야 하는 것

`lib/state/*`. 전부 프로세스-로컬 자료구조다.

| 스토어 | 자료구조 | 내용 | PG로 가나 |
| --- | --- | --- | --- |
| `user-state` | `Map<authId, UserState>` | 위치·닉네임·코스튬·펫·socketId·visitedMaps | ✅ 3분 flush + disconnect |
| `dirty` | `Set<authId>` | flush 대상 마킹 | — |
| `connection` | `Set` + `Map` | 동접 슬롯(`SLOT_CAPACITY` 기본 50), conn 토큰(30초), OAuth state(10분), grace(30초) | ❌ |
| `room` | `Map<mapId, Set>` | 맵별 접속 유저 | ❌ |
| `wild-store` | 중첩 `Map` | 유저별·맵별 야생 포켓몬(TTL 90~300초, shiny는 영구), 사파리 아이템 | ❌ |
| `game-time`, `weather` | 단일 객체 | 게임 시간 위상(dawn/day/dusk/night), 날씨(5~15분) | ❌ |

**야생 스폰·날씨·게임시간은 어떤 로그도 남기지 않는다.** "이번 주 어떤 날씨에 어떤 포켓몬이 많이 잡혔나"를 물으면, 날씨 쪽 팩트가 없어서 답할 수 없다. 잡힌 결과(`POKEMON_CATCH`)만 있다. 이건 알려진 갭이고 §8 백로그 1순위 후보다.

동접 수는 힙에 있고 스냅샷 API 하나로만 노출된다:

```bash
docker exec poposerver_server wget -qO- http://127.0.0.1:9000/api/game/online
# → {"success":true,"data":{"count":N}}   (5초 캐시, 인증 불필요)
```

**이력이 없다.** 어제 피크 동접을 물으면 답이 없다.

---

## 6. 마스터 데이터 (디멘션 테이블)

`server/lib/master/`에 있고 부팅 시 `MasterData.load()`가 메모리에 적재한다. DB 테이블이 **아니다** — 조인하려면 파일을 따로 읽어야 한다.

| 파일 | 내용 | 조인 키 |
| --- | --- | --- |
| `item.csv` | 아이템 마스터(가격·카테고리) | `audit_log.detail->>'item'`, `user_item.item_id` |
| `pokemon.csv` | 전국도감(종·타입·티어·base_exp·스킬) | `user_pokemon.pokedex_id`, `detail->>'pokedexId'` |
| `map/<id>.json` | 맵별 야생 출현표(시간×날씨 16조합) | `caught_location`, `detail->>'mapId'` |
| `map-entry.json` | 맵 진입점 | — |

**⚠️ 조인 시 ID 포맷 함정**: 서버 CSV는 기본 폼을 **plain integer**(`1`, `4`)로 쓰는데, 클라이언트/`map.json`/스타터 목록은 **4자리 zero-padded**(`0001`, `0004`)를 쓴다. `MasterData.getPokemon`이 런타임에 두 포맷을 fallback 매칭해주지만, **SQL로 직접 조인하면 안 맞는다.** 조인 전에 정규화할 것.

**⚠️ 파일 인코딩 함정**: `pokemon.csv`는 **CRLF**, `pokemon.json`은 **LF**다. 재작성 시 `lineterminator`에 주의하고, 두 파일을 `splitlines()`로 비교하지 말 것.

---

## 7. 데이터에 접근하는 법

### 7-1. 기본 경로 — CSV export (권장)

정본 절차: **`docs/audit-log-readonly-access.md`**. 요지만:

1. DataGrip에서 prod(SSH 터널) 커넥션으로 붙는다.
2. `audit_log_ro` 뷰 생성(1회) → `SELECT * FROM audit_log_ro WHERE created_at > now() - interval '7 days' ORDER BY id;`
3. 결과 그리드 → Export Data → CSV (Excel로 열 거면 **UTF-8 BOM** 켤 것).
4. 이후 탐색은 전부 로컬에서.

**왜 실시간 접근이 기본이 아닌가** — 보안(노출 범위가 파일 하나로 고정)도 있지만 **성능이 실질적**이다. prod PG는 게임 서버와 **같은 4GB 박스·같은 디스크**를 쓴다. Lightsail은 버스터블 인스턴스라 무거운 집계를 **반복** 실행하면 CPU 버스트 크레딧이 고갈되고 베이스라인으로 떨어져 **게임 전체가 느려진다.** 일회성 스캔은 괜찮고 반복이 위험하다.

**쿼리 위생 규칙 (반드시)**

- `WHERE created_at > now() - interval '7 days'` — 기간 필터 필수. 30일 한 번보다 **7일씩 여러 번**이 총 부하가 낮다(범위가 전체의 5~10%를 넘으면 플래너가 순차 스캔으로 바꾼다).
- `ORDER BY id` — `created_at` 정렬보다 PK 순서가 싸다.
- 동접 적은 새벽에.
- 실시간 롤을 받았다면 `statement_timeout = 30s`는 절대 풀지 말 것.

### 7-2. 정기 자동화

`server/scripts/ops/backup-pg.sh`가 이미 R2 업로드 경로(`aws --profile r2`, `.env.backup`)를 갖췄다. 정기 CSV 적재가 필요하면 `psql \copy` 한 줄을 cron에 걸고 이 경로를 재활용하는 게 가장 단순하다.

```bash
docker exec poposerver_postgres psql -U "$DB_USERNAME" -d "$DB_DATABASE" -c "\copy ( \
  SELECT id, account_id, action, status, detail, user_agent, source, created_at \
  FROM audit_log WHERE created_at > now() - interval '7 days' ORDER BY id \
) TO STDOUT WITH CSV HEADER" > ~/audit_7d.csv
```

### 7-3. 실시간 SQL 접근이 꼭 필요할 때

Tailscale(WireGuard mesh VPN)로 `100.64.0.0/10` 사설 대역에 5432를 바인딩 + `audit_log_ro` 뷰 하나만 GRANT한 읽기전용 롤. 절차/검증/회수는 `audit-log-readonly-access.md` **부록 A**에 전부 있다.

넘기기 전 8개 검증(뷰는 OK, 베이스 테이블·`session`·`account`·`user`는 permission denied)을 반드시 통과시킬 것. **`~/.ssh/poposafari.pem` 공유 금지**(그 키의 `ubuntu`는 `docker` 그룹 = 사실상 root).

---

## 8. 분석 쿼리 레시피

전부 `audit_log_ro` 뷰 또는 마스킹된 컬럼 목록 기준. 기간 필터 포함.

**일별 활성 계정 (DAU 근사)**

```sql
SELECT date_trunc('day', created_at) AS d,
       count(DISTINCT account_id)    AS dau
FROM audit_log_ro
WHERE created_at > now() - interval '30 days'
  AND account_id IS NOT NULL
GROUP BY 1 ORDER BY 1;
```

> 세션 시작 이벤트가 없어서 "모든 액션 중 하나라도 남긴 계정"으로 근사한다. 로그인만 하고 아무것도 안 한 유저는 `LOGIN_*`로 잡히니 실질적으로 커버된다.

**신규 유입 퍼널 (가입 → 캐릭터 생성 → 첫 포획)**

```sql
WITH f AS (
  SELECT account_id,
    min(created_at) FILTER (WHERE action IN ('REGISTER_LOCAL','LOGIN_OAUTH')) AS t_signup,
    min(created_at) FILTER (WHERE action = 'CREATE_USER')                     AS t_avatar,
    min(created_at) FILTER (WHERE action = 'POKEMON_CATCH')                   AS t_catch
  FROM audit_log_ro
  WHERE created_at > now() - interval '30 days'
  GROUP BY account_id
)
SELECT count(*) FILTER (WHERE t_signup IS NOT NULL) AS signup,
       count(*) FILTER (WHERE t_avatar IS NOT NULL) AS avatar,
       count(*) FILTER (WHERE t_catch  IS NOT NULL) AS first_catch
FROM f;
```

> `LOGIN_OAUTH`는 신규/재로그인 구분이 없다(같은 액션). 정확한 신규는 `account.created_at`을 봐야 하는데 그건 별도 테이블 권한이 필요하다.

**경제 — 재화 faucet / sink**

```sql
SELECT date_trunc('day', created_at) AS d,
       sum((detail->>'totalGain')::bigint) FILTER (WHERE action='ITEM_SELL') AS faucet,
       sum((detail->>'totalCost')::bigint) FILTER (WHERE action='ITEM_BUY')  AS sink
FROM audit_log_ro
WHERE action IN ('ITEM_BUY','ITEM_SELL')
  AND created_at > now() - interval '30 days'
GROUP BY 1 ORDER BY 1;
```

> 이 두 액션은 `auditTx` 경로(자산 변이와 같은 tx)라 **누락이 없다**. 경제 지표 중 가장 신뢰할 수 있다. `detail->>'money'`가 거래 후 잔고라, 유저별 잔고 시계열도 여기서 복원 가능하다 — `user.money` 스냅샷 없이도.

**포획 분포 (맵 × 이로치 × 티어)**

```sql
SELECT detail->>'mapId'                          AS map_id,
       count(*)                                  AS catches,
       count(*) FILTER (WHERE (detail->>'isShiny')::boolean) AS shiny,
       round(avg((detail->>'level')::int), 1)    AS avg_level
FROM audit_log_ro
WHERE action = 'POKEMON_CATCH'
  AND created_at > now() - interval '14 days'
  AND coalesce((detail->>'isS000Starter')::boolean, false) = false
GROUP BY 1 ORDER BY catches DESC;
```

> `isS000Starter=true`는 튜토리얼 강제 성공 포획이라 확률 분석에서 **반드시 제외**해야 한다.
>
> ⚠️ **이건 분자만 센다.** `CatchResult`는 `'caught' | 'fail' | 'flee'` 3값인데 `auditTx`가
> `result === 'caught'` 분기 안에만 있다(`safari.service.ts:299,400`). 실패·도주 시도는 어디에도 기록되지 않는다.
> → **포획률(성공/시도)은 현재 데이터로 구할 수 없다.** 볼 소모량(`ITEM_*`)으로 시도 횟수를 역산하는 우회도
> 정확하지 않다. 이건 계측을 고쳐야 풀리는 문제이고, 게임 밸런스 분석의 1순위 지표라 백로그 상위에 있어야 한다.

**사파리 세션 길이 (추정 — 정확한 값 아님)**

```sql
SELECT account_id, created_at AS entered,
       lead(created_at) OVER (PARTITION BY account_id ORDER BY created_at) - created_at AS gap
FROM audit_log_ro
WHERE action = 'SAFARI_ENTER' AND created_at > now() - interval '7 days';
```

> `SAFARI_EXIT`가 미배선(§3-3)이라 다음 진입까지의 간격일 뿐이다. **체류 시간이 아니다.** 진짜 체류 시간을 원하면 `SAFARI_EXIT` 주석 한 줄을 푸는 게 정답이다.

**맵 이동 그래프 (이탈 지점 탐색)**

```sql
SELECT detail->>'from' AS src, detail->>'to' AS dst, count(*) AS n
FROM audit_log_ro
WHERE action = 'MAP_CHANGE' AND created_at > now() - interval '7 days'
GROUP BY 1,2 ORDER BY n DESC LIMIT 50;
```

---

## 9. 함정 모음 — 데이터를 잘못 읽게 만드는 것들

| # | 함정 | 영향 |
| --- | --- | --- |
| 0 | **포획 시도의 분모 없음** | `auditTx`가 `result==='caught'` 분기 안에만 있어 `fail`/`flee`가 무기록. **포획률 계산 불가** — 밸런스 분석 최대 공백 |
| 1 | **실패 이벤트 부재** | `audit_log`는 성공 로그. 실패율/에러율 산출 불가(LOGIN_FAILED 제외) |
| 2 | **미배선 액션 3종** | `POKEMON_ARRANGE`/`SAFARI_EXIT`/`PET_CHANGE`는 영원히 0행 |
| 3 | **세션 이벤트 부재** | 접속/종료 로그 없음 → 세션 길이·동접 이력 불가 |
| 4 | **60일 하드 컷** | 그 이전 데이터는 물리적으로 없음. 리텐션 코호트 최대 60일 |
| 5 | **`detail` 스키마 무보증** | jsonb 자유형. 코드가 바뀌면 키가 조용히 바뀐다. 파싱은 방어적으로 |
| 6 | **`uid`는 휘발성** | 사파리 `uid`로 크로스-이벤트 조인 불가 |
| 7 | **pokedex_id 포맷 2종** | `1` vs `0001`. SQL 조인 전 정규화 필수 |
| 8 | **`pokemon.csv` CRLF** | 파싱/재작성 시 개행 혼용 주의 |
| 9 | **위치는 3분 지연** | `user.last_x/y`는 최대 3분 낡음. 실시간 위치 아님 |
| 10 | **`playtime` 멱등성 미보장** | flush의 `createdAt` 리셋이 tx **밖**이라 이론상 중복 가산 여지. "완전 정확"으로 단정하지 말 것 |
| 11 | **SERIAL 시퀀스 드리프트** | 명시적 id 시드/마이그레이션 이력이 있어 `account_id_seq` 등이 어긋난 전례가 있음. 데이터 삽입성 작업 시 주의 |
| 12 | **`staging-init.sql`은 낡음** | 옛 INTEGER 스키마. 현 DB(varchar)와 다르다. 스키마 참조는 `lib/schema/*.ts`가 정본 |
| 13 | **부하테스트 로그 무효** | `load-test/out`의 2026-06-12 측정치는 구 4앱+Redis 아키텍처 기준. 현 모놀리스 근거로 인용 금지 |
| 14 | **`docs/plan/` 빈 디렉토리** | 옛 메모가 가리키는 plan 문서 다수가 실체 없음 |

---

## 10. 지금 없는 것 — 개선 백로그

우선순위 순. 위로 갈수록 비용 대비 효과가 크다.

**① 미배선 이벤트 3종 활성화** — 주석 한 줄씩. `SAFARI_EXIT`만 켜도 사파리 체류시간이라는 지표 하나가 통째로 생긴다.

**② 세션 이벤트 추가** — 소켓 `connect`/`disconnect`에 감사 기록. DAU/세션길이/동접 이력이 전부 여기서 나온다. `disconnect` 핸들러엔 이미 flush 호출이 있으니 붙이기 쉽다.

**③ 60일 밖으로 나가는 정기 추출** — `id` 커서 기반 증분 CSV → R2. 백업 스크립트 경로 재활용. 이게 없으면 60일마다 히스토리가 리셋된다. **가장 시급한 건 사실 이것** — 다른 개선은 나중에 해도 데이터가 남지만, 이건 안 하면 지금 지나가는 데이터가 영영 사라진다.

**④ `redactBody()` 보강** — `REDACT_KEYS`에 `idToken`/`code` 추가, 중첩 재귀 처리, `detail.url` 쿼리스트링을 **저장 시점에** 절단(지금은 조회 시점 마스킹으로만 우회). `lib/utils/audit.ts`.

**⑤ 게임 월드 팩트 로깅** — 날씨/게임시간/스폰 이력. 지금은 어떤 기록도 없어서 밸런스 분석의 독립변수가 통째로 비어 있다.

**⑥ 잔고 스냅샷 잡** — `user.money`·`user_item.quantity`를 일 1회 스냅샷. `audit_log`의 `detail.money`로 부분 복원은 되지만 거래 없는 유저는 안 잡힌다.

**⑦ 메트릭/시계열** — 현재 `docker stats` 스냅샷 + Healthchecks.io dead-man's switch가 전부. 정식 출시 후 Netdata 등으로 승격 예정(4GB 박스 마진 때문에 의도적으로 미도입).

> 백로그 설계 원칙 하나: **가장 단순한 충분조건으로 간다.** 이 프로젝트는 1인 운영 + 4GB 단일 박스다. 큐·워커·dead-letter 같은 조기 인프라는 경계하고, 승격 경로만 명시해두는 쪽을 선호해왔다. 파이프라인 제안 시 이 톤을 맞추면 채택 확률이 높다.

---

## 부록 — 1차 소스 지도

| 알고 싶은 것 | 파일 |
| --- | --- |
| 테이블 정의 (정본) | `server/lib/schema/*.ts` |
| 이벤트 목록 | `server/lib/types/audit.type.ts` |
| 이벤트 기록 로직 / 마스킹 | `server/lib/utils/audit.ts` |
| hook 기반 기록 · 에러 처리 | `server/apps/api/app.ts` |
| 보존/prune | `server/apps/server/game-loop/janitor.ts` |
| 위치 write-back | `server/apps/server/flush/position-flush.ts`, `server/lib/user-state-persist.ts` |
| 힙 상태 | `server/lib/state/*.ts` |
| 인프라·백업·모니터링 실행 기록 | `docs/deployment_record.md` |
| audit_log 외부 공유 절차 (정본) | `docs/audit-log-readonly-access.md` |
| 복구 런북 | `docs/runbook-restore.md`, `docs/runbook-alerts.md` |
| ⚠️ 낡음 (참고 금지) | `server/docs/data-storage-strategy.md` (Redis 전제) |
