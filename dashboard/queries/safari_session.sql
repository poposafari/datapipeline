-- 사파리 체류시간
--
-- SAFARI_ENTER ↔ 다음 SAFARI_EXIT 페어링. 중앙값을 쓴다 — 방치된 세션 하나가
-- 평균을 통째로 끌고 간다.
--
-- unclosed_rate 를 같이 낸다. 창을 닫거나 연결이 끊기면 EXIT 가 없어서 짝이
-- 안 맞는 게 **정상적으로** 발생한다. 그래서 이 비율 자체가 지표다 —
-- 튀면 서버 이상 신호다.

WITH m AS (
  SELECT d_kst, sessions, users, closed_sessions, unclosed_rate,
         dwell_median_sec, dwell_p90_sec
  FROM wh.safari_session_daily
),
b AS (SELECT max(d_kst) AS hi, greatest(min(d_kst), max(d_kst) - 89) AS lo FROM m),
spine AS (
  SELECT unnest(generate_series((SELECT lo FROM b), (SELECT hi FROM b),
                                INTERVAL 1 DAY))::DATE AS d_kst
)
SELECT
  s.d_kst::VARCHAR                      AS d,
  coalesce(m.sessions, 0)               AS sessions,
  coalesce(m.users, 0)                  AS users,
  coalesce(m.closed_sessions, 0)        AS closed_sessions,
  round(m.unclosed_rate, 4)             AS unclosed_rate,
  -- 초 → 분. 대시보드에서 읽기 쉬운 단위로 굽는다.
  round(m.dwell_median_sec / 60.0, 2)   AS dwell_median_min,
  round(m.dwell_p90_sec / 60.0, 2)      AS dwell_p90_min
FROM spine s LEFT JOIN m USING (d_kst)
ORDER BY 1;
