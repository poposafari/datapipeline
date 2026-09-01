-- 포획률 — 시도 대비 결과
--
-- 분모는 POKEMON_CATCH_ATTEMPT, 결과는 액션 이름으로 갈린다.
-- s000(튜토리얼)은 뷰에서 이미 제외되어 있다 — 강제 성공이라 넣으면 왜곡된다.
--
-- caught_gap 을 같이 내보낸다. POKEMON_CATCH 에 wildUid 가 없어서 성공을
-- "실패가 안 붙은 시도"로 역산하는데, 그 역산 오차가 이 값이다.
-- 0 근처가 정상이고 크게 벌어지면 지표가 아니라 서버를 봐야 한다.

WITH m AS (
  SELECT d_kst, attempts, users, caught, fled, broke_out,
         catch_rate, flee_rate, break_out_rate,
         attempts_bait, attempts_rock, attempts_plain,
         catch_rate_bait, catch_rate_rock, catch_rate_plain,
         caught_observed, caught_gap
  FROM wh.catch_rate_daily
),
b AS (SELECT max(d_kst) AS hi, greatest(min(d_kst), max(d_kst) - 89) AS lo FROM m),
spine AS (
  SELECT unnest(generate_series((SELECT lo FROM b), (SELECT hi FROM b),
                                INTERVAL 1 DAY))::DATE AS d_kst
)
SELECT
  s.d_kst::VARCHAR                 AS d,
  coalesce(m.attempts, 0)          AS attempts,
  coalesce(m.users, 0)             AS users,
  coalesce(m.caught, 0)            AS caught,
  coalesce(m.fled, 0)              AS fled,
  coalesce(m.broke_out, 0)         AS broke_out,
  round(m.catch_rate, 4)           AS catch_rate,
  round(m.flee_rate, 4)            AS flee_rate,
  round(m.break_out_rate, 4)       AS break_out_rate,
  coalesce(m.attempts_bait, 0)     AS attempts_bait,
  coalesce(m.attempts_rock, 0)     AS attempts_rock,
  coalesce(m.attempts_plain, 0)    AS attempts_plain,
  round(m.catch_rate_bait, 4)      AS catch_rate_bait,
  round(m.catch_rate_rock, 4)      AS catch_rate_rock,
  round(m.catch_rate_plain, 4)     AS catch_rate_plain,
  coalesce(m.caught_observed, 0)   AS caught_observed,
  coalesce(m.caught_gap, 0)        AS caught_gap
FROM spine s LEFT JOIN m USING (d_kst)
ORDER BY 1;
