-- PopoSafari — 적재 이력 기록.
--
-- 10_load_audit.sql 이 아니라 여기 있는 이유: R2 에 대상 객체가 0개면 적재 단계를
-- 통째로 건너뛰는데(05_scan.sql 참고), **건너뛴 실행도 이력에 남아야 한다.**
-- "어제 파이프라인이 돌긴 했는데 넣을 게 없었다"와 "어제 아예 안 돌았다"는
-- 장애 조사에서 완전히 다른 이야기다.
--
-- rows_inserted 는 총 행수가 아니라 **이번에 늘어난 수**다. 총 행수를 넣으면
-- "이번에 몇 행 들어왔나"를 영영 알 수 없다.

INSERT INTO wh.load_log
SELECT (SELECT run_at    FROM wh.scan_state),
       (SELECT scan_from FROM wh.scan_state),
       (SELECT count(*)  FROM wh.scan_plan),
       (SELECT count(*)  FROM wh.audit) - (SELECT rows_before FROM wh.scan_state),
       (SELECT count(*)  FROM wh.audit),
       (SELECT max(id)   FROM wh.audit);
