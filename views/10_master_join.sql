-- PopoSafari — 마스터 정규화 뷰
--
-- ★ pokedex_id 포맷 함정 — 이 파이프라인 최대의 조용한 실패 지점.
--
--   pokemon.csv 의 id 컬럼은 **형식이 섞여 있다**:
--     · 기본형 → 평문 정수      "1", "16", "1025"
--     · 변종   → 패딩된 합성 id  "0003-mega", "0058_hisui", "0052_galar"
--   반면 map/*.json 의 스폰 id 와 user_pokemon.pokedex_id(varchar(20)),
--   즉 audit detail.pokedexId 는 **전부 패딩 형식**이다.
--
--   따라서 정규형은 정수가 아니라 **패딩 문자열**이어야 한다.
--   TRY_CAST(id AS INTEGER) 로 정규화하면 변종 행이 전부 NULL 이 되고,
--   audit 쪽 "0058_hisui" 도 NULL 이 되어 조인이 통째로 사라진다.
--
--   정규화 규칙의 정본은 server 레포 lib/master/csv_to_json.py:48-52 다:
--       s.zfill(4) if s.isdigit() else s
--   아래 CASE 가 그것과 동일하다.
--
-- ⚠️ 마스터 CSV 는 CRLF 다. DuckDB 가 대개 처리하지만 마지막 컬럼에 \r 이
--    남는 경우가 있어 쓰는 컬럼마다 rtrim(col, chr(13)) 을 건다.

CREATE OR REPLACE VIEW wh.pokemon_dim AS
WITH s AS (
  SELECT rtrim(id, chr(13)) AS raw_id, * EXCLUDE (id)
  FROM wh.master_pokemon
)
SELECT
  CASE WHEN regexp_full_match(raw_id, '^[0-9]+$')
       THEN lpad(raw_id, 4, '0') ELSE raw_id END        AS pokedex_id,   -- 정규형
  raw_id                                                AS pokedex_id_raw,
  TRY_CAST(raw_id AS INTEGER)                           AS pokedex_num,  -- 기본형만. 정렬용
  rtrim(comment, chr(13))                               AS name_ko,
  rtrim(type1, chr(13))                                 AS type1,
  nullif(rtrim(type2, chr(13)), '')                     AS type2,
  rtrim(tier, chr(13))                                  AS tier,
  rtrim(generation, chr(13))                            AS generation,
  rtrim(growth_group, chr(13))                          AS growth_group,
  TRY_CAST(rtrim(rate_capture, chr(13)) AS DOUBLE)      AS rate_capture,
  TRY_CAST(rtrim(rate_flee,    chr(13)) AS DOUBLE)      AS rate_flee,
  TRY_CAST(rtrim(height_m,     chr(13)) AS DOUBLE)      AS height_m,
  TRY_CAST(rtrim(weight_kg,    chr(13)) AS DOUBLE)      AS weight_kg,
  TRY_CAST(rtrim(base_exp,     chr(13)) AS INTEGER)     AS base_exp
FROM s;

-- item.csv 의 id 는 슬러그("safari-ball")라 패딩 문제가 없다.
-- 불리언은 CSV 에 대문자 문자열 TRUE/FALSE 로 들어 있다.
CREATE OR REPLACE VIEW wh.item_dim AS
WITH s AS (
  SELECT rtrim(id, chr(13)) AS item_id, * EXCLUDE (id)
  FROM wh.master_item
)
SELECT
  item_id,
  rtrim(comment, chr(13))                               AS name_ko,
  rtrim(category, chr(13))                              AS category,
  rtrim(tier, chr(13))                                  AS tier,
  TRY_CAST(rtrim(buy,  chr(13)) AS BIGINT)              AS buy_price,
  TRY_CAST(rtrim(sell, chr(13)) AS BIGINT)              AS sell_price,
  upper(rtrim(purchasable, chr(13))) = 'TRUE'           AS purchasable,
  upper(rtrim(sellable,    chr(13))) = 'TRUE'           AS sellable
FROM s;
