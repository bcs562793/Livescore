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
    
    # Nesine'nin isteği engellememesi için tarayıcı kimliği (User-Agent) ekliyoruz
    req_headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Accept": "application/json"
    }
    
    # Timeout süresini 60 saniyeye çıkarıyoruz
    r = requests.get(BULTEN_URL, headers=req_headers, timeout=60)
    r.raise_for_status()
    data = r.json()

    events  = data["sg"]["EA"]           # tüm maçlar
    leagues = {l["LID"]: l for l in data["sg"]["LA"]}  # lig haritası

    basketball = [e for e in events if e.get("TYPE") == 2]
    print(f"🏀 {len(basketball)} basketbol maçı bulundu")
    return basketball, leagues


def build_rows(basketball, leagues):
    rows = []
    for e in basketball:
        lig = leagues.get(e.get("LC"), {})

        # ESD: unix milliseconds → ISO timestamptz
        esd_ms = e.get("ESD") or e.get("ED")
        if not esd_ms:
            continue
        starts_at = datetime.fromtimestamp(esd_ms / 1000, tz=timezone.utc).isoformat()

        rows.append({
            "nesine_bid":    e["C"],
            "home_team":     e.get("HN", ""),
            "away_team":     e.get("AN", ""),
            "league_name":   lig.get("N", ""),
            "country":       lig.get("CC", ""),
            "starts_at":     starts_at,
            "has_broadcast": e.get("LE", 0) == 1,
            "updated_at":    datetime.now(tz=timezone.utc).isoformat(),
        })
    return rows


def upsert(rows):
    if not rows:
        print("⚠️  Yazılacak satır yok")
        return

    r = requests.post(
        f"{SUPABASE_URL}/rest/v1/future_bball",
        headers=SB_HEADERS,
        json=rows,
        timeout=30,
    )

    if r.status_code in (200, 201):
        print(f"✅ {len(rows)} satır upsert edildi")
    else:
        print(f"❌ Supabase hata: {r.status_code} — {r.text[:300]}")
        raise SystemExit(1)


if __name__ == "__main__":
    basketball, leagues = fetch_fixtures()
    rows = build_rows(basketball, leagues)
    upsert(rows)
