-- PopoSafari — 방어적 파싱 뷰
--
-- 계약 §1-4: server 레포는 detail 에 스키마 보증을 하지 않는다. 방어적 파싱은
-- 이쪽 책임이다. 여기서 **한 번만** 흡수하고 상위 뷰·레시피는 이 뷰만 본다.
-- json_extract_string 은 키가 없거나 detail 이 NULL/비객체면 NULL 을 돌려주고,
-- TRY_CAST 가 타입 불일치를 NULL 로 흡수한다 — 어떤 경우에도 예외로 죽지 않는다.

CREATE OR REPLACE VIEW wh.audit_v AS
SELECT
  id, account_id, action, status, user_agent, source, created_at,

  -- created_at 은 UTC 벽시계(TIMESTAMP)다. AT TIME ZONE 을 쓰면 안 된다 —
  -- 원본에 tz 정보가 없어 세션 TZ 로 재해석되어 9시간 밀린다.
  created_at + INTERVAL 9 HOUR                                    AS created_at_kst,

  detail,

  -- ── 맵 ────────────────────────────────────────────────────────────
  -- SAFARI_ENTER / POKEMON_CATCH 는 detail.mapId 를 쓰지만
  -- MAP_CHANGE 는 {from,to,x,y} 라 mapId 가 아예 없다 (apps/socket/app.ts).
  -- map_id 는 "이 이벤트가 일어난 맵"으로 통일하고, 이동은 from/to 를 따로 둔다.
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
  -- 튜토리얼 강제 포획. 확률 분석에서 반드시 제외해야 한다 (온보딩 §8-④).
  coalesce(TRY_CAST(json_extract_string(detail, '$.isS000Starter') AS BOOLEAN), false)
                                                                  AS is_starter,

  -- catch_result: POKEMON_CATCH 에는 result 가 없다. auditTx 가 result='caught'
  -- 분기 안에만 있어서 성공만 기록된다 — 분모가 없다. server S2-2
  -- (POKEMON_CATCH_ATTEMPT) 배포 후에 아래 주석을 풀 것.
  -- json_extract_string(detail, '$.result')                      AS catch_result,

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
  json_extract_string(detail, '$.url')                            AS req_url,
  json_extract_string(detail, '$.errorCode')                      AS error_code,
  -- redactBody 가 2048B 초과 시 body 를 통째로 {_truncated:...} 로 치환한다.
  -- 그런 행은 body 하위 키가 없다 — 파서가 아니라 데이터의 성질이다.
  json_extract_string(detail, '$.body._truncated') IS NOT NULL    AS body_truncated

FROM wh.audit;
