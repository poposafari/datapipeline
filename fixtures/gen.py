#!/usr/bin/env python3
"""PopoSafari — R2 픽스처 생성기.

미니 PC 에서 R2 도, prod 도 없이 파이프라인 전체를 검증하기 위한 가짜 아카이브를 만든다.
R2_BASE 를 이쪽으로 돌리면 load/run.sh 부터 checks/ 까지 그대로 돈다.

핵심은 "그럴듯한 데이터"가 아니라 **server 레포 scripts/ops/archive-audit.sh 의
출력 형식을 정확히 흉내내는 것**이다:

    psql_stream "SELECT row_to_json(t) FROM (SELECT * FROM audit_log ...) t" | gzip

즉 gzip JSONL 이고, `SELECT *` 라서 **ip 가 들어 있고**, detail 은 jsonb 라
따옴표로 감싼 문자열이 아니라 **중첩 JSON 객체**이며, created_at 은 timestamptz 를
row_to_json 이 렌더한 '2026-08-20T12:34:56.789+00:00' 형태다
(postgres:15-alpine 에 TZ 미설정 → UTC).

    python3 fixtures/gen.py            # fixtures/out, fixtures/out-dirty 둘 다
    python3 fixtures/gen.py --clean-only

레이아웃은 실제 R2 와 동일하다:
    <base>/audit/YYYY/MM/DD/audit-<UTC stamp>-<cutoff>.jsonl.gz
    <base>/master/LATEST, master/v=<sha>/{pokemon.csv,item.csv}   ← 아직 prod 엔 없다

⚠️ raw/ · backfill/ · meta/ 는 더 이상 만들지 않는다. 계획서 v3 §1-1 이 그렇게
   적어뒀지만 실제 익스포터는 그런 걸 올리지 않는다. 야간 재스윕도 없다 —
   그래서 "겹치면 backfill 을 채택" 같은 우선순위 규칙도 사라졌다.
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

# 소스 컬럼 9개. archive-audit.sh 가 SELECT * 로 뽑으므로 ip 가 포함된다.
# 파이프라인은 이 중 ip 를 적재 단계에서 떨어뜨려야 한다 (load/10_load_audit.sql).
COLUMNS = [
    "id",
    "account_id",
    "action",
    "status",
    "detail",
    "ip",
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
# status 가 NULL 인 액션 — auditTx/auditAsync 를 직접 부르는 경로다.
# CSV 시절에는 "이 파일만 status 가 전부 비면 타입 추론이 갈린다"가 최대 함정이었다.
# JSONL 은 null 이 명시적이라 그 함정은 사라졌지만, columns 명시는 그대로 유지한다.
NULL_STATUS_ACTIONS = {
    "POKEMON_CATCH", "POKEMON_CATCH_ATTEMPT", "POKEMON_CATCH_FAIL",
    "SAFARI_ENTER", "SAFARI_TICKET_CLAIM", "ITEM_BUY", "ITEM_SELL",
    "MAP_CHANGE", "POKEMON_SPAWN", "SAFARI_ITEM_SPAWN",
    "SOCKET_CONNECT", "SOCKET_DISCONNECT",
}

IP_POOL = ["203.0.113.7", "198.51.100.42", "192.0.2.19", "2001:db8::1"]

# 실물 map/*.json 의 스폰 id 형식. 전부 패딩되어 있다.
POKEDEX_POOL = ["0001", "0016", "0025", "0052", "0129", "0058_hisui", "0003-mega"]
# 사파리 맵만. s000 은 튜토리얼이라 따로 다룬다 (ENTER 를 남기지 않는다).
SAFARI_POOL = ["s001", "s002", "s014"]
MAP_POOL = ["s000", "s001", "s002", "s014", "p001"]
ITEM_POOL = ["safari-ball", "safari-zone-ticket", "fire-stone", "rare-candy"]


# ─── row_to_json 출력 형식 ─────────────────────────────────────────────
#
# PostgreSQL 의 row_to_json 은
#   · SQL NULL    → JSON null
#   · jsonb       → 중첩 객체 (문자열이 아니다)
#   · boolean     → true / false
#   · timestamptz → "2026-08-20T12:34:56.789+00:00"
# 로 렌더한다. detail 이 진짜 객체라는 게 CSV 시절과의 가장 큰 차이다 —
# 그래서 적재 SQL 에서 TRY_CAST(VARCHAR AS JSON) 단계가 사라졌다.
def pg_ts(dt: datetime) -> str:
    """timestamptz 의 row_to_json 렌더링. 마이크로초가 0이면 생략된다."""
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    if dt.microsecond:
        base += f".{dt.microsecond:06d}".rstrip("0")
    return base + "+00:00"


def jsonl_gz(rows: list[dict]) -> bytes:
    """row_to_json 한 줄에 1행 + gzip."""
    out = []
    for r in rows:
        obj = {c: r[c] for c in COLUMNS}
        obj["created_at"] = pg_ts(obj["created_at"])
        out.append(json.dumps(obj, ensure_ascii=False))
    return ("\n".join(out) + "\n").encode("utf-8")


# ─── 마스터 데이터 ─────────────────────────────────────────────────────
#
# server 레포 lib/master/*.csv 의 실제 스키마. 두 파일 모두 **CRLF**, BOM 없음,
# EOF 개행 없음. pokemon.csv 의 id 는 형식이 섞여 있다 — 기본형은 평문 정수
# ("1"), 변종은 패딩된 합성 문자열("0058_hisui"). 이게 최대 함정의 원천이다.
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
        self.next_wild = 0
        # CREATE_USER 를 이미 남긴 계정 (계정당 1회)
        self.created: set[int] = set()

    def _id(self) -> int:
        self.next_id += self.rng.randint(1, 3)
        return self.next_id

    def wild_uid(self) -> str:
        self.next_wild += 1
        return f"w{self.next_wild:06d}"

    def add(
        self,
        when: datetime,
        action: str,
        detail: dict | list | str | int | None,
        *,
        account_id: int | None = None,
        status: int | None | str = "__auto__",
        user_agent: object = "__pick__",
        ip: object = "__pick__",
        source: str = "api",
        row_id: int | None = None,
    ) -> dict:
        if user_agent == "__pick__":
            user_agent = self.rng.choice(UA_POOL)
        if ip == "__pick__":
            ip = self.rng.choice(IP_POOL)
        if status == "__auto__":
            # status 를 채우는 건 apps/api/app.ts 의 onResponse/onError 훅뿐이고,
            # 그건 request.audit 를 쓴 액션에만 붙는다. auditTx/auditAsync 를
            # 직접 부르는 경로는 전부 NULL 이다 (lib/utils/audit.ts toRow).
            status = None if action in NULL_STATUS_ACTIONS else 200
        row = {
            "id": row_id if row_id is not None else self._id(),
            "account_id": account_id,
            "action": action,
            "status": status,
            # jsonb 라 그대로 중첩된다. dict 가 아닌 값(리스트/스칼라/None)도
            # jsonb 는 허용하므로 방어적 파싱 검증에 쓴다.
            "detail": detail,
            "ip": ip,
            "user_agent": user_agent,
            "source": source,
            "created_at": when,
        }
        self.rows.append(row)
        return row

    # ── 사파리 조우 한 건 ────────────────────────────────────────────
    #
    # 실제 순서를 그대로 흉내낸다 (safari.service.ts catchWild):
    #   [미끼/돌] → POKEMON_CATCH_ATTEMPT → 결과
    #   결과 = POKEMON_CATCH(성공, wildUid 없음) | POKEMON_CATCH_FAIL(flee|break_out)
    # break_out 이면 야생이 살아 있어 같은 uid 로 다시 시도할 수 있다.
    def encounter(self, acct: int, map_id: str, bump, *, lose_outcome: bool = False) -> None:
        uid = self.wild_uid()
        pdx = self.rng.choice(POKEDEX_POOL)
        lvl = self.rng.randint(2, 40)
        shiny = self.rng.random() < 0.02

        bait = rock = False
        roll = self.rng.random()
        if roll < 0.25:
            bait = True
            self.add(bump(), "SAFARI_BAIT",
                     {"uid": uid, "result": "stay" if self.rng.random() < 0.85 else "flee"},
                     account_id=acct)
        elif roll < 0.40:
            rock = True
            self.add(bump(), "SAFARI_ROCK",
                     {"uid": uid, "result": "stay" if self.rng.random() < 0.6 else "flee"},
                     account_id=acct)

        for attempt in range(self.rng.randint(1, 3)):
            self.add(bump(), "POKEMON_CATCH_ATTEMPT",
                     {"mapId": map_id, "wildUid": uid, "pokedexId": pdx, "level": lvl,
                      "isShiny": shiny, "bait": bait, "rock": rock,
                      "partyBonus": round(self.rng.uniform(0, 0.08), 4)},
                     account_id=acct)

            # 마지막 시도의 결과를 일부러 누락시킨다 (auditAsync 는 tx 밖이라
            # 실제로 유실될 수 있다). 그러면 파이프라인이 그 시도를 성공으로
            # 역산하고 caught_gap 이 벌어진다 — 그게 잡히는지 보는 프로브.
            if lose_outcome and attempt == 0:
                return

            r = self.rng.random()
            if r < 0.35:
                # 성공. ★ POKEMON_CATCH 에는 wildUid 가 없다 (실물 그대로).
                self.add(bump(), "POKEMON_CATCH",
                         {"userPokemonId": self.rng.randint(1, 99999), "pokedexId": pdx,
                          "level": lvl, "isShiny": shiny, "mapId": map_id,
                          "isS000Starter": False},
                         account_id=acct)
                return
            if r < 0.55:
                self.add(bump(), "POKEMON_CATCH_FAIL",
                         {"mapId": map_id, "wildUid": uid, "pokedexId": pdx, "level": lvl,
                          "isShiny": shiny, "reason": "flee", "fled": True},
                         account_id=acct)
                return
            self.add(bump(), "POKEMON_CATCH_FAIL",
                     {"mapId": map_id, "wildUid": uid, "pokedexId": pdx, "level": lvl,
                      "isShiny": shiny, "reason": "break_out", "fled": False},
                     account_id=acct)

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

            # 신규 가입은 계정당 정확히 **1회**다 — user.service.ts:22-29 가 이미
            # 유저가 있으면 409 로 죽고, apps/api/app.ts:112 의 onResponse 훅은
            # 4xx 를 아예 기록하지 않는다. 그래서 이 계정을 처음 본 날에만 남긴다.
            # (계정당 1회라는 성질이 지표2 신규 가입 카운터의 근거다.)
            if acct not in self.created and self.rng.random() < 0.35:
                self.created.add(acct)
                self.add(bump(), "CREATE_USER",
                         {"nickname": f"user{acct}", "gender": "male"},
                         account_id=acct, status=201)

            smap = self.rng.choice(SAFARI_POOL)
            self.add(bump(), "SAFARI_ENTER",
                     {"mapId": smap, "ticketConsumed": True, "ballsGranted": 30},
                     account_id=acct)

            # 야생 스폰은 게임루프(worker)가 남긴다. detail 에 배열이 통째로 들어가
            # 행이 무겁다 — 볼륨 관측용 컬럼(spawn_count)이 있는 이유.
            self.add(bump(), "POKEMON_SPAWN",
                     {"mapId": smap, "origin": "first_entry", "count": 3,
                      "wilds": [{"uid": f"s{i}", "pokedexId": self.rng.choice(POKEDEX_POOL),
                                 "level": self.rng.randint(2, 40), "gender": 0,
                                 "isShiny": False} for i in range(3)]},
                     account_id=acct, source="worker", user_agent=None)

            for _ in range(self.rng.randint(1, 4)):
                self.encounter(acct, smap, bump)

            # 대부분은 정상적으로 나가지만, 일부는 창을 닫아 EXIT 가 없다.
            # 짝이 안 맞는 게 정상이라는 걸 safari_session 이 견뎌야 한다.
            if self.rng.random() < 0.8:
                self.add(bump(), "SAFARI_EXIT", {"mapId": smap, "to": "p001"},
                         account_id=acct)

            bal = self.balance.setdefault(acct, self.rng.randint(20000, 90000))
            # 잔고보다 비싼 구매는 만들지 않는다 — 실제로도 ck_user_money CHECK 가 막는다.
            # 클램프하면 money_delta 항등식이 깨져 검증이 무의미해진다.
            if self.rng.random() < 0.7 and bal > 3000:
                cost = self.rng.randint(100, 3000)
                bal = bal - cost
                self.balance[acct] = bal
                self.add(bump(), "ITEM_BUY",
                         {"item": self.rng.choice(ITEM_POOL),
                          "quantity": self.rng.randint(1, 9),
                          "totalCost": cost, "money": bal},  # 거래 후 잔고
                         account_id=acct)
            if self.rng.random() < 0.5:
                gain = self.rng.randint(10, 800)
                bal = bal + gain
                self.balance[acct] = bal
                self.add(bump(), "ITEM_SELL",
                         {"item": self.rng.choice(ITEM_POOL),
                          "quantity": self.rng.randint(1, 4),
                          "totalGain": gain, "money": bal},
                         account_id=acct)
            if self.rng.random() < 0.8:
                # MAP_CHANGE 는 mapId 가 아니라 from/to 다 (apps/socket/app.ts:617)
                self.add(bump(), "MAP_CHANGE",
                         {"from": self.rng.choice(MAP_POOL), "to": self.rng.choice(MAP_POOL),
                          "x": self.rng.randint(0, 80), "y": self.rng.randint(0, 80)},
                         account_id=acct, source="socket",
                         user_agent=None)  # 소켓 경로는 user_agent 가 없다 → NULL 함정


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

    # UTC 23:30 → KST 로는 다음 날. TIMESTAMPTZ 컬럼으로 담으면 9h 밀린다.
    g.add(datetime(d2.year, d2.month, d2.day, 23, 30, 0), "POKEMON_CATCH",
          {"userPokemonId": 777001, "pokedexId": "0025", "level": 12, "isShiny": False,
           "mapId": "s001", "isS000Starter": False, "probe": "kst_boundary"},
          account_id=1)

    # 변종 pokedexId — 정수 캐스팅하면 NULL 이 되어 마스터 조인이 통째로 유실된다
    for pdx in ("0058_hisui", "0003-mega"):
        g.add(datetime(d2.year, d2.month, d2.day, 12, 0, 0), "POKEMON_CATCH",
              {"userPokemonId": 777002, "pokedexId": pdx, "level": 30, "isShiny": False,
               "mapId": "s014", "isS000Starter": False, "probe": "variant_form"},
              account_id=2)

    # 튜토리얼(s000) — ENTER 를 남기지 않고 EXIT 만 남는다. 강제 성공/샤이니라
    # 포획률·샤이니율에서 반드시 제외되어야 한다.
    g.add(datetime(d3.year, d3.month, d3.day, 9, 0, 0), "POKEMON_CATCH_ATTEMPT",
          {"mapId": "s000", "wildUid": "starter1", "pokedexId": "0001", "level": 5,
           "isShiny": True, "bait": False, "rock": False, "partyBonus": 0},
          account_id=3)
    g.add(datetime(d3.year, d3.month, d3.day, 9, 0, 30), "POKEMON_CATCH",
          {"userPokemonId": 777003, "pokedexId": "0001", "level": 5, "isShiny": True,
           "mapId": "s000", "isS000Starter": True},
          account_id=3)
    g.add(datetime(d3.year, d3.month, d3.day, 9, 5, 0), "SAFARI_EXIT",
          {"mapId": "s000", "to": "p001", "probe": "s000_exit_without_enter"},
          account_id=3)

    # 결과가 유실된 시도 — 성공으로 역산되어 caught_gap 을 벌린다
    def _bump_at(dt0):
        t = [dt0]
        def b(lo=5, hi=30):
            t[0] = t[0] + timedelta(seconds=g.rng.randint(lo, hi))
            return t[0]
        return b
    g.encounter(9, "s002", _bump_at(datetime(d3.year, d3.month, d3.day, 14, 0, 0)),
                lose_outcome=True)

    # §1-4: detail 무보증. jsonb 라 문법이 깨진 JSON 은 올 수 없지만,
    # **객체가 아닌 값**과 NULL 은 얼마든지 올 수 있다. 어느 쪽도 행을 죽이면 안 되고
    # json_extract_string 은 NULL 을 돌려줘야 한다.
    g.add(datetime(d3.year, d3.month, d3.day, 10, 0, 0), "REQUEST_REJECTED",
          "plain string detail", account_id=4, status=400)
    g.add(datetime(d3.year, d3.month, d3.day, 10, 1, 0), "REQUEST_REJECTED",
          [1, 2, 3], account_id=4, status=400)
    g.add(datetime(d3.year, d3.month, d3.day, 10, 2, 0), "LOGOUT",
          None, account_id=5)

    # ★ 쿼리스트링이 살아 있는 url. **클린 픽스처에도 넣는다** —
    #   apps/api/app.ts:150 이 request.url 을 그대로 넣으므로 이게 정상 상태다.
    #   자르는 건 이제 이쪽 책임이고(views/00_audit.sql), req_url 에 '?' 가
    #   남으면 그건 우리 마스킹이 뚫린 것이다.
    g.add(datetime(d2.year, d2.month, d2.day, 8, 0, 0), "REQUEST_REJECTED",
          {"url": "/api/auth/oauth/callback?code=SECRET123&state=abc", "method": "GET",
           "errorCode": "OAUTH_INVALID_STATE", "probe": "querystring"},
          account_id=None, status=400)
    # 같은 이유로 평문 username 도 정상 상태다 (REDACT_KEYS 에 username 이 없다).
    # audit_v 가 이걸 편의 컬럼으로 꺼내지 않는지가 검증 대상이다.
    g.add(datetime(d2.year, d2.month, d2.day, 8, 5, 0), "LOGIN_FAILED",
          {"url": "/api/auth/login", "body": {"username": "victim@example.com"},
           "method": "POST", "errorCode": "FAILED_ACCOUNT"},
          account_id=None, status=401)
    # redactBody 가 2048B 초과 시 통째로 치환하는 형태 (lib/utils/audit.ts:27)
    g.add(datetime(d3.year, d3.month, d3.day, 10, 5, 0), "REQUEST_REJECTED",
          {"url": "/api/pokemon/arrange", "body": {"_truncated": "x" * 300},
           "method": "POST", "errorCode": "DTO_INVALID"},
          account_id=4, status=400)

    # 빈 문자열 user_agent — NULL 과 구분되는지
    g.add(datetime(d3.year, d3.month, d3.day, 11, 0, 0), "LOGOUT",
          None, account_id=5, user_agent="")

    # 티켓 수지 — SAFARI_TICKET_CLAIM 한 건이 여러 장을 준다 (최대 3).
    # 건수로 세면 획득이 과소 계상되어 ticketless_enter 가 전원을 오탐한다.
    g.add(datetime(d3.year, d3.month, d3.day, 7, 0, 0), "SAFARI_TICKET_CLAIM",
          {"claimed": 3, "quantity": 3, "probe": "multi_claim"}, account_id=1)

    if dirty:
        # 마스터에 없는 pokedexId → orphan 어서션이 잡아야 한다
        g.add(datetime(d2.year, d2.month, d2.day, 9, 0, 0), "POKEMON_CATCH",
              {"userPokemonId": 777004, "pokedexId": "9999", "level": 50, "isShiny": False,
               "mapId": "s002", "isS000Starter": False},
              account_id=6)
        # 잔고 조작 — 거래로 설명되지 않는 증가.
        # → recipes/abuse/money_spike.sql ① 의 항등식이 깨져야 한다.
        cheater = 7
        g.balance[cheater] = g.balance.get(cheater, 50_000) + 5_000_000
        g.add(datetime(d2.year, d2.month, d2.day, 10, 0, 0), "ITEM_SELL",
              {"item": "rare-candy", "quantity": 1, "totalGain": 40,
               "money": g.balance[cheater], "probe": "money_manipulation"},
              account_id=cheater)

        # id 갭 — 유실 의심 신호.
        # archive-audit.sh 의 export↔DELETE 창에서 행이 사라지면 이렇게 보인다.
        # 재스윕이 없어졌으므로 이 갭은 **영구적**이다 (docs 의 알려진 결함).
        g.next_id += 50_000

    # 갭 뒤에도 데이터가 있어야 lag() 가 갭을 본다.
    # 위 루프가 이미 today 를 돌았으므로, 잔고 시계열이 겹치지 않도록 별도 계정으로.
    g.day(today, n_accounts=4, acct_offset=20)

    g.rows.sort(key=lambda r: (r["created_at"], r["id"]))

    # ── audit/ 배치로 내보낸다 ──────────────────────────────────────
    #
    # archive-audit.sh 는 5분 랙을 두고 id <= cutoff 를 통째로 가져간다.
    # 그래서 배치는 **id 구간**이고, 경로의 날짜는 이벤트일이 아니라 **아카이브일**이다.
    # 보통 둘이 같지만 자정 근처 행은 다음 날 배치에 실린다 — 아래 late 배치가 그 경우다.
    by_day: dict[date, list[dict]] = {}
    for r in g.rows:
        by_day.setdefault(r["created_at"].date(), []).append(r)

    # 자정 직전 행을 다음 날 아카이브로 옮긴다 (batch_date != 이벤트일).
    late: list[dict] = []
    if d2 in by_day:
        late = [r for r in by_day[d2] if r["created_at"].hour == 23]
        by_day[d2] = [r for r in by_day[d2] if r["created_at"].hour != 23]

    stamp_n = 0

    def emit(archive_day: date, rows: list[dict]) -> None:
        nonlocal stamp_n
        if not rows:
            return
        rows = sorted(rows, key=lambda r: r["id"])
        stamp_n += 1
        cutoff = rows[-1]["id"]
        stamp = f"{archive_day.isoformat()}T{stamp_n % 24:02d}00Z"
        write_gz(
            base / "audit" / f"{archive_day:%Y/%m/%d}" / f"audit-{stamp}-{cutoff}.jsonl.gz",
            jsonl_gz(rows),
        )

    for d, rows in sorted(by_day.items()):
        # 하루치를 두 배치로 쪼갠다 — 실제로도 주기적으로 여러 번 돈다.
        half = len(rows) // 2
        emit(d, rows[:half])
        emit(d, rows[half:])

    if late:
        emit(d2 + timedelta(days=1), late)

    # 배치가 겹쳐도 무해해야 한다 (archive-audit.sh 재실행 시나리오).
    # 같은 행을 한 번 더 올린다 — 안티조인과 DISTINCT ON 이 흡수해야 한다.
    dup_day = today - timedelta(days=1)
    if by_day.get(dup_day):
        emit(dup_day, by_day[dup_day][:5])

    # ── master/ — server 레포에서 그대로 복사 ───────────────────────
    #
    # ⚠️ prod R2 에는 아직 master/ 가 없다 (server 레포에 push-master.sh 부재).
    #    픽스처에는 넣어서 마스터 조인 경로를 검증하고, 없는 경우는
    #    fixtures/run-local.sh 가 별도로 확인한다.
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

    n_files = sum(1 for _ in base.rglob("*.jsonl.gz"))
    uniq = len({r["id"] for r in g.rows})
    origin = "server 레포 실물" if used_real else "합성(server 레포 없음)"
    print(f"  {base.relative_to(REPO)}: {uniq}행(중복제외), {n_files}개 객체, 마스터={origin}")


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
