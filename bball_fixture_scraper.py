import os
import requests
from datetime import datetime, timezone

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_KEY"]
BULTEN_URL = "https://cdnbulten.nesine.com/api/bulten/getprebultenfull"

SB_HEADERS = {
    "apikey": SUPABASE_KEY,
    "Authorization": f"Bearer {SUPABASE_KEY}",
    "Content-Type": "application/json",
    "Prefer": "resolution=merge-duplicates,return=minimal",
}

def fetch_fixtures():
    print("📡 Nesine fikstürü çekiliyor...")
    req_headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Accept": "application/json"
    }
    r = requests.get(BULTEN_URL, headers=req_headers, timeout=60)
    r.raise_for_status()
    data = r.json()

    events  = data["sg"]["EA"]
    leagues = {l["LID"]: l for l in data["sg"]["LA"]}

    # 🔍 DEBUG: Hangi TYPE değerleri geliyor?
    type_counts = {}
    for e in events:
        t = e.get("TYPE")
        type_counts[t] = type_counts.get(t, 0) + 1
    print(f"📊 Event TYPE dağılımı: {type_counts}")

    # 🔍 DEBUG: "Efes" veya "Telekom" geçen maçları bul (TYPE'tan bağımsız)
    suspect = [e for e in events if
               "efes" in str(e.get("HN", "")).lower() or
               "efes" in str(e.get("AN", "")).lower() or
               "telekom" in str(e.get("HN", "")).lower() or
               "telekom" in str(e.get("AN", "")).lower()]
    if suspect:
        print(f"🎯 Efes/Telekom maçı bulundu: TYPE={suspect[0].get('TYPE')}, ESD={suspect[0].get('ESD')}, data={suspect[0]}")
    else:
        print("⚠️  Efes/Telekom maçı hiç gelmiyor — API'de yok!")

    # TYPE filtresi: 2 kesin basketbol, ama BSL için farklı olabilir
    # Şimdilik 2 ve potansiyel alternatifleri dahil et
    BASKETBALL_TYPES = {2}  # Debug sonrası genişletilebilir
    basketball = [e for e in events if e.get("TYPE") in BASKETBALL_TYPES]
    print(f"🏀 {len(basketball)} basketbol maçı bulundu")
    return basketball, leagues


def build_rows(basketball, leagues):
    rows = []
    skipped = 0
    for e in basketball:
        lig = leagues.get(e.get("LC"), {})

        # ✅ DÜZELTİLDİ: 0 değerini de geçerli say, sadece None/eksik olanı atla
        esd_ms = e.get("ESD") if e.get("ESD") is not None else e.get("ED")
        if not esd_ms:
            skipped += 1
            continue

        starts_at = datetime.fromtimestamp(esd_ms / 1000, tz=timezone.utc).isoformat()

        rows.append({
            "nesine_bid":    str(e["C"]),         # string'e cast — tip uyuşmazlığı önler
            "home_team":     e.get("HN", ""),
            "away_team":     e.get("AN", ""),
            "league_name":   lig.get("N", ""),
            "country":       lig.get("CC", ""),
            "starts_at":     starts_at,
            "has_broadcast": e.get("LE", 0) == 1,
            "updated_at":    datetime.now(tz=timezone.utc).isoformat(),
        })

    if skipped:
        print(f"⏭️  {skipped} maç ESD/ED eksik olduğu için atlandı")
    return rows


def upsert(rows):
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


if __name__ == "__main__":
    basketball, leagues = fetch_fixtures()
    rows = build_rows(basketball, leagues)
    upsert(rows)
