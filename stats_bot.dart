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
  'Topla Oynama':     'Ball Possession',
  'Toplam Şut':       'Total Shots',
  'İsabetli Şut':     'Shots on Goal',
  'İsabetsiz Şut':    'Shots off Goal',
  'Bloke Edilen Şut': 'Blocked Shots',
  'Başarılı Paslar':  'Passes accurate',
  'Pas Başarı(%)':    'Passes %',
  'Pas Başarı %':     'Passes %',
  'Pas Başarı()':     'Passes %',
  'Korner':           'Corner Kicks',
  'Köşe Vuruşu':      'Corner Kicks',
  'Orta':             'Crosses',
  'Faul':             'Fouls',
  'Ofsayt':           'Offsides',
  'Sarı Kart':        'Yellow Cards',
  'Kırmızı Kart':     'Red Cards',
  'Kurtarış':         'Goalkeeper Saves',
  'Tehlikeli Ataklar':'Dangerous Attacks',
  'Ataklar':          'Attacks',
};

// ─── FUZZY MATCH FONKSİYONLARI ───
String _normalize(String name) {
  return name
      .toLowerCase()
      .replaceAll('ı', 'i').replaceAll('ğ', 'g').replaceAll('ü', 'u')
      .replaceAll('ş', 's').replaceAll('ö', 'o').replaceAll('ç', 'c')
      .replaceAll('é', 'e').replaceAll('á', 'a').replaceAll('ñ', 'n')
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
  final res = await http
      .get(Uri.parse(url), headers: _macHeaders)
      .timeout(const Duration(seconds: 10));
  print('  📥 [LOG] Mackolik HTTP Status: ${res.statusCode}');

  final titleMatch = RegExp(
      r'<title>([^<(]+?)\s*-\s*([^<(]+?)\s*\((\d{1,2})\.(\d{1,2})\.(\d{4})\)')
      .firstMatch(res.body);

  if (titleMatch == null) {
    print('  ❌ [HATA] Title parse edilemedi!');
    return null;
  }

  final macHome = titleMatch.group(1)!.trim();
  final macAway = titleMatch.group(2)!.trim();
  final day     = titleMatch.group(3)!.padLeft(2, '0');
  final month   = titleMatch.group(4)!.padLeft(2, '0');
  final year    = titleMatch.group(5)!;
  final apiDate = '$year-$month-$day';

  print('  📅 [LOG] Tarih: $apiDate | Takımlar: $macHome vs $macAway');

  final apiRes = await http.get(
    Uri.parse('https://v3.football.api-sports.io/fixtures?date=$apiDate'),
    headers: {'x-apisports-key': apiKey},
  ).timeout(const Duration(seconds: 15));

  if (apiRes.statusCode != 200) {
    print('  ❌ [HATA] API-Football başarısız! Status: ${apiRes.statusCode}');
    return null;
  }

  final fixtures = (jsonDecode(apiRes.body)['response'] as List? ?? []);

  Map<String, dynamic>? bestMatch;
  double bestScore = 0;

  for (final fixture in fixtures) {
    final teams    = fixture['teams'];
    final apiHome  = teams['home']['name'] as String;
    final apiAway  = teams['away']['name'] as String;
    final homeSim  = _teamSimilarity(macHome, apiHome);
    final awaySim  = _teamSimilarity(macAway, apiAway);
    final combined = (homeSim + awaySim) / 2;

    if (combined > bestScore && homeSim >= 0.5 && awaySim >= 0.5) {
      bestScore = combined;
      bestMatch = fixture;
    }
  }

  if (bestMatch != null && bestScore >= 0.65) {
    print('  ✅ Eşleşti! Fixture ID: ${bestMatch['fixture']['id']}'
        ' (${(bestScore * 100).toStringAsFixed(0)}%)');
    return bestMatch;
  }

  print('  ❌ [HATA] API-Football eşleşmesi bulunamadı.');
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
    print('  ⚠️ Stats fetch hatası: $e');
    return '';
  }
}

