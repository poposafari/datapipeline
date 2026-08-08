-- PopoSafari — R2 → wh.audit 적재
--
-- 성질
--   · 재실행 멱등    — id 안티조인. 2회차 rows_inserted = 0
--   · 파일 겹침 무해  — DISTINCT ON (id). 증분과 재스윕이 겹쳐도 된다
--   · 커서 갭 복구    — 증분에서 빠진 id 가 재스윕 파일에 있으면 여기서 메워진다
--   · 스캔 범위 고정  — 최근 7일 파티션만. Celeron N3150 에서도 초 단위
--   · R2 가 정본     — 이 .duckdb 가 깨지면 테이블을 비우고 다시 돌리면 전량 재구축된다
--                      (아래 scan_from 이 빈 테이블일 때 자동으로 전량으로 넓어진다)

SET VARIABLE scan_from = (
  -- 평소엔 7일. 첫 실행(빈 테이블)이면 서비스 개시일부터 전량.
  SELECT CASE WHEN (SELECT count(*) FROM wh.audit) = 0
              THEN DATE '2026-01-01'
              ELSE current_date - 7 END
);

-- rows_inserted 를 "이번에 늘어난 수"로 남기려면 적재 전 카운트가 필요하다.
CREATE OR REPLACE TEMP TABLE _before AS SELECT count(*) AS n FROM wh.audit;

INSERT INTO wh.audit
SELECT s.id, s.account_id, s.action, s.status,
       -- §1-4: detail 스키마는 무보증이다. PG 의 jsonb 가 CSV 에서는 따옴표로
       -- 감싼 문자열이라 바로 JSON 으로 읽으면 파싱 실패 시 행 전체가 죽는다.
       -- VARCHAR 로 읽고 TRY_CAST 로 NULL 흡수한다.
       TRY_CAST(s.detail AS JSON),
       s.user_agent, s.source, s.created_at
FROM (
  SELECT DISTINCT ON (id) *
  FROM read_csv(
        -- 프리픽스를 명시적으로 나열한다. '*/dt=*' 는 master/ 와 meta/ 까지 긁는다.
        -- ⚠️ 중괄호 확장('{raw,backfill}')은 DuckDB 1.5 에서 **동작하지 않는다**
        --    — 0개 파일에 매칭되고 조용히 빈 결과가 된다. 리스트 형태를 쓸 것.
        [ getvariable('r2_base') || '/raw/dt=*/*.csv.gz',
          getvariable('r2_base') || '/backfill/dt=*/*.csv.gz' ],
        header            = true,
        hive_partitioning = true,   -- dt 파티션 컬럼 (DATE 로 추론된다)
        filename          = true,   -- 아래 중복 우선순위 판정에 쓴다
        nullstr           = '',     -- psql COPY 의 NULL 표현
        -- 타입을 명시한다. auto-detect 에 맡기면 어떤 날 status 가 전부 비었을 때
        -- 그 파일만 VARCHAR 로 추론되어 union 시 타입 충돌이 난다. 가장 흔한 조용한 실패.
        columns = {
          'id':'BIGINT', 'account_id':'INTEGER', 'action':'VARCHAR', 'status':'SMALLINT',
          'detail':'VARCHAR', 'user_agent':'VARCHAR', 'source':'VARCHAR',
          'created_at':'TIMESTAMP'
        })
  WHERE dt >= getvariable('scan_from')
  -- 같은 id 가 증분과 재스윕 양쪽에 있으면 **재스윕(backfill)을 채택**한다.
  -- 재스윕이 나중에 만들어진 데이터이고 마스킹 정의도 최신이다.
  --   ⚠️ dt 로는 판정할 수 없다. raw 의 dt 는 *추출일*, backfill 의 dt 는 *이벤트일*이라
  --      익스포트가 자정을 넘기면 raw 쪽 dt 가 오히려 크다. 경로로 판정해야 한다.
  ORDER BY id, (filename LIKE '%/backfill/%') DESC
) s
WHERE NOT EXISTS (SELECT 1 FROM wh.audit a WHERE a.id = s.id);

INSERT INTO wh.load_log
SELECT now()::TIMESTAMP,
       getvariable('scan_from'),
       (SELECT count(*) FROM wh.audit) - (SELECT n FROM _before),
       (SELECT count(*) FROM wh.audit),
       (SELECT max(id) FROM wh.audit);
