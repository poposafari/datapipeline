-- PopoSafari — 적재 후 자동 검증
--
-- **전부 0행이어야 한다.** 한 행이라도 나오면 run.sh 가 Discord 로 알린다.
-- 호출자가 wh 카탈로그를 붙여둔 상태를 전제한다 (ATTACH ... AS wh).
--
-- ⚠️ server 레포 S1(export-audit.sh)이 배포되기 전에는 ②가 **반드시 걸린다.**
--    계약 §1-3 의 마스킹 3종은 전부 "아직 없는 익스포터"의 성질이기 때문이다.
--    현재 prod DB 에는 ip 값이 있고, request.url 은 쿼리스트링을 포함하며,
--    LOGIN_FAILED 의 body.username 은 REDACT_KEYS 에 없어 평문으로 저장된다.
--    이 어서션의 목적은 "지금 깨끗한가"가 아니라 **계약이 깨졌는가를 탐지**하는 것이다.

-- ① 중복 — 안티조인이 뚫렸다는 뜻. PRIMARY KEY 가 있으니 사실상 나올 수 없다.
SELECT 'dup' AS check_name, id::VARCHAR AS detail
FROM wh.audit GROUP BY id HAVING count(*) > 1

UNION ALL
-- ② 마스킹 위반 — 상대편 계약(§1-3) 파기 탐지
--    url 에 '?' 가 남아 있으면 OAuth code 같은 게 그대로 적재된 것이다.
SELECT 'unmasked_url', id::VARCHAR
FROM wh.audit_v
WHERE action = 'REQUEST_REJECTED' AND req_url LIKE '%?%'

UNION ALL
SELECT 'unmasked_username', id::VARCHAR
FROM wh.audit_v
WHERE action = 'LOGIN_FAILED'
  AND json_extract_string(detail, '$.body.username') IS NOT NULL

UNION ALL
-- ③ id 연속성 — 갭이 크면 유실 의심.
--    커밋 순서 갭(bigserial 은 커밋 순서가 아니라 채번 순서다)은 재스윕이
--    다음날 메우므로, **3일 넘게 남아 있는 갭만이 진짜 유실**이다.
--    임계 1000 은 임시값 — 첫 2주 실측으로 조정할 것.
SELECT 'gap', prev::VARCHAR || '→' || id::VARCHAR
FROM (
  SELECT id, lag(id) OVER (ORDER BY id) AS prev
  FROM wh.audit
  WHERE created_at > now()::TIMESTAMP - INTERVAL 3 DAY
)
WHERE prev IS NOT NULL AND id - prev > 1000

UNION ALL
-- ④ 마스터 조인 손실 — pokedex_id 정규형이 어긋나면 여기가 터진다.
--    정수 캐스팅으로 정규화하면 변종 폼("0058_hisui")이 전부 여기 걸린다.
SELECT 'orphan_pokedex', a.pokedex_id
FROM wh.audit_v a
LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
WHERE a.pokedex_id IS NOT NULL AND p.pokedex_id IS NULL

UNION ALL
-- ⑤ ip 컬럼 부재 — 계약 §1-3. 스키마에 ip 가 생기면 즉시 알린다.
SELECT 'ip_column_present', column_name
FROM (DESCRIBE wh.audit)
WHERE lower(column_name) = 'ip'

UNION ALL
-- ⑥ CRLF 잔재 — 마스터 CSV 가 CRLF 라 마지막 컬럼에 \r 이 남을 수 있다.
SELECT 'crlf_residue', pokedex_id_raw
FROM wh.pokemon_dim
WHERE pokedex_id_raw LIKE '%' || chr(13) || '%'
   OR tier          LIKE '%' || chr(13) || '%'

ORDER BY 1, 2;
