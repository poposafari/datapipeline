-- PopoSafari — 방어적 파싱 뷰
--
-- 계약 §1-4: server 레포는 detail 에 스키마 보증을 하지 않는다. 방어적 파싱은
-- 이쪽 책임이다. 여기서 **한 번만** 흡수하고 상위 뷰·레시피는 이 뷰만 본다.
-- json_extract_string 은 키가 없거나 detail 이 NULL/비객체면 NULL 을 돌려주고,
-- TRY_CAST 가 타입 불일치를 NULL 로 흡수한다 — 어떤 경우에도 예외로 죽지 않는다.
--
-- ★ 이 뷰는 **PII 경계**이기도 하다. 소스(archive-audit.sh 의 row_to_json)에는
--   ip 가 들어 있고 url 에는 쿼리스트링이, LOGIN_FAILED 에는 평문 username 이
--   들어 있다. ip 는 적재 단계(load/10_load_audit.sql)가 떨어뜨리고, 나머지 둘은
--   여기서 막는다. 계약 §1-3 이 "server 가 보장한다"고 적어둔 마스킹 3종은
--   실제 익스포터가 그렇게 만들어지지 않았다 — 책임이 전부 이쪽으로 넘어왔다.

CREATE OR REPLACE VIEW wh.audit_v AS
SELECT
  id, account_id, action, status, user_agent, source, created_at,
  -- source 는 'api' | 'socket' | 'worker'. worker 는 게임루프가 남기는 것으로
  -- (apps/server/game-loop/wild-spawn.ts) POKEMON_SPAWN 이 대부분이다.

  -- created_at 은 UTC 벽시계(TIMESTAMP)다. AT TIME ZONE 을 쓰면 안 된다 —
  -- 이미 UTC 로 정규화해 담았으므로 여기서 또 변환하면 세션 TZ 로 밀린다.
  created_at + INTERVAL 9 HOUR                                    AS created_at_kst,

  detail,

  -- ── 맵 ────────────────────────────────────────────────────────────
  -- SAFARI_ENTER / SAFARI_EXIT / POKEMON_CATCH* 는 detail.mapId 를 쓰지만
  -- MAP_CHANGE 는 {from,to,x,y} 라 mapId 가 아예 없다 (apps/socket/app.ts:617).
  -- map_id 는 "이 이벤트가 일어난 맵"으로 통일하고, 이동은 from/to 를 따로 둔다.
  --   ⚠️ SAFARI_EXIT 의 detail 은 {mapId: 나온 맵, to: 'p001'} 이다
  --      (safari.controller.ts:44). mapId 가 *떠난* 사파리 맵이라 체류시간
  --      페어링에서 그대로 쓸 수 있다.
  coalesce(json_extract_string(detail, '$.mapId'),
           json_extract_string(detail, '$.to'))                   AS map_id,
  json_extract_string(detail, '$.from')                           AS map_from,
  json_extract_string(detail, '$.to')                             AS map_to,

  -- ── 포켓몬 ────────────────────────────────────────────────────────
  -- ⚠️ pokedex_id 는 **VARCHAR 그대로** 둔다. 정수로 캐스팅하면 안 된다.
  --    user_pokemon.pokedex_id 가 varchar(20)이고, 스폰 소스인 map/*.json 의
  --    id 는 전부 패딩되어 있다("0016", "0058_hisui"). 정수 캐스팅은 변종 폼을
  --    전부 NULL 로 만들어 마스터 조인을 조용히 유실시킨다.
  --    wh.pokemon_dim 의 정규형과 같은 형식이라 그대로 조인된다.
  json_extract_string(detail, '$.pokedexId')                      AS pokedex_id,
  TRY_CAST(json_extract_string(detail, '$.level')   AS INTEGER)   AS level,
  TRY_CAST(json_extract_string(detail, '$.isShiny') AS BOOLEAN)   AS is_shiny,
  -- 튜토리얼 강제 포획. 확률 분석에서 반드시 제외해야 한다 — 100% 성공이고
  -- 샤이니가 강제되는 경로라 넣으면 포획률과 샤이니율이 통째로 왜곡된다.
  coalesce(TRY_CAST(json_extract_string(detail, '$.isS000Starter') AS BOOLEAN), false)
                                                                  AS is_starter,

  -- ── 사파리 조우 ───────────────────────────────────────────────────
  -- wild_uid 는 한 마리의 야생 개체를 가리키는 키다. 시도(POKEMON_CATCH_ATTEMPT)
  -- 와 실패(POKEMON_CATCH_FAIL)는 wildUid 를, 미끼/돌(SAFARI_BAIT/ROCK)은 uid 를
  -- 쓴다 — 같은 것이다.
  --   ⚠️ POKEMON_CATCH(성공)에는 wild uid 가 **없다**. detail 이
  --      {userPokemonId, pokedexId, level, isShiny, mapId, isS000Starter} 라
  --      새로 만들어진 소유 포켓몬 id 만 있다. 그래서 시도→성공을 행 단위로
  --      직접 이을 수 없고, views/20_metrics.sql 이 "실패가 안 붙은 시도"로
  --      성공을 역산한다. 그 근거와 한계는 거기 적혀 있다.
  coalesce(json_extract_string(detail, '$.wildUid'),
           json_extract_string(detail, '$.uid'))                  AS wild_uid,
  -- 미끼/돌 사용 여부. POKEMON_CATCH_ATTEMPT 만 갖고 있다 (safari.service.ts:562).
  -- 지표1(미끼·돌이 실제로 쓰이는가)의 분모가 여기서 나온다 — 사용 건수만으로는
  -- 비율을 낼 수 없기 때문이다.
  TRY_CAST(json_extract_string(detail, '$.bait') AS BOOLEAN)      AS used_bait,
  TRY_CAST(json_extract_string(detail, '$.rock') AS BOOLEAN)      AS used_rock,
  TRY_CAST(json_extract_string(detail, '$.partyBonus') AS DOUBLE) AS party_bonus,
  -- 실패 사유. 'flee' = 도망, 'break_out' = 볼에서 빠져나옴 (safari.service.ts:588).
  json_extract_string(detail, '$.reason')                         AS catch_reason,
  TRY_CAST(json_extract_string(detail, '$.fled') AS BOOLEAN)      AS catch_fled,
  -- SAFARI_BAIT / SAFARI_ROCK 의 결과. 'stay' = 남음, 'flee' = 도망.
  -- 미끼는 도주율 x0.5, 돌은 x1.5 다 (safari.service.ts applyBaitOrRock).
  -- 이 비율이 그 설계대로 나오는지가 지표1 의 검산이다.
  json_extract_string(detail, '$.result')                         AS flee_result,
  -- POKEMON_SPAWN / SAFARI_ITEM_SPAWN 의 배치 크기 (lib/utils/audit-safari.ts).
  -- detail 에 wilds[]/items[] 배열이 통째로 들어 있어 행이 무겁다 — 볼륨 관측용.
  TRY_CAST(json_extract_string(detail, '$.count') AS INTEGER)     AS spawn_count,
  -- SAFARI_TICKET_CLAIM 에서 **이번에 받은 장수**. quantity 는 받은 뒤 총 보유량이라
  -- 서로 다르다 (item.service.ts:94). 티켓 수지 계산은 이쪽을 써야 한다.
  TRY_CAST(json_extract_string(detail, '$.claimed') AS INTEGER)   AS ticket_claimed,

  -- ── 경제 ──────────────────────────────────────────────────────────
  -- money 는 **거래 후 잔고**다. user.money 스냅샷 없이도 유저별 잔고 시계열이
  -- 복원되는 근거이고, 잔고 스냅샷 잡이 보류인 이유다.
  TRY_CAST(json_extract_string(detail, '$.money') AS BIGINT)      AS money_after,
  json_extract_string(detail, '$.item')                           AS item_id,
  TRY_CAST(json_extract_string(detail, '$.quantity') AS INTEGER)  AS quantity,
  -- 금액 키가 비대칭이다: ITEM_BUY 는 totalCost, ITEM_SELL 은 totalGain.
  TRY_CAST(coalesce(json_extract_string(detail, '$.totalCost'),
                    json_extract_string(detail, '$.totalGain')) AS BIGINT)
                                                                  AS trade_amount,

  -- ── 요청 실패 계열 ────────────────────────────────────────────────
  -- ★ 쿼리스트링을 자른다. apps/api/app.ts:150 이 request.url 을 그대로 넣기
  --   때문에 OAuth code 같은 게 원본에 남아 있다. 계약은 server 가 자른다고
  --   적혀 있었지만 실제로는 안 자른다 — 여기가 유일한 방어선이다.
  --   원본이 필요하면 detail 컬럼을 직접 봐야 하고, 그건 의도적으로 불편하게 뒀다.
  split_part(json_extract_string(detail, '$.url'), '?', 1)        AS req_url,
  json_extract_string(detail, '$.method')                         AS req_method,
  json_extract_string(detail, '$.errorCode')                      AS error_code,
  -- ⚠️ body 하위 키는 노출하지 않는다. redactBody 의 REDACT_KEYS 에 username 이
  --    없어서 LOGIN_FAILED.detail.body.username 이 평문이다 (lib/utils/audit.ts:8).
  --    편의 컬럼으로 꺼내두면 아무 뷰에서나 새어 나간다.
  -- redactBody 가 2048B 초과 시 body 를 통째로 {_truncated:...} 로 치환한다.
  -- 그런 행은 body 하위 키가 없다 — 파서가 아니라 데이터의 성질이다.
  json_extract_string(detail, '$.body._truncated') IS NOT NULL    AS body_truncated

FROM wh.audit;
