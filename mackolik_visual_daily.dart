import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

// ─── Cookie-aware HTTP client ───────────────────────────────────────────────
class _CookieClient {
  final Map<String, String> _cookies = {};
  final _client = http.Client();

  Future<http.Response> get(String url,
      {String? referer, Map<String, String>? extra}) async {
    final cookieHeader =
        _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final response = await _client.get(Uri.parse(url), headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept-Language': 'tr-TR,tr;q=0.9',
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      if (referer != null) 'Referer': referer,
      ...?extra,
    });
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      for (final c in setCookie.split(',')) {
        final kv = c.trim().split(';')[0].split('=');
        if (kv.length >= 2)
          _cookies[kv[0].trim()] = kv.sublist(1).join('=').trim();
      }
    }
    return response;
  }

  void close() => _client.close();
}

// ─── Fuzzy name matching (worker'dakiyle aynı mantık) ──────────────────────
double _matchScore(String a, String b) {
  a = _normalize(a);
  b = _normalize(b);
  if (a == b) return 1.0;
  if (a.contains(b) || b.contains(a)) return 0.85;

  final wordsA = a.split(' ').toSet();
  final wordsB = b.split(' ').toSet();
  final common = wordsA.intersection(wordsB).length;
  final total = wordsA.union(wordsB).length;
  return total == 0 ? 0.0 : common / total;
}

