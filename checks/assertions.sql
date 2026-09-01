-- PopoSafari — 적재 후 자동 검증
--
-- **전부 0행이어야 한다.** 한 행이라도 나오면 run.sh 가 Discord 로 알린다.
-- 호출자가 wh 카탈로그를 붙여둔 상태를 전제한다 (ATTACH ... AS wh).
--
-- ★ 이 파일의 목적이 바뀌었다.
--
--   예전 계약(§1-3)은 마스킹 3종(ip 부재 / url 쿼리스트링 절단 / username 제거)을
--   **server 가 보장한다**고 적었고, 어서션은 그 계약이 깨졌는지를 탐지하는 장치였다.
--   실제로 만들어진 익스포터(scripts/ops/archive-audit.sh)는 `SELECT *` 라서
--   ip 가 그대로 실려 오고, apps/api/app.ts:150 은 request.url 을 자르지 않으며,
--   REDACT_KEYS 에 username 이 없다. **셋 다 보장된 적이 없다.**
--
--   그래서 마스킹은 이쪽 책임이 됐고(load/10_load_audit.sql 이 ip 를 버리고,
--   views/00_audit.sql 이 url 을 자르고 username 을 노출하지 않는다),
--   이 파일은 **그 마스킹이 실제로 동작하는지를 자기점검**한다.
--
--   소스가 여전히 그런 상태인지(= 상대편이 언젠가 고쳤는지)는 알림 대상이 아니다.
--   매일 걸리면 알림이 죽는다. 그쪽은 checks/contract_drift.sql 로 분리했고
--   사람이 가끔 돌린다.

-- ① 중복 — 안티조인이 뚫렸다는 뜻. PRIMARY KEY 가 있으니 사실상 나올 수 없다.
SELECT 'dup' AS check_name, id::VARCHAR AS detail
FROM wh.audit GROUP BY id HAVING count(*) > 1

UNION ALL
-- ② ip 유입 — 적재 단계가 ip 를 떨어뜨리는지. 소스에는 **항상 들어 있다.**
--    누군가 load/10_load_audit.sql 의 SELECT 에 ip 를 되살리면 여기가 잡는다.
--    (소스에 ip 가 있느냐가 아니라, 우리가 그걸 버렸느냐를 본다.)
SELECT 'ip_column_present', column_name
FROM (DESCRIBE wh.audit)
WHERE lower(column_name) = 'ip'

UNION ALL
-- ③ 쿼리스트링 유출 — views/00_audit.sql 의 split_part 마스킹이 뚫렸는지.
--    OAuth code 가 여기로 새면 그대로 영구 보존된다.
SELECT 'unmasked_url', id::VARCHAR
FROM wh.audit_v
WHERE req_url LIKE '%?%'

UNION ALL
-- ④ username 노출 — audit_v 가 body 하위 키를 편의 컬럼으로 꺼내지 않는지.
--    원본 detail 에는 평문으로 들어 있다(REDACT_KEYS 에 username 이 없다).
--    뷰가 꺼내는 순간 아무 데서나 새어 나가므로 스키마 수준에서 막는다.
SELECT 'username_column_exposed', column_name
FROM (DESCRIBE wh.audit_v)
WHERE lower(column_name) LIKE '%username%'

UNION ALL
-- ⑤ id 연속성 — 갭이 크면 유실 의심.
--    ⚠️ 예전에는 "커밋 순서 갭은 재스윕이 다음날 메운다"고 적혀 있었다.
--       **재스윕이 없어졌다.** archive-audit.sh 는 export SELECT 와
--       DELETE 가 별개 세션이라 그 사이에 커밋된 행은 익스포트 없이 삭제된다.
--       메울 수단이 없으므로 여기 걸린 갭은 **영구 유실**로 봐야 한다.
--    임계 1000 은 임시값 — 첫 2주 실측으로 조정할 것.
SELECT 'gap', prev::VARCHAR || '→' || id::VARCHAR
FROM (
  SELECT id, lag(id) OVER (ORDER BY id) AS prev
  FROM wh.audit
  WHERE created_at > now()::TIMESTAMP - INTERVAL 3 DAY
)
WHERE prev IS NOT NULL AND id - prev > 1000

UNION ALL
-- ⑥ 마스터 조인 손실 — pokedex_id 정규형이 어긋나면 여기가 터진다.
--    정수 캐스팅으로 정규화하면 변종 폼("0058_hisui")이 전부 여기 걸린다.
--    ⚠️ 마스터가 아직 R2 에 없으면(= 스텁이면) 전건이 고아가 되어 무의미하다.
--       server 레포에 push-master.sh 가 없어서 그게 현재의 정상 상태다.
SELECT 'orphan_pokedex', a.pokedex_id
FROM wh.audit_v a
LEFT JOIN wh.pokemon_dim p USING (pokedex_id)
WHERE a.pokedex_id IS NOT NULL AND p.pokedex_id IS NULL
  AND (SELECT count(*) FROM wh.master_pokemon) > 0

UNION ALL
-- ⑦ CRLF 잔재 — 마스터 CSV 가 CRLF 라 마지막 컬럼에 \r 이 남을 수 있다.
SELECT 'crlf_residue', pokedex_id_raw
FROM wh.pokemon_dim
WHERE pokedex_id_raw LIKE '%' || chr(13) || '%'
   OR tier          LIKE '%' || chr(13) || '%'

ORDER BY 1, 2;
