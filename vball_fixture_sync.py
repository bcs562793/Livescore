import os
import requests
from datetime import datetime, timezone, timedelta

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_KEY"]

# ── API adresleri ────────────────────────────────────────────────────────────
# Birincil: ls.nesine.com GetUnliveMatches?sportType=3
#   → sportType=3 = Volleyball (LivescoreConstants.min.js'ten doğrulandı:
#     SportType:{Football:1, Basketball:2, Volleyball:3, Handball:4, Tennis:5, ...})
#   → DİKKAT: bball scriptindeki "19=voleybol" notu YANLIŞTI (19=FootballDuel).
#
# Yedek: getprebultenfull, voleybol = TYPE 23
#   → 12 Haziran 2026 HAR analizi: /iddaa/voleybol?et=23 sayfası, EA içinde
#     TYPE=23 olan 17 maç (Milletler Ligi vs). Alanlar: C, HN, AN, LC, ESD, BRID.
#   → BRID her maçta DOLU → betradar_id fixture aşamasında hazır
#     (basketboldaki gamelist/header zincirine gerek yok).
LS_BASE    = "https://ls.nesine.com/api/v2/LiveScore"
BULTEN_URL = "https://bulten.nesine.com/api/bulten/getprebultenfull"

SB_HEADERS = {
    "apikey":        SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type":  "application/json",
    "Prefer":        "resolution=merge-duplicates,return=minimal",
}

REQ_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Referer":    "https://www.nesine.com/iddaa/canli-skor/voleybol",
    "Accept":     "application/json",
}

# sportType=3 → voleybol (LivescoreConstants ile doğrulandı)
SPORT_TYPE = 3
# bülten event TYPE → voleybol
BULTEN_TYPE = 23

# Kaç gün ileriye bak (bugün dahil)
FETCH_DAYS = 3


# ── ls.nesine.com — birincil kaynak ──────────────────────────────────────────

def fetch_ls_upcoming() -> dict:
    """GetUnliveMatches?sportType=3&date=YYYY-MM-DD — alan adları bball ile aynı."""
    now = datetime.now(tz=timezone.utc)
    matches: dict[int, dict] = {}

    for delta in range(FETCH_DAYS):
        date_str = (now + timedelta(days=delta)).strftime("%Y-%m-%d")
        url = f"{LS_BASE}/GetUnliveMatches?sportType={SPORT_TYPE}&date={date_str}"
        try:
            r = requests.get(url, headers=REQ_HEADERS, timeout=15)
            if r.status_code != 200:
                print(f"⚠️  GetUnliveMatches {date_str}: HTTP {r.status_code}")
                continue
            for m in r.json().get("d", []):
                nid = m.get("C") or m.get("NID")
                if not nid:
                    continue
                nid = int(nid)
                match_date = m.get("matchDate")
                if not match_date and m.get("MDE"):
                    match_date = datetime.fromtimestamp(
                        m["MDE"] / 1000, tz=timezone.utc
                    ).isoformat()
                if not match_date:
                    continue
                matches[nid] = {
                    "nesine_bid":    str(nid),
                    "home_team":     m.get("HT") or m.get("HTTR") or "",
                    "away_team":     m.get("AT") or m.get("ATTR") or "",
                    "league_name":   m.get("L") or "",
                    "country":       m.get("FC") or "",
                    "starts_at":     match_date,
                    "has_broadcast": bool(m.get("LT") or m.get("liveCoverageInfo")),
                    # LSBRID = Sportradar ID, ls.nesine fixture seviyesinde hazır
                    # (12 Haziran 2026 canlı-skor HAR'ı ile doğrulandı)
                    "betradar_id":   m.get("LSBRID"),
                }
        except Exception as e:
            print(f"⚠️  GetUnliveMatches {date_str}: {e}")

    print(f"📡 ls.nesine.com (upcoming): {len(matches)} maç")
    return matches


def fetch_ls_live() -> dict:
    """GetLiveMatchListWithVersion?sportType=3&v=0 — şu an canlı maçlar."""
    url = f"{LS_BASE}/GetLiveMatchListWithVersion?sportType={SPORT_TYPE}&v=0"
    matches: dict[int, dict] = {}
    try:
        r = requests.get(url, headers=REQ_HEADERS, timeout=15)
        if r.status_code != 200:
            print(f"⚠️  GetLiveMatchList: HTTP {r.status_code}")
            return matches
        for m in r.json().get("d", []):
            nid = m.get("C") or m.get("NID")
            if not nid:
                continue
            nid = int(nid)
            match_date = m.get("matchDate")
            if not match_date and m.get("MDE"):
                match_date = datetime.fromtimestamp(
                    m["MDE"] / 1000, tz=timezone.utc
                ).isoformat()
            matches[nid] = {
                "nesine_bid":    str(nid),
                "home_team":     m.get("HT") or m.get("HTTR") or "",
                "away_team":     m.get("AT") or m.get("ATTR") or "",
                "league_name":   m.get("L") or "",
                "country":       m.get("FC") or "",
                "starts_at":     match_date or datetime.now(tz=timezone.utc).isoformat(),
                "has_broadcast": bool(m.get("LT") or m.get("liveCoverageInfo")),
                "betradar_id":   m.get("LSBRID"),
            }
    except Exception as e:
        print(f"⚠️  GetLiveMatchList: {e}")

    if matches:
        print(f"🔴 ls.nesine.com (live): {len(matches)} canlı maç")
    return matches