String _normalize(String s) {
  return s
      .toLowerCase()
      .replaceAll('ı', 'i')
      .replaceAll('ğ', 'g')
      .replaceAll('ü', 'u')
      .replaceAll('ş', 's')
      .replaceAll('ö', 'o')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// ─── Visual URL fetch (mackolik_visual_test.dart'tan) ─────────────────────
Future<String?> fetchVisualUrl(int mackolikId, _CookieClient client) async {
  try {
    final pageUrl = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
    final page =
        await client.get(pageUrl, referer: 'https://arsiv.mackolik.com/');
    if (page.statusCode != 200) {
      print('   ❌ Sayfa ${page.statusCode} for mackolikId=$mackolikId');
      return null;
    }

    final body = page.body;

// DEBUG: rbid için farklı pattern'ları dene
print('   🔍 Body length: ${body.length}');
print('   🔍 Body snippet: ${body.substring(0, body.length.clamp(0, 500))}');

// Daha geniş pattern'lar dene
final rbid =
    RegExp(r'getMatchCast\s*\(\s*(\d+)').firstMatch(body)?.group(1) ??
    RegExp(r'rbid=(\d+)').firstMatch(body)?.group(1) ??
    RegExp(r'"rbid"\s*:\s*"?(\d+)"?').firstMatch(body)?.group(1) ??
    RegExp(r'performgroup\.com[^"]*rbid=(\d+)').firstMatch(body)?.group(1) ??
    RegExp(r'customerId=mackolik[^"]*[&?]rbid=(\d+)').firstMatch(body)?.group(1);
    if (rbid == null) {
      print('   ❌ rbid bulunamadı for mackolikId=$mackolikId');
      return null;
    }

    final tokenResp = await client.get(
      'https://visualisation.performgroup.com/getToken?rbid=$rbid&customerId=mackolikWeb',
      referer: pageUrl,
      extra: {
        'Origin': 'https://arsiv.mackolik.com',
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'text/plain, */*; q=0.01',
      },
    );

    final token = tokenResp.body.trim();
    if (token.contains('<errors>') || token.length < 20) {
      print('   ❌ Token hatası: $token');
      return null;
    }

    // Token expiry kontrolü
    final parts = token.split('.');
    if (parts.length == 3) {
      try {
        final payload = jsonDecode(utf8.decode(
            base64Url.decode(base64.normalize(parts[1])))) as Map;
        final exp = payload['exp'] as int?;
        if (exp != null) {
          final mins = DateTime.fromMillisecondsSinceEpoch(exp * 1000)
              .difference(DateTime.now())
              .inMinutes;
          print('   ⏱ Token: $mins dk geçerli');
        }
      } catch (_) {}
    }

    return 'https://visualisation.performgroup.com/csb/index.html?token=$token';
  } catch (e) {
    print('   ❌ fetchVisualUrl hatası: $e');
    return null;
  }
}

// ─── Ana işlem ─────────────────────────────────────────────────────────────
void main() async {
  print('🚀 Mackolik Visual Daily Sync\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  final supabaseUrl = Platform.environment['SUPABASE_URL'];
  final supabaseKey = Platform.environment['SUPABASE_KEY'] ??
      Platform.environment['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null || supabaseKey == null) {
    print('❌ SUPABASE_URL veya SUPABASE_KEY eksik');
    exit(1);
  }

  final supabase = SupabaseClient(supabaseUrl, supabaseKey);

  // ── 1. Bugünün tarihini al (DD/MM/YYYY) ──────────────────────────────────
  final now = DateTime.now().toUtc();
  final dateStr =
      '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
  print('📅 Tarih: $dateStr\n');

  // ── 2. Mackolik günün maç listesini çek ──────────────────────────────────
  print('📡 Mackolik livedata çekiliyor...');
  final mackolikResp = await http.get(
    Uri.parse('https://vd.mackolik.com/livedata?date=$dateStr'),
    headers: {
      'User-Agent': 'Mozilla/5.0',
      'Accept': 'application/json',
      'Referer': 'https://www.mackolik.com/',
    },
  );

  if (mackolikResp.statusCode != 200) {
    print('❌ Mackolik livedata ${mackolikResp.statusCode}');
    exit(1);
  }

  final mackolikData = jsonDecode(mackolikResp.body) as Map;
  print('   🔍 Top-level keys: ${mackolikData.keys.toList()}');

  // m direkt maç listesi
  final rawList = (mackolikData['m'] as List? ?? mackolikData['d'] as List? ?? []);
  print('   ${rawList.length} raw eleman bulundu');
  if (rawList.isNotEmpty) {
    print('   🔍 İlk eleman tipi: ${rawList[0].runtimeType}');
    print('   🔍 İlk eleman: ${rawList[0]}');
  }

  // Her eleman bir List: [0]=id, [2]=home, [4]=away
  final mackolikMatches = <Map<String, dynamic>>[];
  for (final item in rawList) {
    if (item is List && item.length >= 5) {
      final id = item[0];
      final home = item[2]?.toString() ?? '';
      final away = item[4]?.toString() ?? '';
      if (id != null && home.isNotEmpty && away.isNotEmpty) {
        mackolikMatches.add({
          'id': id is int ? id : int.tryParse(id.toString()),
          'home': home,
          'away': away,
        });
      }
    }
  }
  print('   ${mackolikMatches.length} parse edilebilir maç\n');
  if (mackolikMatches.isNotEmpty) {
    print('   🔍 Örnek: ${mackolikMatches[0]}');
  }

  // ── 3. Supabase'den bugünün live_matches'ini çek ──────────────────────────
  print('📡 Supabase live_matches çekiliyor...');
  // match_date yok — visual_url'si null olan TÜM maçları al
  /// YENİ:
    final dbMatches = await supabase
    .from('live_matches')
    .select('fixture_id, home_team, away_team, visual_url')
    .inFilter('status_short', ['1H', '2H', 'HT', 'ET', 'BT', 'P', 'LIVE']);

  print('   ${(dbMatches as List).length} Supabase maç bulundu\n');

  // ── 4. Eşleştirme ─────────────────────────────────────────────────────────
  print('🔗 Eşleştirme yapılıyor...\n');

  final client = _CookieClient();
  // Session cookie'yi kur
  await client.get('https://arsiv.mackolik.com/',
      referer: 'https://www.google.com/');

  int matched = 0, saved = 0, skipped = 0, failed = 0;

  for (final dbMatch in dbMatches) {
    final fixtureId = dbMatch['fixture_id'] as int;
    final homeTeam = dbMatch['home_team'] as String? ?? '';
    final awayTeam = dbMatch['away_team'] as String? ?? '';
    final existingUrl = dbMatch['visual_url'] as String?;

    // Zaten visual_url varsa atla
    if (existingUrl != null && existingUrl.isNotEmpty) {
      skipped++;
      continue;
    }

    // En iyi eşleşmeyi bul
    double bestScore = 0.0;
    Map<String, dynamic>? bestMatch;

    for (final mac in mackolikMatches) {
      final homeScore = _matchScore(homeTeam, mac['home'] as String);
      final awayScore = _matchScore(awayTeam, mac['away'] as String);
      final total = (homeScore + awayScore) / 2;
      if (total > bestScore) {
        bestScore = total;
        bestMatch = mac;
      }
    }

    if (bestScore < 0.5 || bestMatch == null) {
      print('   ⚠️  Eşleşme yok: $homeTeam vs $awayTeam (best: ${bestScore.toStringAsFixed(2)})');
      failed++;
      continue;
    }

    matched++;
    final mackolikId = bestMatch['id'] as int;
    print('   ✅ $homeTeam vs $awayTeam → mackolik:$mackolikId (score: ${bestScore.toStringAsFixed(2)})');

    // ── 5. Visual URL çek ──────────────────────────────────────────────────
    final visualUrl = await fetchVisualUrl(mackolikId, client);
    if (visualUrl == null) {
      failed++;
      continue;
    }

    // ── 6. Supabase'e yaz ─────────────────────────────────────────────────
    try {
      await supabase
          .from('live_matches')
          .update({
            'visual_url': visualUrl,
            'visual_expires_at': DateTime.now()
                .add(const Duration(hours: 4))
                .toUtc()
                .toIso8601String(),
          })
          .eq('fixture_id', fixtureId);
      print('   💾 Kaydedildi: fixture=$fixtureId');
      saved++;
    } catch (e) {
      print('   ❌ Supabase yazma hatası: $e');
      failed++;
    }

    // Rate limit için kısa bekleme
    await Future.delayed(const Duration(milliseconds: 500));
  }

  client.close();

  print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📊 Özet:');
  print('   Eşleşen:  $matched');
  print('   Kaydeden: $saved');
  print('   Atlanan:  $skipped (zaten var)');
  print('   Başarısız: $failed');
  print('✅ Tamamlandı.');
}
