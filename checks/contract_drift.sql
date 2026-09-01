-- PopoSafari — 상대편(server 레포)이 만들어 보내는 것의 **현재 상태 보고**.
--
--   duckdb /srv/warehouse/poposafari.duckdb
--   D .read /opt/poposafari-data-pipeline/checks/contract_drift.sql
--
-- 적재 때마다 자동으로 돌지 않는다. 알림 대상이 아니기 때문이다.
--
-- 계획서 §1-3 은 server 가 마스킹 3종을 보장한다고 적었지만, 실제로 배포된
-- 익스포터·핸들러는 셋 다 하지 않는다. 매일 알리면 알림이 죽으므로
-- checks/assertions.sql 에서 빼고 여기로 옮겼다.
--
-- 여기의 값이 바뀌면 그건 사고가 아니라 **상대편이 뭔가 고쳤다는 뜻**이다.
-- 좋은 소식이지만 이쪽 마스킹을 걷어내도 되는지는 사람이 판단해야 한다.
--
-- expected 컬럼이 지금 관측된 값이다. actual 이 그것과 다르면 살펴볼 것.

SELECT '1. 소스에 ip 가 실려 오는가' AS item,
       'yes (archive-audit.sh 가 SELECT * 로 뽑는다)' AS expected,
       CASE WHEN list_contains((SELECT columns FROM wh.src_shape), 'ip')
            THEN 'yes' ELSE 'no — 익스포터가 바뀌었다' END AS actual,
       (SELECT sampled FROM wh.src_shape) AS evidence

UNION ALL
SELECT '2. 소스 컬럼 목록',
       '[account_id, action, created_at, detail, id, ip, source, status, user_agent]',
       coalesce((SELECT columns FROM wh.src_shape)::VARCHAR, '(샘플 없음)'),
       coalesce((SELECT observed_at FROM wh.src_shape)::VARCHAR, '')

UNION ALL
-- apps/api/app.ts:150 이 request.url 을 그대로 넣는다. 자르는 건 이쪽 뷰다.
SELECT '3. REQUEST_REJECTED.url 에 쿼리스트링이 남아 오는가',
       'yes (server 가 자르지 않는다)',
       CASE WHEN count(*) > 0 THEN 'yes — ' || count(*) || '행'
            ELSE 'no — server 가 자르기 시작했거나 표본이 없다' END,
       ''
FROM wh.audit
WHERE action = 'REQUEST_REJECTED'
  AND json_extract_string(detail, '$.url') LIKE '%?%'
  AND created_at > now()::TIMESTAMP - INTERVAL 30 DAY

UNION ALL
-- lib/utils/audit.ts:8 의 REDACT_KEYS 에 username 이 없다.
SELECT '4. LOGIN_FAILED.body.username 이 평문으로 오는가',
       'yes (REDACT_KEYS 에 username 이 없다)',
       CASE WHEN count(*) > 0 THEN 'yes — ' || count(*) || '행'
            ELSE 'no — REDACT_KEYS 에 추가됐거나 표본이 없다' END,
       ''
FROM wh.audit
WHERE action = 'LOGIN_FAILED'
  AND json_extract_string(detail, '$.body.username') IS NOT NULL
  AND created_at > now()::TIMESTAMP - INTERVAL 30 DAY

UNION ALL
-- master/ 프리픽스는 server 레포에 push-master.sh 가 생겨야 채워진다.
SELECT '5. 마스터가 R2 에 올라오는가',
       'no (server 레포에 push-master.sh 가 아직 없다)',
       CASE WHEN (SELECT count(*) FROM wh.master_pokemon) > 0
            THEN 'yes — ' || (SELECT count(*) FROM wh.master_pokemon) || '행'
            ELSE 'no (스텁)' END,
       coalesce((SELECT sha FROM wh.master_version), '')

UNION ALL
-- POKEMON_CATCH 에 wildUid 가 생기면 포획률 역산을 걷어낼 수 있다.
-- views/20_metrics.sql 의 catch_attempt 가 그때 훨씬 단순해진다.
SELECT '6. POKEMON_CATCH 에 wildUid 가 생겼는가',
       'no (detail 에 userPokemonId 만 있어 시도↔성공 직접 연결 불가)',
       CASE WHEN count(*) > 0 THEN 'yes — ' || count(*) || '행. 역산을 걷어낼 것'
            ELSE 'no' END,
       ''
FROM wh.audit
WHERE action = 'POKEMON_CATCH'
  AND json_extract_string(detail, '$.wildUid') IS NOT NULL
  AND created_at > now()::TIMESTAMP - INTERVAL 30 DAY

UNION ALL
-- SAFARI_BAIT/ROCK 에 mapId 가 생기면 s000 을 걸러 stay_rate 오염을 없앨 수 있다.
SELECT '7. SAFARI_BAIT/ROCK 에 mapId 가 생겼는가',
       'no (detail 이 {uid, result} 뿐이라 s000 을 못 거른다)',
       CASE WHEN count(*) > 0 THEN 'yes — bait_stay_rate 에서 s000 을 제외할 것'
            ELSE 'no' END,
       ''
FROM wh.audit
WHERE action IN ('SAFARI_BAIT', 'SAFARI_ROCK')
  AND json_extract_string(detail, '$.mapId') IS NOT NULL
  AND created_at > now()::TIMESTAMP - INTERVAL 30 DAY

ORDER BY 1;
