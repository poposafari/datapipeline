#!/usr/bin/env python3
"""PopoSafari — R2 픽스처 생성기.

server 레포의 S1(export-audit.sh)이 아직 없어서 R2에 객체가 하나도 없다.
이 스크립트가 계약(§1-2)대로 가짜 객체를 만들어, S1 없이도 D2~D5 전체를
로컬에서 검증할 수 있게 한다. S1이 붙는 날 바뀌는 건 R2_BASE 하나다.

핵심은 "그럴듯한 데이터"가 아니라 **psql COPY CSV의 출력 형식을 정확히
흉내내는 것**이다. NULL 표현 하나만 틀려도 적재 검증이 의미를 잃는다.
그리고 파이프라인이 반드시 견뎌야 할 함정(§0 C1~C6)을 의도적으로 심는다.

    python3 fixtures/gen.py            # fixtures/out, fixtures/out-dirty 둘 다
    python3 fixtures/gen.py --clean-only

레이아웃은 실제 R2와 동일하다:
    <base>/raw/dt=YYYY-MM-DD/audit_<from>_<to>.csv.gz
    <base>/backfill/dt=YYYY-MM-DD/resweep.csv.gz
    <base>/meta/counts.csv.gz
    <base>/master/LATEST, master/v=<sha>/{pokemon.csv,item.csv}
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import random
import shutil
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# server 레포가 있으면 진짜 마스터를 쓰고, 없으면 아래 스키마로 합성한다.
#   POPOSAFARI_SERVER=/path/to/server python3 fixtures/gen.py
SERVER_MASTER = Path(
    os.environ.get("POPOSAFARI_SERVER", str(Path.home() / "Downloads" / "server"))
) / "lib" / "master"

# 계약 §1-2. 8컬럼 고정, ip 없음.
COLUMNS = [
    "id",
    "account_id",
    "action",
    "status",
    "detail",
    "user_agent",
    "source",
    "created_at",
]

MASTER_SHA = "a6e3b43c0de1f2a3b4c5d6e7f8091a2b3c4d5e6f"

UA_POOL = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
]

# 실물 map/*.json 의 스폰 id 형식. 전부 패딩되어 있다 (§0 C1).
POKEDEX_POOL = ["0001", "0016", "0025", "0052", "0129", "0058_hisui", "0003-mega"]
MAP_POOL = ["s000", "s001", "s002", "s014", "p001"]
ITEM_POOL = ["safari-ball", "safari-zone-ticket", "fire-stone", "rare-candy"]


# ─── psql COPY CSV 형식 ────────────────────────────────────────────────
#
# PostgreSQL 은 CSV 로 내보낼 때
#   · NULL        → 따옴표 없는 빈 필드
#   · 빈 문자열   → "" (따옴표) — NULL 과 구분하기 위해 강제로 인용한다
#   · boolean     → t / f
#   · timestamp   → 'YYYY-MM-DD HH:MM:SS' (AT TIME ZONE 'UTC' 를 거쳤으므로 tz 없음)
# 를 지킨다. csv.QUOTE_MINIMAL + 빈 문자열 특례로 재현된다.
def _pg_field(v: object) -> str:
    if v is None:
        return ""  # 인용되지 않은 빈 필드 = NULL
    if isinstance(v, bool):
        return "t" if v else "f"
    s = str(v)
    # 빈 문자열은 NULL 과 구분하기 위해 PG 가 강제로 인용한다
    if s == "" or any(c in s for c in ',"\n\r'):
        return '"' + s.replace('"', '""') + '"'
    return s


def pg_csv(rows: list[list[object]]) -> bytes:
    """헤더 + rows 를 psql COPY ... WITH CSV HEADER 형식 바이트로."""
    out = [",".join(COLUMNS)]
    out += [",".join(_pg_field(v) for v in row) for row in rows]
    return ("\n".join(out) + "\n").encode("utf-8")


def pg_jsonb(obj: dict) -> str:
    """PG jsonb 의 렌더링을 흉내낸다: 키를 길이→바이트순 정렬, ', ' / ': ' 구분자."""
    if obj is None:
        return None
    items = sorted(obj.items(), key=lambda kv: (len(kv[0]), kv[0]))
    inner = ", ".join(f"{json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in items)
    return "{" + inner + "}"


# ─── 마스터 데이터 ─────────────────────────────────────────────────────
#
# server 레포 lib/master/*.csv 의 실제 스키마. 두 파일 모두 **CRLF**, BOM 없음,
# EOF 개행 없음. pokemon.csv 의 id 는 형식이 섞여 있다 — 기본형은 평문 정수
# ("1"), 변종은 패딩된 합성 문자열("0058_hisui"). 이게 §0 C1 함정의 원천이다.
# 정규화 규칙의 정본은 server 레포 lib/master/csv_to_json.py:48-52 다:
#     s.zfill(4) if s.isdigit() else s

POKEMON_HEADER = (
    "id,ability,comment,evol_cost,evol_next,form_cost,form_next,generation,"
    "height_m,rate_capture,rate_female,rate_flee,rate_male,skills,spawn,tier,"
    "type1,type2,weight_kg,growth_group,base_exp"
)
ITEM_HEADER = "id,buy,category,comment,purchasable,sell,sellable,tier"

# (id, 한글명, type1, type2, tier)
_POKEMON_SEED = [
    ("1", "이상해씨", "grass", "poison", "super-rare"),
    ("2", "이상해풀", "grass", "poison", "ultra-rare"),
    ("3", "이상해꽃", "grass", "poison", "legendary"),
    ("16", "구구", "normal", "flying", "common"),
    ("19", "꼬렛", "normal", "", "common"),
    ("25", "피카츄", "electric", "", "rare"),
    ("52", "나옹", "normal", "", "common"),
    ("58", "가디", "fire", "", "rare"),
    ("129", "잉어킹", "water", "", "common"),
    ("1025", "브리두라스", "poison", "fighting", "legendary"),
    # 변종 — 이미 패딩된 합성 id. 정수 캐스팅하면 NULL 이 된다.
    ("0003-mega", "메가이상해꽃", "grass", "poison", "legendary"),
    ("0019_alola", "알로라꼬렛", "dark", "normal", "common"),
    ("0052_galar", "가라르나옹", "steel", "", "common"),
    ("0058_hisui", "히스이가디", "fire", "rock", "rare"),
]


def synth_master_pokemon() -> bytes:
    rows = [POKEMON_HEADER]
    for i, (pid, name, t1, t2, tier) in enumerate(_POKEMON_SEED):
        rows.append(
            ",".join(
                [
                    pid,
                    '"[\'overgrow\', \'chlorophyll\']"',  # 콤마 포함 → 인용됨
                    name,
                    "['candy_50']",
                    "[]",
                    "[]",
                    "[]",
                    "1",
                    f"{0.4 + i * 0.3:.1f}",
                    f"{0.05 + i * 0.01:.2f}",  # rate_capture
                    "0.12",
                    f"{0.30 + i * 0.02:.2f}",  # rate_flee
                    "0.88",
                    '"[\'move_flash\', \'move_cut\']"',
                    "['land']",
                    tier,
                    t1,
                    t2,
                    f"{6.9 + i:.1f}",
                    "medium_slow",
                    str(64 + i * 7),
                ]
            )
        )
    # CRLF, EOF 개행 없음 — 실물 그대로
    return "\r\n".join(rows).encode("utf-8")


def synth_master_item() -> bytes:
    rows = [ITEM_HEADER]
    seed = [
        ("safari-ball", 200, "pokeball", "사파리볼", "TRUE", 10, "TRUE", "common"),
        ("safari-zone-ticket", 400, "etc", "사파리존입장권", "TRUE", 0, "FALSE", "rare"),
        ("fire-stone", 3000, "evolution", "불의돌", "TRUE", 1500, "TRUE", "rare"),
        ("rare-candy", 9800, "etc", "이상한사탕", "TRUE", 4900, "TRUE", "super-rare"),
    ]
    for iid, buy, cat, name, purch, sell, sellable, tier in seed:
        rows.append(f"{iid},{buy},{cat},{name},{purch},{sell},{sellable},{tier}")
    return "\r\n".join(rows).encode("utf-8")


def ts(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def write_gz(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 으로 고정해 같은 입력이면 같은 바이트가 나오게 한다
    with path.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as f:
        f.write(data)


# ─── 이벤트 생성 ───────────────────────────────────────────────────────


class Gen:
    def __init__(self, today: date, seed: int = 20260808) -> None:
        self.today = today
        self.rng = random.Random(seed)
        self.next_id = 1_000_000
        self.rows: list[dict] = []
        # 계정별 잔고를 실제로 추적한다. detail.money 는 "거래 후 잔고"이므로
        # 무작위 값을 넣으면 money_series 의 1차 차분이 무의미해지고
        # recipes/abuse/money_spike.sql 의 항등식 검사를 검증할 수 없다.
        self.balance: dict[int, int] = {}

    def _id(self) -> int:
        self.next_id += self.rng.randint(1, 3)
        return self.next_id

    def add(
        self,
        when: datetime,
        action: str,
        detail: dict | str | None,
        *,
        account_id: int | None = None,
        status: int | None = 200,
        user_agent: object = "__pick__",
        source: str = "api",
        row_id: int | None = None,
    ) -> dict:
        if user_agent == "__pick__":
            user_agent = self.rng.choice(UA_POOL)
        row = {
            "id": row_id if row_id is not None else self._id(),
            "account_id": account_id,
            "action": action,
            "status": status,
            # detail 이 str 이면 그대로 (깨진 JSON 함정용), dict 면 jsonb 렌더링
            "detail": detail if isinstance(detail, str) or detail is None else pg_jsonb(detail),
            "user_agent": user_agent,
            "source": source,
            "created_at": when,
        }
        self.rows.append(row)
        return row

    # ── 일상적인 하루치 트래픽 ──────────────────────────────────────
    # 주의: 잔고를 이어서 갱신하므로 **날짜 오름차순으로 호출해야 한다.**
    # 순서를 어기면 created_at 정렬 후 money_delta 항등식이 깨진다.
    # 같은 날을 두 번 부를 때는 acct_offset 으로 계정을 겹치지 않게 할 것.
    def day(self, d: date, n_accounts: int = 12, acct_offset: int = 0) -> None:
        for acct in range(1 + acct_offset, n_accounts + 1 + acct_offset):
            base = datetime(d.year, d.month, d.day, self.rng.randint(1, 20), tzinfo=timezone.utc)
            t = base

            def bump(lo=20, hi=400):
                nonlocal t
                t = t + timedelta(seconds=self.rng.randint(lo, hi))
                return t.replace(tzinfo=None)

            self.add(bump(), "LOGIN_LOCAL", {"provider": "local"}, account_id=acct)
            self.add(
                bump(),
                "SAFARI_ENTER",
                {"mapId": self.rng.choice(MAP_POOL), "ticketConsumed": True, "ballsGranted": 30},
                account_id=acct,
            )
            for _ in range(self.rng.randint(1, 5)):
                self.add(
                    bump(),
                    "POKEMON_CATCH",
                    {
                        "userPokemonId": self.rng.randint(1, 99999),
                        "pokedexId": self.rng.choice(POKEDEX_POOL),
                        "level": self.rng.randint(2, 40),
                        "isShiny": self.rng.random() < 0.02,
                        "mapId": self.rng.choice(MAP_POOL),
                        "isS000Starter": False,
                    },
                    account_id=acct,
                )
            bal = self.balance.setdefault(acct, self.rng.randint(20000, 90000))
            # 잔고보다 비싼 구매는 만들지 않는다 — 실제로도 ck_user_money CHECK 가 막는다.
            # 클램프하면 money_delta 항등식이 깨져 검증이 무의미해진다.
            if self.rng.random() < 0.7 and bal > 3000:
                cost = self.rng.randint(100, 3000)
                bal = bal - cost
                self.balance[acct] = bal
                self.add(
                    bump(),
                    "ITEM_BUY",
                    {
                        "item": self.rng.choice(ITEM_POOL),
                        "quantity": self.rng.randint(1, 9),
                        "totalCost": cost,
                        "money": bal,  # 거래 후 잔고
                    },
                    account_id=acct,
                )
            if self.rng.random() < 0.5:
                gain = self.rng.randint(10, 800)
                bal = bal + gain
                self.balance[acct] = bal
                self.add(
                    bump(),
                    "ITEM_SELL",
                    {
                        "item": self.rng.choice(ITEM_POOL),
                        "quantity": self.rng.randint(1, 4),
                        "totalGain": gain,
                        "money": bal,
                    },
                    account_id=acct,
                )
            if self.rng.random() < 0.8:
                # MAP_CHANGE 는 mapId 가 아니라 from/to 다 (§0 C5)
                self.add(
                    bump(),
                    "MAP_CHANGE",
                    {
                        "from": self.rng.choice(MAP_POOL),
                        "to": self.rng.choice(MAP_POOL),
                        "x": self.rng.randint(0, 80),
                        "y": self.rng.randint(0, 80),
                    },
                    account_id=acct,
                    source="socket",
                    user_agent=None,  # 소켓 경로는 user_agent 가 없다 → NULL 함정
                )


def build(base: Path, today: date, dirty: bool) -> None:
    g = Gen(today, seed=20260808 + (1 if dirty else 0))

    # 창 밖 파티션 — 최초 전량 적재에서만 잡혀야 한다.
    # 날짜 오름차순 규칙 때문에 **가장 먼저** 생성한다.
    g.day(today - timedelta(days=40), n_accounts=3)

    # 7일 스캔 창 안쪽 (TODAY-5 .. TODAY)
    for back in range(5, -1, -1):
        g.day(today - timedelta(days=back))

    # ── 함정 심기 ──────────────────────────────────────────────────
    d2 = today - timedelta(days=2)
    d3 = today - timedelta(days=3)

    # C2: UTC 23:30 → KST 로는 다음 날. TIMESTAMPTZ 로 읽으면 9h 밀린다.
    g.add(
        datetime(d2.year, d2.month, d2.day, 23, 30, 0),
        "POKEMON_CATCH",
        {
            "userPokemonId": 777001,
            "pokedexId": "0025",
            "level": 12,
            "isShiny": False,
            "mapId": "s001",
            "isS000Starter": False,
            "probe": "c2_kst_boundary",
        },
        account_id=1,
    )

    # C1: 변종 pokedexId — 정수 캐스팅하면 NULL 이 되어 조인이 유실된다
    for pdx in ("0058_hisui", "0003-mega"):
        g.add(
            datetime(d2.year, d2.month, d2.day, 12, 0, 0),
            "POKEMON_CATCH",
            {
                "userPokemonId": 777002,
                "pokedexId": pdx,
                "level": 30,
                "isShiny": False,
                "mapId": "s014",
                "isS000Starter": False,
                "probe": "c1_variant_form",
            },
            account_id=2,
        )

    # 튜토리얼 강제 포획 — 확률 분석에서 제외되어야 한다
    g.add(
        datetime(d3.year, d3.month, d3.day, 9, 0, 0),
        "POKEMON_CATCH",
        {
            "userPokemonId": 777003,
            "pokedexId": "0001",
            "level": 5,
            "isShiny": True,
            "mapId": "s000",
            "isS000Starter": True,
        },
        account_id=3,
    )

    # §1-4: detail 무보증. 깨진 JSON 이 와도 행 전체가 죽으면 안 된다.
    g.add(
        datetime(d3.year, d3.month, d3.day, 10, 0, 0),
        "REQUEST_REJECTED",
        "this is not json at all",
        account_id=4,
        status=400,
    )

    # redactBody 가 2048B 초과 시 통째로 치환하는 형태 (lib/utils/audit.ts:27)
    g.add(
        datetime(d3.year, d3.month, d3.day, 10, 5, 0),
        "REQUEST_REJECTED",
        {
            "url": "/api/pokemon/arrange",
            "body": {"_truncated": "x" * 300},
            "method": "POST",
            "errorCode": "DTO_INVALID",
        },
        account_id=4,
        status=400,
    )

    # 빈 문자열 user_agent — NULL 과 구분되는지
    g.add(
        datetime(d3.year, d3.month, d3.day, 11, 0, 0),
        "LOGOUT",
        None,
        account_id=5,
        user_agent="",
    )

    if dirty:
        # 계약 §1-3 파기: url 에 쿼리스트링이 남아 있다 (OAuth code 유출 경로)
        g.add(
            datetime(d2.year, d2.month, d2.day, 8, 0, 0),
            "REQUEST_REJECTED",
            {
                "url": "/api/auth/oauth/callback?code=SECRET123&state=abc",
                "method": "GET",
                "errorCode": "OAUTH_INVALID_STATE",
            },
            account_id=None,
            status=400,
        )
        # 계약 §1-3 파기: 실패 시도 아이디 평문
        g.add(
            datetime(d2.year, d2.month, d2.day, 8, 5, 0),
            "LOGIN_FAILED",
            {
                "url": "/api/auth/login",
                "body": {"username": "victim@example.com"},
                "method": "POST",
                "errorCode": "FAILED_ACCOUNT",
            },
            account_id=None,
            status=401,
        )
        # 마스터에 없는 pokedexId → orphan 어서션이 잡아야 한다
        g.add(
            datetime(d2.year, d2.month, d2.day, 9, 0, 0),
            "POKEMON_CATCH",
            {
                "userPokemonId": 777004,
                "pokedexId": "9999",
                "level": 50,
                "isShiny": False,
                "mapId": "s002",
                "isS000Starter": False,
            },
            account_id=6,
        )
        # 잔고 조작 — 거래로 설명되지 않는 증가.
        # 직전 거래 잔고에서 trade_amount 와 무관하게 튀어 오른다
        # → recipes/abuse/money_spike.sql ① 의 항등식이 깨져야 한다.
        cheater = 7
        g.balance[cheater] = g.balance.get(cheater, 50_000) + 5_000_000
        g.add(
            datetime(d2.year, d2.month, d2.day, 10, 0, 0),
            "ITEM_SELL",
            {
                "item": "rare-candy",
                "quantity": 1,
                "totalGain": 40,
                "money": g.balance[cheater],
                "probe": "money_manipulation",
            },
            account_id=cheater,
        )

        # id 갭 — 유실 의심 신호
        g.next_id += 50_000

    # 갭 뒤에도 데이터가 있어야 lag() 가 갭을 본다.
    # 위 루프가 이미 today 를 돌았으므로, 잔고 시계열이 겹치지 않도록 별도 계정으로.
    g.day(today, n_accounts=4, acct_offset=20)

    g.rows.sort(key=lambda r: (r["created_at"], r["id"]))

    # ── raw/ 파티션: 이벤트 날짜별로 묶어 내보낸다 ──────────────────
    by_day: dict[date, list[dict]] = {}
    for r in g.rows:
        by_day.setdefault(r["created_at"].date(), []).append(r)

    # 중복 우선순위 검증용 행: raw 는 늦게(다음 날) 내보내고 내용이 낡았다.
    # backfill 은 이벤트 날짜 파티션에 올바른 내용으로 들어간다.
    # → dt DESC 로 정렬하면 raw(늦은 dt)가 이기고, filename 규칙이라야 backfill 이 이긴다.
    dup_src = by_day[d3][len(by_day[d3]) // 2]
    dup_stale = dict(dup_src)
    dup_stale["detail"] = pg_jsonb({"probe": "dedup_priority", "corrected": False})
    dup_fixed = dict(dup_src)
    dup_fixed["detail"] = pg_jsonb({"probe": "dedup_priority", "corrected": True})
    by_day[d3] = [r for r in by_day[d3] if r["id"] != dup_src["id"]]

    # status 가 전부 NULL 인 배치를 따로 떼어낸다. columns 를 명시하지 않으면
    # 이 파일만 VARCHAR 로 추론되어 union 시 타입 충돌이 난다
    # (계획서 §D2-2 ①, "가장 흔한 조용한 실패"). id 는 원래 것을 그대로 쓰므로
    # 중복도 갭도 만들지 않는다.
    d4 = today - timedelta(days=4)
    null_status = [dict(r, status=None) for r in by_day[d4][:5]]
    by_day[d4] = by_day[d4][5:]

    for d, rows in sorted(by_day.items()):
        if not rows:
            continue
        payload = [[r[c] for c in COLUMNS] for r in _fmt(rows)]
        ids = [r["id"] for r in rows]
        obj = f"audit_{min(ids):012d}_{max(ids):012d}.csv.gz"
        write_gz(base / "raw" / f"dt={d.isoformat()}" / obj, pg_csv(payload))

    write_gz(
        base / "raw" / f"dt={d4.isoformat()}" / "audit_null_status.csv.gz",
        pg_csv([[r[c] for c in COLUMNS] for r in _fmt(null_status)]),
    )

    # 낡은 사본을 하루 뒤 파티션에 (익스포트가 자정을 넘긴 상황)
    write_gz(
        base / "raw" / f"dt={(d3 + timedelta(days=1)).isoformat()}" / "audit_late_export.csv.gz",
        pg_csv([[r[c] for c in COLUMNS] for r in _fmt([dup_stale])]),
    )

    # ── backfill/ 재스윕: 직전 2일 + 중복 우선순위 검증 행 ──────────
    for back in (1, 2):
        d = today - timedelta(days=back)
        rows = by_day.get(d, [])
        if rows:
            write_gz(
                base / "backfill" / f"dt={d.isoformat()}" / "resweep.csv.gz",
                pg_csv([[r[c] for c in COLUMNS] for r in _fmt(rows)]),
            )
    write_gz(
        base / "backfill" / f"dt={d3.isoformat()}" / "resweep.csv.gz",
        pg_csv([[r[c] for c in COLUMNS] for r in _fmt([dup_fixed])]),
    )
    g.rows.append(dup_fixed)

    # ── meta/counts.csv.gz — prod 가 재스윕 때 발행하는 일별 카운트 ──
    seen: set[int] = set()
    daily: dict[date, int] = {}
    for r in g.rows:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        daily[r["created_at"].date()] = daily.get(r["created_at"].date(), 0) + 1
    cutoff = today - timedelta(days=14)
    counts = [(d, n) for d, n in sorted(daily.items()) if d > cutoff]
    if dirty:
        # 유실 시뮬레이션: prod 가 웨어하우스보다 많다고 주장하는 날
        counts = [(d, n + 25 if d == today - timedelta(days=4) else n) for d, n in counts]
    body = "d,n\n" + "".join(f"{d.isoformat()},{n}\n" for d, n in counts)
    write_gz(base / "meta" / "counts.csv.gz", body.encode())

    # ── master/ — server 레포에서 그대로 복사 ───────────────────────
    mdir = base / "master" / f"v={MASTER_SHA}"
    mdir.mkdir(parents=True, exist_ok=True)
    synth = {"pokemon.csv": synth_master_pokemon, "item.csv": synth_master_item}
    used_real = False
    for name, fallback in synth.items():
        src = SERVER_MASTER / name
        if src.exists():
            shutil.copyfile(src, mdir / name)
            used_real = True
        else:
            (mdir / name).write_bytes(fallback())
    (base / "master" / "LATEST").write_text(MASTER_SHA)

    n_files = sum(1 for _ in base.rglob("*.csv.gz"))
    origin = "server 레포 실물" if used_real else "합성(server 레포 없음)"
    print(f"  {base.relative_to(REPO)}: {len(seen)}행(중복제외), {n_files}개 객체, 마스터={origin}")


def _fmt(rows: list[dict]) -> list[dict]:
    """created_at 을 psql 출력 문자열로 바꾼 사본을 돌려준다."""
    return [dict(r, created_at=ts(r["created_at"])) for r in rows]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO / "fixtures" / "out"))
    ap.add_argument("--clean-only", action="store_true")
    args = ap.parse_args()

    today = datetime.now(timezone.utc).date()
    print(f"픽스처 생성 (기준일 {today} UTC)")

    clean = Path(args.out)
    if clean.exists():
        shutil.rmtree(clean)
    build(clean, today, dirty=False)

    if not args.clean_only:
        dirty = clean.parent / (clean.name + "-dirty")
        if dirty.exists():
            shutil.rmtree(dirty)
        build(dirty, today, dirty=True)


if __name__ == "__main__":
    main()