// ─── STATS PARSE — NODE.JS SCRAPER İLE AYNI REGEX MANTIĞI ───
//
// Mackolik HTML yapısı:
//   <div class="team-1-statistics-text">27</div>   ← home değer
//   <div class="statistics-title-text">Topla Oynama</div>  ← başlık
//   <div class="team-2-statistics-text">%73</div>   ← away değer
//
// Node.js scraper'daki parseStatsHtml() ile birebir aynı mantık.
List<Map<String, dynamic>>? _parseStatsHtml(String html) {
  if (html.trim().length < 20) return null;

  final stats = <Map<String, dynamic>>[];

  dynamic parseVal(String v) {
    v = v.trim().replaceAll('%', '').replaceAll('&nbsp;', '').trim();
    if (v.isEmpty || v == '-') return 0;
    if (v.contains('/')) return v;   // "5/23" gibi değerler string kalır
    final n = num.tryParse(v);
    return n ?? v;
  }

  // Regex: home → title → away sırasıyla yakala
  final pattern = RegExp(
    r'class="team-1-statistics-text"[^>]*>([\s\S]*?)<\/div>'
    r'[\s\S]*?'
    r'class="statistics-title-text"[^>]*>([\s\S]*?)<\/div>'
    r'[\s\S]*?'
    r'class="team-2-statistics-text"[^>]*>([\s\S]*?)<\/div>',
  );

  for (final m in pattern.allMatches(html)) {
    // HTML tag'lerini temizle
    final homeRaw = m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    final titleTR = m.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    final awayRaw = m.group(3)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();

    if (titleTR.isEmpty || homeRaw.isEmpty || awayRaw.isEmpty) continue;

    final titleEN = _statsNameMap[titleTR] ??
        _statsNameMap[titleTR.replaceAll('(%)', '').trim()] ??
        titleTR;

    stats.add({
      'type':    titleEN,
      'homeVal': parseVal(homeRaw),
      'awayVal': parseVal(awayRaw),
    });
  }

  if (stats.isNotEmpty) {
    print('  📊 [LOG] ${stats.length} istatistik parse edildi.');
    return stats;
  }

  print('  ⚠️ [UYARI] Regex eşleşmedi, ham HTML (ilk 200): '
      '${html.substring(0, html.length > 200 ? 200 : html.length).replaceAll('\n', ' ')}');
  return null;
}

// ─── ANA ÇALIŞTIRICI ───
void main() async {
  print('🚀 Stats Bot Başlatılıyor...\n');

  final sbUrl  = Platform.environment['SUPABASE_URL']     ?? '';
  final sbKey  = Platform.environment['SUPABASE_KEY']     ?? '';
  final apiKey = Platform.environment['API_FOOTBALL_KEY'] ?? '';

  if (sbUrl.isEmpty || sbKey.isEmpty || apiKey.isEmpty) {
    print('❌ Eksik env: SUPABASE_URL, SUPABASE_KEY, API_FOOTBALL_KEY');
    exit(1);
  }

  final sb = SupabaseClient(sbUrl, sbKey);

  final List<int> mackolikIds = [
    4418306,
  ];

  int basarili = 0, hatali = 0;
  print('📋 ${mackolikIds.length} maç işlenecek.\n');

  for (final mackolikId in mackolikIds) {
    print('----------------------------------------------------');
    print('⚙️  Mackolik ID: $mackolikId');

    // 1. fixture_id al — ZORUNLU
    final apiMatch = await _getApiFootballMatchInfo(mackolikId, apiKey);
    if (apiMatch == null) {
      print('  ❌ fixture_id alınamadı, atlanıyor.');
      hatali++;
      continue;
    }
    final int fixtureId = apiMatch['fixture']['id'] as int;

    // 2. Stats HTML çek
    print('  📡 Mackolik stats çekiliyor...');
    final statsHtml = await _macFetchStats(mackolikId);

    if (statsHtml.isEmpty || statsHtml.trim().length < 20) {
      print('  ❌ Stats HTML boş.');
      hatali++;
      continue;
    }

    // 3. HTML'den değerleri regex ile parse et (Node.js ile aynı mantık)
    final statsData = _parseStatsHtml(statsHtml);

    if (statsData == null || statsData.isEmpty) {
      print('  ❌ Stats parse edilemedi.');
      hatali++;
      continue;
    }

    // 4. Payload — sadece tabloda var olan kolonlar
    //
    //    Tablo şeması:
    //      CREATE TABLE match_statistics (
    //        fixture_id  BIGINT PRIMARY KEY,
    //        stats       JSONB NOT NULL,
    //        updated_at  TIMESTAMPTZ
    //      );
    final supabasePayload = {
      'fixture_id': fixtureId,
      'stats':      statsData,   // [{type, homeVal, awayVal}] — Firebase ile aynı
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    final encoder = JsonEncoder.withIndent('  ');
    print('\n═══════════════════════════════════════════════════════════');
    print('🔍 [DEBUG] YAZILACAK JSON');
    print('═══════════════════════════════════════════════════════════');
    print(encoder.convert(supabasePayload));
    print('═══════════════════════════════════════════════════════════\n');

    // 5. Upsert
    try {
      await sb
          .from('match_statistics')
          .upsert(supabasePayload, onConflict: 'fixture_id');
      print('  🎉 Yazıldı. fixture_id=$fixtureId');
      basarili++;
    } catch (e) {
      print('  ❌ Supabase Hatası: $e');
      hatali++;
    }

    await Future.delayed(const Duration(seconds: 2));
  }

  print('\n🏁 TAMAMLANDI — ✅ $basarili başarılı | ❌ $hatali hatalı');
  exit(0);
}