# ── Bülten: isim yedeği + BRID (betradar) kaynağı ────────────────────────────

def fetch_bulten() -> dict:
    """
    getprebultenfull → TYPE=23 voleybol maçları.
    İki amaç: (1) ls.nesine'de isim boş kalırsa yedek,
              (2) BRID → betradar_id (fixture aşamasında hazır).
    Lig adı LA listesinden LC ile çözülür (HAR'da doğrulandı:
    {"LID":2384,"N":"Milletler Ligi","CC":"VOLEYBOL-GENEL"}).
    """
    try:
        r = requests.get(BULTEN_URL, headers=REQ_HEADERS, timeout=60)
        r.raise_for_status()
        data = r.json()
        events  = data["sg"]["EA"]
        leagues = {l["LID"]: l for l in data["sg"].get("LA", [])}
        out = {}
        for e in events:
            if e.get("TYPE") != BULTEN_TYPE or not e.get("ESD"):
                continue
            nid = int(e["C"])
            lg  = leagues.get(e.get("LC", 0), {})
            out[nid] = {
                "home_team":   e.get("HN", ""),
                "away_team":   e.get("AN", ""),
                "league_name": lg.get("N", ""),
                "country":     lg.get("CC", ""),
                "betradar_id": e.get("BRID"),
                "starts_at":   datetime.fromtimestamp(
                                   e["ESD"] / 1000, tz=timezone.utc
                               ).isoformat(),
            }
        print(f"📋 Bulten: {len(out)} voleybol maçı (TYPE={BULTEN_TYPE})")
        return out
    except Exception as e:
        print(f"⚠️  Bulten: {e}")
        return {}


# ── Birleştirme & upsert ─────────────────────────────────────────────────────

def build_rows(upcoming: dict, live: dict, bulten: dict) -> list:
    """ls upcoming + live birleşir; isim/BRID bülten ile zenginleştirilir.
    ls.nesine hiç sonuç vermezse bülten tek başına da fixture kaynağıdır."""
    merged: dict[int, dict] = {**upcoming, **live}  # live öncelikli

    # ls.nesine'de hiç olmayan bülten maçlarını da ekle
    # (iddaa programına girmiş ama canlı-skor listesine düşmemiş olabilir)
    for nid, b in bulten.items():
        if nid not in merged:
            merged[nid] = {
                "nesine_bid":    str(nid),
                "home_team":     b["home_team"],
                "away_team":     b["away_team"],
                "league_name":   b["league_name"],
                "country":       b["country"],
                "starts_at":     b["starts_at"],
                "has_broadcast": False,
            }

    rows = []
    now_iso = datetime.now(tz=timezone.utc).isoformat()

    for nid, m in merged.items():
        b = bulten.get(nid)
        # ÖNEMLİ: ls.nesine isimleri İNGİLİZCE ("Brazil vs Belgium"),
        # bülten isimleri TÜRKÇE ("İran vs Arjantin") — HAR ile doğrulandı.
        # ScorePop Türkçe platform → bülten ismi VARSA tercih edilir,
        # sadece boş-doldurma yedeği değil.
        if b and b["home_team"]:
            m["home_team"]   = b["home_team"]
            m["away_team"]   = b["away_team"]
            m["league_name"] = b["league_name"] or m["league_name"]
            m["country"]     = b["country"] or m["country"]
        # BRID yedeği — ls.nesine LSBRID vermediyse bültenden tamamla
        if not m.get("betradar_id") and b and b.get("betradar_id"):
            m["betradar_id"] = b["betradar_id"]

        if not m["home_team"] and not m["away_team"]:
            print(f"  ⚠️  NID {nid}: takım ismi yok, atlandı")
            continue

        rows.append({**m, "updated_at": now_iso})

    return rows


def upsert(rows: list):
    if not rows:
        print("⚠️  Yazılacak satır yok")
        return
    url = f"{SUPABASE_URL}/rest/v1/future_vball?on_conflict=nesine_bid"
    r = requests.post(url, headers=SB_HEADERS, json=rows, timeout=30)
    if r.status_code in (200, 201):
        print(f"✅ {len(rows)} satır upsert edildi")
    else:
        print(f"❌ Supabase hata: {r.status_code} — {r.text[:300]}")
        raise SystemExit(1)


# ── Ana akış ─────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("📡 Nesine voleybol fikstürü çekiliyor…")
    print(f"   Kaynak: {LS_BASE}/GetUnliveMatches?sportType={SPORT_TYPE}")

    upcoming = fetch_ls_upcoming()
    live     = fetch_ls_live()
    bulten   = fetch_bulten()          # isim yedeği + BRID

    rows = build_rows(upcoming, live, bulten)
    print(f"🏐 Toplam {len(rows)} maç → Supabase")
    upsert(rows)
