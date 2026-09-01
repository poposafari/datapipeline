-- 지표1 — 미끼(BAIT) / 돌(ROCK) 사용
--
-- 최근 90일 일별 시계열. 기간 토글(7/30/90)은 클라이언트가 이 배열을 잘라 쓴다.
-- 서버가 없으므로 매번 다시 굽는 것보다 한 번에 다 굽고 브라우저가 자르는 게 싸다.
--
-- 날짜 스파인을 만들어 **빈 날도 0으로 채운다.** 안 채우면 이벤트가 없는 날이
-- 차트에서 사라져 X축 간격이 거짓말을 한다.

WITH m AS (
  SELECT d_kst, bait_n, rock_n, users_bait, users_rock,
         attempts, attempts_bait, attempts_rock, attempts_plain,
         bait_share, rock_share, plain_share,
         bait_stay_rate, rock_stay_rate
  FROM wh.bait_rock_daily
),
b AS (SELECT max(d_kst) AS hi, greatest(min(d_kst), max(d_kst) - 89) AS lo FROM m),
spine AS (
  SELECT unnest(generate_series((SELECT lo FROM b), (SELECT hi FROM b),
                                INTERVAL 1 DAY))::DATE AS d_kst
)
SELECT
  s.d_kst::VARCHAR                          AS d,
  coalesce(m.bait_n, 0)                     AS bait_n,
  coalesce(m.rock_n, 0)                     AS rock_n,
  coalesce(m.users_bait, 0)                 AS users_bait,
  coalesce(m.users_rock, 0)                 AS users_rock,
  coalesce(m.attempts, 0)                   AS attempts,
  coalesce(m.attempts_bait, 0)              AS attempts_bait,
  coalesce(m.attempts_rock, 0)              AS attempts_rock,
  coalesce(m.attempts_plain, 0)             AS attempts_plain,
  -- 비율은 0으로 채우지 않는다. "시도가 없어서 알 수 없음"과 "0%" 는 다르다.
  round(m.bait_share, 4)                    AS bait_share,
  round(m.rock_share, 4)                    AS rock_share,
  round(m.plain_share, 4)                   AS plain_share,
  round(m.bait_stay_rate, 4)                AS bait_stay_rate,
  round(m.rock_stay_rate, 4)                AS rock_stay_rate
FROM spine s LEFT JOIN m USING (d_kst)
ORDER BY 1;
