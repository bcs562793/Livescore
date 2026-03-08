import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

// ─── SABİTLER ───
final _macHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  'Accept': 'text/html,application/json,*/*',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
};

const _statsNameMap = {
  'Topla Oynama': 'Ball Possession',
  'Toplam Şut': 'Total Shots',
  'İsabetli Şut': 'Shots on Goal',
  'İsabetsiz Şut': 'Shots off Goal',
  'Bloke Edilen Şut': 'Blocked Shots',
  'Başarılı Paslar': 'Passes accurate',
  'Pas Başarı(%)': 'Passes %',
  'Pas Başarı %': 'Passes %',
  'Korner': 'Corner Kicks',
  'Köşe Vuruşu': 'Corner Kicks',
  'Orta': 'Crosses',
  'Faul': 'Fouls',
  'Ofsayt': 'Offsides',
  'Sarı Kart': 'Yellow Cards',
  'Kırmızı Kart': 'Red Cards',
  'Kurtarış': 'Goalkeeper Saves',
  'Tehlikeli Ataklar': 'Dangerous Attacks',
  'Ataklar': 'Attacks',
};

// ─── FUZZY MATCH FONKSİYONLARI ───
String _normalize(String name) {
  return name
      .toLowerCase()
      .replaceAll('ı', 'i')
      .replaceAll('ğ', 'g')
      .replaceAll('ü', 'u')
      .replaceAll('ş', 's')
      .replaceAll('ö', 'o')
      .replaceAll('ç', 'c')
      .replaceAll('é', 'e')
      .replaceAll('á', 'a')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[^\w\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

double _teamSimilarity(String name1, String name2) {
  final n1 = _normalize(name1);
  final n2 = _normalize(name2);
  if (n1 == n2) return 1.0;
  if (n1.contains(n2) || n2.contains(n1)) return 0.9;

  final w1 = n1.split(' ').toSet();
  final w2 = n2.split(' ').toSet();
  final inter = w1.intersection(w2);
  final union = w1.union(w2);
  final jaccard = union.isEmpty ? 0.0 : inter.length / union.length;

  if (jaccard >= 0.5) return 0.7 + jaccard * 0.2;
  if (n1.length >= 3 && n2.length >= 3 && n1.substring(0, 3) == n2.substring(0, 3)) return 0.6;
  return jaccard * 0.5;
}

// ─── OTOMATİK API-FOOTBALL EŞLEŞTİRME ───
Future<Map<String, dynamic>?> _getApiFootballMatchInfo(
    int mackolikId, String apiKey) async {
  print('  🔍 [LOG] Mackolik maç sayfası inceleniyor... ID: $mackolikId');

  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  print('  🔗 [LOG] İstek atılan URL: $url');

  final res = await http
      .get(Uri.parse(url), headers: _macHeaders)
      .timeout(const Duration(seconds: 10));
  print('  📥 [LOG] Mackolik HTTP Status: ${res.statusCode}');

  final titleMatch = RegExp(
          r'<title>([^<(]+?)\s*-\s*([^<(]+?)\s*\((\d{1,2})\.(\d{1,2})\.(\d{4})\)')
      .firstMatch(res.body);

  if (titleMatch == null) {
    print('  ❌ [HATA] Beklenen tarih formatı Regex ile eşleşmedi!');
    return null;
  }

  final macHome = titleMatch.group(1)!.trim();
  final macAway = titleMatch.group(2)!.trim();
  final day = titleMatch.group(3)!.padLeft(2, '0');
  final month = titleMatch.group(4)!.padLeft(2, '0');
  final year = titleMatch.group(5)!;
  final apiDate = '$year-$month-$day';

  print('  📅 [LOG] Parse edilen tarih: $apiDate');
  print('  ⚽ [LOG] Takımlar: $macHome vs $macAway');
  print('  📡 [LOG] API-Football üzerinde aranıyor... (Tarih: $apiDate)');

  final apiRes = await http.get(
    Uri.parse('https://v3.football.api-sports.io/fixtures?date=$apiDate'),
    headers: {'x-apisports-key': apiKey},
  ).timeout(const Duration(seconds: 15));

  if (apiRes.statusCode != 200) {
    print(
        '  ❌ [HATA] API-Football isteği başarısız! Status: ${apiRes.statusCode}');
    return null;
  }

  final apiData = jsonDecode(apiRes.body);
  final fixtures = apiData['response'] as List? ?? [];

  Map<String, dynamic>? bestMatch;
  double bestScore = 0;

  for (final fixture in fixtures) {
    final teams = fixture['teams'];
    final apiHome = teams['home']['name'];
    final apiAway = teams['away']['name'];

    final homeSim = _teamSimilarity(macHome, apiHome);
    final awaySim = _teamSimilarity(macAway, apiAway);
    final combined = (homeSim + awaySim) / 2;

    if (combined > bestScore && homeSim >= 0.5 && awaySim >= 0.5) {
      bestScore = combined;
      bestMatch = fixture;
    }
  }

  if (bestMatch != null && bestScore >= 0.65) {
    print(
        '  ✅ [BAŞARILI] Eşleşti! Fixture ID: ${bestMatch['fixture']['id']} (${(bestScore * 100).toStringAsFixed(0)}% benzerlik)');
    return bestMatch;
  }

  print('  ❌ [HATA] API-Football tarafında uygun eşleşme bulunamadı.');
  return null;
}

// ─── MACKOLİK STATS HTML FETCH ───
Future<String> _macFetchStats(int mackolikId) async {
  final url =
      'https://arsiv.mackolik.com/AjaxHandlers/MatchHandler.aspx?command=optaStats&id=$mackolikId';
  try {
    final res = await http.get(Uri.parse(url), headers: {
      ..._macHeaders,
      'Referer': 'https://arsiv.mackolik.com/Mac/$mackolikId/',
    }).timeout(const Duration(seconds: 10));
    return res.statusCode == 200 ? res.body : '';
  } catch (e) {
    print('  ⚠️ Mackolik stats hatası ($mackolikId): $e');
    return '';
  }
}

// ─── STATS TRANSFORM → FİREBASE İLE AYNI FORMAT ───
// Firebase formatı: [{type: '...', homeVal: ..., awayVal: ...}]
List<Map<String, dynamic>>? _macTransformStatistics(String text) {
  if (text.trim().length < 20) return null;
  if (text.trim().startsWith('{') || text.trim().startsWith('[')) return null;

  final lines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  if (lines.isEmpty) return null;

  final stats = <Map<String, dynamic>>[];
  final int startIndex = lines[0].contains('İstatistikler') ? 1 : 0;

  dynamic _fmtVal(String raw) {
    raw = raw.trim().replaceAll('%', '').replaceAll('&nbsp;', '').trim();
    if (raw.isEmpty || raw == '-') return 0;
    if (raw.contains('/')) return raw;
    final n = num.tryParse(raw);
    return n ?? raw;
  }

  // ── Pattern 1: 3'lü gruplar (away / title / home) ──
  for (int i = startIndex; i + 2 < lines.length; i += 3) {
    final awayValue = lines[i];
    final titleRaw = lines[i + 1];
    final homeValue = lines[i + 2];

    if (titleRaw.isEmpty) continue;

    final titleEN = _statsNameMap[titleRaw] ??
        _statsNameMap[titleRaw.replaceAll('(%)', '').trim()] ??
        titleRaw;

    stats.add({
      'type': titleEN,
      'homeVal': _fmtVal(homeValue), // Firebase ile aynı alan adı
      'awayVal': _fmtVal(awayValue), // Firebase ile aynı alan adı
    });
  }

  if (stats.isNotEmpty) {
    print('  📊 [LOG] ${stats.length} istatistik başlığı işlendi (Pattern 1).');
    return stats;
  }

  // ── Pattern 2: Alternatif sıra (title ortada değilse) ──
  print('  ⚠️ [UYARI] Pattern 1 boş, alternatif deneniyor...');
  final altLines = lines
      .where((l) => !l.contains('İstatistikler'))
      .toList();

  for (int i = 0; i + 2 < altLines.length; i++) {
    final l1 = altLines[i];
    final l2 = altLines[i + 1];
    final l3 = altLines[i + 2];

    String? titleRaw;
    String? homeVal;
    String? awayVal;

    if (!_isNumeric(l1) && !l1.startsWith('%') && !l1.contains('/')) {
      titleRaw = l1; homeVal = l2; awayVal = l3;
    } else if (!_isNumeric(l2) && !l2.startsWith('%') && !l2.contains('/')) {
      titleRaw = l2; homeVal = l1; awayVal = l3;
    } else {
      continue;
    }

    final titleEN = _statsNameMap[titleRaw] ??
        _statsNameMap[titleRaw.replaceAll('(%)', '').trim()] ??
        titleRaw;

    if (!stats.any((s) => s['type'] == titleEN)) {
      stats.add({
        'type': titleEN,
        'homeVal': _fmtVal(homeVal!),
        'awayVal': _fmtVal(awayVal!),
      });
    }
  }

  if (stats.isEmpty) return null;

  print('  📊 [LOG] ${stats.length} istatistik başlığı işlendi (Pattern 2).');
  return stats;
}

bool _isNumeric(String str) => num.tryParse(str.trim()) != null;

// ─── ANA ÇALIŞTIRICI ───
void main() async {
  print('🚀 Otomatik İstatistik Botu Başlatılıyor...\n');

  final sbUrl  = Platform.environment['SUPABASE_URL']       ?? '';
  final sbKey  = Platform.environment['SUPABASE_KEY']       ?? '';
  final apiKey = Platform.environment['API_FOOTBALL_KEY']   ?? '';

  if (sbUrl.isEmpty || sbKey.isEmpty || apiKey.isEmpty) {
    print('❌ [HATA] Ortam değişkenleri eksik!');
    print('Gerekenler: SUPABASE_URL, SUPABASE_KEY, API_FOOTBALL_KEY');
    exit(1);
  }

  final sb = SupabaseClient(sbUrl, sbKey);

  // İşlenecek Mackolik ID listesi
  final List<int> mackolikIds = [
    4418306,
  ];

  int basarili = 0;
  int hatali   = 0;

  print('📋 Toplam ${mackolikIds.length} maçın istatistikleri işlenecek.\n');

  for (final mackolikId in mackolikIds) {
    print('----------------------------------------------------');
    print('⚙️  İşleniyor: Mackolik ID $mackolikId');

    // 1. API-Football eşleşmesi — OPSIYONEL, başarısız olsa da devam et
    //    mackolik_id zaten birincil anahtar olduğu için kaydı her zaman yazabiliriz.
    //    fixture_id sadece bonus eşleşme için — null olabilir.
    final apiMatch = await _getApiFootballMatchInfo(mackolikId, apiKey);
    final int? fixtureId = apiMatch?['fixture']['id'] as int?;

    if (fixtureId == null) {
      print('  ⚠️ [UYARI] API-Football eşleşmesi bulunamadı — fixture_id null olarak kaydedilecek.');
    }

    // 2. Mackolik'ten stats HTML'i çek
    print('  📊 Mackolik istatistikleri çekiliyor...');
    final statsHtml = await _macFetchStats(mackolikId);

    if (statsHtml.isEmpty || statsHtml.trim().length < 20) {
      print('  ❌ [HATA] İstatistik HTML boş veya geçersiz.');
      hatali++;
      continue;
    }

    // 3. Firebase ile AYNI formata dönüştür: [{type, homeVal, awayVal}]
    final statsData = _macTransformStatistics(statsHtml);

    if (statsData == null || statsData.isEmpty) {
      print('  ❌ [HATA] İstatistikler parse edilemedi.');
      hatali++;
      continue;
    }

    // ─────────────────────────────────────────────────────────────────
    // 4. Supabase'e yaz
    //
    //    PRIMARY KEY  → mackolik_id   (her zaman biliniyor, asla null olmaz)
    //    FOREIGN KEY  → fixture_id    (API-Football eşleşirse dolar, yoksa null)
    //
    //    Tablo şeması (öneri):
    //      CREATE TABLE match_statistics (
    //        mackolik_id  BIGINT PRIMARY KEY,
    //        fixture_id   BIGINT,          -- nullable, API-Football ID
    //        stats        JSONB NOT NULL,  -- [{type, homeVal, awayVal}]
    //        updated_at   TIMESTAMPTZ
    //      );
    // ─────────────────────────────────────────────────────────────────
    final supabasePayload = {
      'mackolik_id': mackolikId,   // ✅ BİRİNCİL ANAHTAR — asla null olmaz
      'fixture_id':  fixtureId,    // ✅ Opsiyonel — null olabilir
      'stats':       statsData,    // ✅ Firebase ile aynı alan adı ve format
      'updated_at':  DateTime.now().toUtc().toIso8601String(),
    };

    // Debug: yazılacak JSON'u göster
    final encoder = JsonEncoder.withIndent('  ');
    print('\n');
    print('═══════════════════════════════════════════════════════════');
    print('🔍 [DEBUG] SUPABASE\'E YAZILACAK JSON (FİREBASE FORMATI)');
    print('═══════════════════════════════════════════════════════════');
    print(encoder.convert(supabasePayload));
    print('═══════════════════════════════════════════════════════════\n');

    // 5. Supabase upsert — mackolik_id üzerinden çakışma kontrolü
    try {
      await sb
          .from('match_statistics')
          .upsert(supabasePayload, onConflict: 'mackolik_id');

      print('  🎉 [BAŞARILI] Veri Supabase tablosuna yazıldı.'
          '${fixtureId != null ? " (fixture_id: $fixtureId)" : " (fixture_id: yok)"}');
      basarili++;
    } catch (e) {
      print('  ❌ [HATA] Supabase Yazma Hatası: $e');
      hatali++;
    }

    await Future.delayed(const Duration(seconds: 2));
  }

  print('\n🏁 İŞLEM TAMAMLANDI!');
  print('✅ Başarılı: $basarili');
  print('❌ Hatalı:   $hatali');
  exit(0);
}
