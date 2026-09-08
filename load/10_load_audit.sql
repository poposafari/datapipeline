-- PopoSafari — R2 아카이브 → wh.audit 적재
--
-- ⚠️ run.sh 는 wh.scan_plan 이 비어 있지 않을 때만 이 파일을 실행한다 (05_scan.sql 참고).
--
-- 성질
--   · 재실행 멱등    — id 안티조인. 2회차 rows_inserted = 0
--   · 파일 겹침 무해  — DISTINCT ON (id). 배치가 겹쳐도 된다
--   · 스캔 범위 고정  — 최근 7일 아카이브일만. Celeron N3150 에서도 초 단위
--   · 전량 재구축     — 이 .duckdb 를 지우면 scan_from 이 자동으로 전량으로 넓어진다
--
-- ⚠️ 다만 "R2 가 정본"의 의미가 예전과 다르다. archive-audit.sh 는 업로드 뒤
--    audit_log 를 DELETE 하고 backup-pg.sh 는 --exclude-table-data=audit_log 다.
--    **R2 아카이브가 유일본이고 이 웨어하우스가 두 번째 사본이다.** 재구축이
--    가능한 건 R2 객체가 살아 있는 동안뿐이다 (docs §8).

-- ── 소스 형상 스냅샷 ────────────────────────────────────────────────
-- 가장 최근 객체 하나로 최상위 컬럼 목록을 떠 둔다. R2 를 다시 읽지 않고도
-- 계약 파기 탐지(checks/contract_drift.sql)와 ip 드롭 자기점검을 할 수 있다.
SET VARIABLE sample_obj = (
  SELECT path FROM wh.scan_plan ORDER BY batch_date DESC, path DESC LIMIT 1
);

DELETE FROM wh.src_shape;

INSERT INTO wh.src_shape
SELECT now()::TIMESTAMP,
       getvariable('sample_obj'),
       list_sort(list(column_name))
FROM (
  DESCRIBE
  SELECT * FROM read_json_auto(getvariable('sample_obj'),
                               format = 'newline_delimited') LIMIT 0
);

-- ── 적재 ────────────────────────────────────────────────────────────
SET VARIABLE files = (SELECT list(path) FROM wh.scan_plan);

INSERT INTO wh.audit
SELECT s.id, s.account_id, s.action, s.status,
       s.detail,
       s.user_agent, s.source,
       -- 소스는 '2026-08-20T12:34:56.789+00:00' 처럼 오프셋이 박힌 ISO 문자열이다
       -- (postgres:15-alpine 에 TZ 미설정 → row_to_json 이 UTC 로 렌더).
       -- 오프셋이 문자열 안에 있으므로 이 변환은 세션 TZ 와 무관하게 결정적이다.
       TRY_CAST(s.created_at AS TIMESTAMPTZ) AT TIME ZONE 'UTC'
FROM (
  SELECT DISTINCT ON (id) *
  FROM read_json(
        getvariable('files'),
        format = 'newline_delimited',
        -- 타입을 명시한다. auto-detect 에 맡기면 어떤 날 status 가 전부 비었을 때
        -- 그 파일만 다르게 추론되어 union 시 타입 충돌이 난다. 가장 흔한 조용한 실패.
        --
        -- detail 은 CSV 시절과 달리 **중첩 JSON 객체**로 온다. PG 의 jsonb 를
        -- row_to_json 이 그대로 중첩시키기 때문이다 — 따옴표로 감싼 문자열이 아니라
        -- 진짜 객체라서 TRY_CAST(VARCHAR AS JSON) 단계가 사라졌다.
        -- 그래도 방어적 파싱은 그대로 이쪽 책임이다 (계약 §1-4): 키 부재와 타입
        -- 불일치는 views/00_audit.sql 이 NULL 로 흡수한다.
        --
        -- created_at 을 VARCHAR 로 받는 이유는 위 SELECT 의 주석 참고.
        columns = {
          'id':'BIGINT', 'account_id':'INTEGER', 'action':'VARCHAR', 'status':'SMALLINT',
          'detail':'JSON', 'ip':'VARCHAR', 'user_agent':'VARCHAR', 'source':'VARCHAR',
          'created_at':'VARCHAR'
        })
  -- ★ ip 를 SELECT 하지 않는다. 소스에는 들어 있다 (archive-audit.sh 가
  --   SELECT * 로 뽑는다). 계약 §1-3 의 "ip 부재"는 익스포터 성질이었는데
  --   그 익스포터가 그렇게 만들어지지 않았다 — **마스킹 책임이 이쪽으로 넘어왔다.**
  --   여기서 떨어뜨리지 않으면 IP 가 웨어하우스에 영구 보존된다.
  ORDER BY id
) s
WHERE coalesce(getvariable('force_reload'), false)
   OR NOT EXISTS (SELECT 1 FROM wh.audit a WHERE a.id = s.id)
ON CONFLICT (id) DO UPDATE SET
  account_id = excluded.account_id,
  action = excluded.action,
  status = excluded.status,
  detail = excluded.detail,
  user_agent = excluded.user_agent,
  source = excluded.source,
  created_at = excluded.created_at;

INSERT INTO wh.loaded_objects
SELECT path, (SELECT run_at FROM wh.scan_state) FROM wh.scan_plan
ON CONFLICT (path) DO UPDATE SET loaded_at = excluded.loaded_at;

-- load_log 기록은 15_load_log.sql 이 한다. 적재 대상이 0개라 이 파일을 건너뛴
-- 실행도 이력에 남아야 하기 때문이다.
