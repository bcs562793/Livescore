import os
import time
import requests
from datetime import datetime, timezone, timedelta

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_KEY"]

# ── API adresleri ────────────────────────────────────────────────────────────
# ESKI: cdnbulten.nesine.com/api/bulten/getprebultenfull
#   → Yalnızca iddaa kuponu olan maçları kapsar, CDN önbelleği geç güncellenir.
#   → Playoff/geç eklenen maçlar eksik kalıyordu (örn. Fenerbahçe – Anadolu Efes).
#
# YENİ: ls.nesine.com/api/v2/LiveScore/GetUnliveMatches?sportType=2
#   → Nesine'nin "Canlı Skor > Basketbol" sayfasının kullandığı endpoint.
#   → Takım adı (HT/AT), lig (L), ülke (FC), tarih (matchDate) dahil her şeyi verir.
#   → İddaa dışı (LE=0) maçları da içerir.
LS_BASE    = "https://ls.nesine.com/api/v2/LiveScore"
BULTEN_URL = "https://bulten.nesine.com/api/bulten/getprebultenfull"  # yedek

SB_HEADERS = {
    "apikey":        SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type":  "application/json",
    "Prefer":        "resolution=merge-duplicates,return=minimal",
}

REQ_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Referer":    "https://www.nesine.com/iddaa/canli-skor/basketbol",
    "Accept":     "application/json",
}

# sportType=2 → basketbol (HAR analizi ile doğrulandı)
# GetLiveScoreMenu: [1=futbol, 2=basketbol, 5=tenis, 3=basketbol2?, 4=hokey, 19=voleybol, 8=masa tenisi]
SPORT_TYPE = 2

# Kaç gün ileriye bak (bugün dahil)
FETCH_DAYS = 3


# ── ls.nesine.com — birincil kaynak ──────────────────────────────────────────

def fetch_ls_upcoming() -> dict:
    """
    GetUnliveMatches?sportType=2&date=YYYY-MM-DD  →  {"C": nid, "HT": ev, "AT": dep, ...}

    HAR'da doğrulanan alan isimleri:
      C / NID  → nesine_bid
      HT       → home_team
      AT       → away_team
      L        → league_name
      FC       → country_code
      matchDate → starts_at (UTC ISO string)
      LT / liveCoverageInfo → has_broadcast (bool)
    """
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
                # matchDate yoksa MDE (ms epoch) kullan
                match_date = m.get("matchDate")
                if not match_date and m.get("MDE"):
                    match_date = datetime.fromtimestamp(
                        m["MDE"] / 1000, tz=timezone.utc
                    ).isoformat()
                if not match_date:
                    continue
                # HT/AT boşsa LE=0 gibi özel maç olabilir, yine de ekle
                matches[nid] = {
                    "nesine_bid":    str(nid),
                    "home_team":     m.get("HT") or m.get("HTTR") or "",
                    "away_team":     m.get("AT") or m.get("ATTR") or "",
                    "league_name":   m.get("L") or "",
                    "country":       m.get("FC") or "",
                    "starts_at":     match_date,
                    "has_broadcast": bool(m.get("LT") or m.get("liveCoverageInfo")),
                }
        except Exception as e:
            print(f"⚠️  GetUnliveMatches {date_str}: {e}")

    print(f"📡 ls.nesine.com (upcoming): {len(matches)} maç")
    return matches


def fetch_ls_live() -> dict:
    """
    GetLiveMatchListWithVersion?sportType=2&v=0  →  şu an canlı olan maçlar.
    Yapı GetUnliveMatches ile aynı; alan adları birebir örtüşür.
    """
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
            }
    except Exception as e:
        print(f"⚠️  GetLiveMatchList: {e}")

    if matches:
        print(f"🔴 ls.nesine.com (live): {len(matches)} canlı maç")
    return matches


# ── Yedek: bulten'den eksik takım ismi tamamla ───────────────────────────────

def fetch_bulten_names() -> dict:
    """
    getprebultenfull'dan TYPE=2 maçların HN/AN isimlerini çek.
    ls.nesine'de isim boş gelen nadir durumlar için yedek.
    """
    try:
        r = requests.get(BULTEN_URL, headers=REQ_HEADERS, timeout=60)
        r.raise_for_status()
        data = r.json()
        events = data["sg"]["EA"]
        leagues = {l["LID"]: l for l in data["sg"]["LA"]}
        names = {}
        for e in events:
            if e.get("TYPE") != 2 or not e.get("ESD"):
                continue
            nid = int(e["C"])
            names[nid] = {
                "home_team":   e.get("HN", ""),
                "away_team":   e.get("AN", ""),
                "league_name": leagues.get(e.get("LC", 0), {}).get("N", ""),
                "country":     leagues.get(e.get("LC", 0), {}).get("CC", ""),
            }
        print(f"📋 Bulten (yedek): {len(names)} basketbol ismi")
        return names
    except Exception as e:
        print(f"⚠️  Bulten yedek: {e}")
        return {}


# ── Birleştirme & upsert ─────────────────────────────────────────────────────

def build_rows(upcoming: dict, live: dict, bulten_names: dict) -> list:
    """ls upcoming + live maçlarını birleştir; isim boşsa bulten'den tamamla."""
    merged: dict[int, dict] = {**upcoming, **live}  # live öncelikli

    rows = []
    now_iso = datetime.now(tz=timezone.utc).isoformat()

    for nid, m in merged.items():
        # İsim boşsa bulten'den tamamla
        if not m["home_team"] and nid in bulten_names:
            m["home_team"]   = bulten_names[nid]["home_team"]
            m["away_team"]   = bulten_names[nid]["away_team"]
            m["league_name"] = bulten_names[nid]["league_name"] or m["league_name"]
            m["country"]     = bulten_names[nid]["country"] or m["country"]

        # Her iki taraf da boşsa atla
        if not m["home_team"] and not m["away_team"]:
            print(f"  ⚠️  NID {nid}: takım ismi yok, atlandı")
            continue

        rows.append({**m, "updated_at": now_iso})

    return rows


def upsert(rows: list):
    if not rows:
        print("⚠️  Yazılacak satır yok")
        return
    url = f"{SUPABASE_URL}/rest/v1/future_bball?on_conflict=nesine_bid"
    r = requests.post(url, headers=SB_HEADERS, json=rows, timeout=30)
    if r.status_code in (200, 201):
        print(f"✅ {len(rows)} satır upsert edildi")
    else:
        print(f"❌ Supabase hata: {r.status_code} — {r.text[:300]}")
        raise SystemExit(1)


# ── Ana akış ─────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("📡 Nesine basketbol fikstürü çekiliyor…")
    print(f"   Kaynak: {LS_BASE}/GetUnliveMatches?sportType={SPORT_TYPE}")

    upcoming     = fetch_ls_upcoming()
    live         = fetch_ls_live()
    bulten_names = fetch_bulten_names()      # isim boşsa yedek

    rows = build_rows(upcoming, live, bulten_names)
    print(f"🏀 Toplam {len(rows)} maç → Supabase")
    upsert(rows)
