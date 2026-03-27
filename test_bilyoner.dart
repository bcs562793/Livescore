import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _bilyonerBase           = 'https://www.bilyoner.com';
const _bilyonerPlatformToken  = '40CAB7292CD83F7EE0631FC35A0AFC75';
const _bilyonerDeviceId       = 'C1A34687-8F75-47E8-9FF9-1D231F05782E';
const _bilyonerAppVersion     = '3.95.2';
const _bilyonerChromeVersion  = '146';
const _bilyonerBrowserVersion = 'Chrome / v146.0.0.0';

Map<String, String> getBilyonerHeaders({bool isLive = false}) {
  return {
    'accept':                   'application/json, text/plain, */*',
    'accept-language':          'tr',
    'accept-encoding':          'gzip, deflate, br',
    'cache-control':            'no-cache',
    'pragma':                   'no-cache',
    'referer':                  isLive
        ? '$_bilyonerBase/canli-iddaa'
        : '$_bilyonerBase/iddaa',
    'sec-ch-ua':                '"Chromium";v="$_bilyonerChromeVersion", "Not-A.Brand";v="24", "Google Chrome";v="$_bilyonerChromeVersion"',
    'sec-ch-ua-mobile':         '?0',
    'sec-ch-ua-platform':       '"macOS"',
    'sec-fetch-dest':           'empty',
    'sec-fetch-mode':           'cors',
    'sec-fetch-site':           'same-origin',
    'user-agent':               'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$_bilyonerChromeVersion.0.0.0 Safari/537.36',
    'platform-token':           _bilyonerPlatformToken,
    'x-client-app-version':     _bilyonerAppVersion,
    'x-client-browser-version': _bilyonerBrowserVersion,
    'x-client-channel':         'WEB',
    'x-device-id':              _bilyonerDeviceId,
  };
}

Future<void> testGamelist({required int tabType, required int bulletinType}) async {
  final tag = 'tabType=$tabType&bulletinType=$bulletinType';
  final uri = Uri.parse(
    '$_bilyonerBase/api/v3/mobile/aggregator/gamelist/all/v1'
    '?tabType=$tabType&bulletinType=$bulletinType',
  );

  print('\n─── TEST: $tag ───────────────────────────────');
  print('URL: $uri');

  final client = http.Client();
  try {
    final stopwatch = Stopwatch()..start();
    final res = await client
        .get(uri, headers: getBilyonerHeaders(isLive: tabType == 9999))
        .timeout(const Duration(seconds: 20));
    stopwatch.stop();

    print('HTTP ${res.statusCode}  (${stopwatch.elapsedMilliseconds}ms)');
    print('Content-Type: ${res.headers['content-type']}');
    print('Content-Length: ${res.contentLength ?? res.body.length} bytes');

    // Bot engeli kontrolü
    if (res.statusCode == 403) { print('❌ ENGEL: HTTP 403 Forbidden'); return; }
    if (res.statusCode == 429) { print('❌ ENGEL: HTTP 429 Too Many Requests'); return; }
    if (res.statusCode != 200) { print('❌ Beklenmedik status: ${res.statusCode}'); return; }

    final body = res.body.trim();
    if (body.isEmpty) { print('❌ ENGEL: Boş yanıt'); return; }
    if (body.startsWith('<!DOCTYPE') || body.startsWith('<html')) {
      print('❌ ENGEL: JSON beklendi, HTML döndü (Cloudflare/captcha)');
      print('   İlk 300 karakter: ${body.substring(0, body.length.clamp(0, 300))}');
      return;
    }

    // JSON parse
    late Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      print('❌ JSON parse hatası: $e');
      print('   İlk 200 karakter: ${body.substring(0, body.length.clamp(0, 200))}');
      return;
    }

    final eventsRaw = json['events'] as Map<String, dynamic>? ?? {};
    print('✅ events alanı: ${eventsRaw.length} kayıt');

    if (eventsRaw.isEmpty) {
      print('⚠️  events boş — muhtemelen bot engeli veya maç yok');
      // Tüm top-level anahtarları yazdır
      print('   Top-level keys: ${json.keys.toList()}');
      return;
    }

    // Futbol filtresi (st=1)
    final football = eventsRaw.values
        .whereType<Map<String, dynamic>>()
        .where((e) => (e['st'] as int? ?? 0) == 1)
        .toList();
    print('   Futbol maçları (st=1): ${football.length}');

    // İlk 3 maçı detaylı yazdır
    for (int i = 0; i < football.length.clamp(0, 3); i++) {
      final ev = football[i];
      final id    = ev['id'];
      final htn   = ev['htn'] ?? '?';
      final atn   = ev['atn'] ?? '?';
      final lgn   = ev['lgn'] ?? '?';
      final esd   = ev['esd'] ?? '?';
      final hls   = ev['hls'] ?? false;
      print('   [$i] id=$id  $htn vs $atn  |  $lgn  |  esd=$esd  hls=$hls');
    }
    if (football.length > 3) {
      print('   ... ve ${football.length - 3} maç daha');
    }

  } catch (e) {
    print('❌ İstek hatası: $e');
  } finally {
    client.close();
  }
}

Future<void> testLiveScores(List<int> ids) async {
  if (ids.isEmpty) { print('\n─── LIVE SCORE: test edilecek id yok ───'); return; }
  print('\n─── TEST: live-score (${ids.length} id) ──────────────────');

  final chunk = ids.take(5).toList();
  final eventListParam = '1:${chunk.join(';')}';
  final uri = Uri.parse(
    '$_bilyonerBase/api/mobile/live-score/event/v2/sport-list'
    '?eventList=$eventListParam',
  );
  print('URL: $uri');

  final client = http.Client();
  try {
    final res = await client
        .get(uri, headers: getBilyonerHeaders(isLive: true))
        .timeout(const Duration(seconds: 15));

    print('HTTP ${res.statusCode}');
    if (res.statusCode != 200) { print('❌ ${res.statusCode}'); return; }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final events = json['events'] as List? ?? [];
    print('✅ live-score events: ${events.length}');
    for (final ev in events.take(3)) {
      if (ev is Map<String, dynamic>) {
        final sbsId = ev['sbsEventId'];
        final sport = ev['sportType'];
        final cs    = ev['currentScore'] as Map? ?? {};
        print('   sbsId=$sbsId  sport=$sport  score=${cs['home']}-${cs['away']}  status=${cs['type']}');
      }
    }
  } catch (e) {
    print('❌ live-score hatası: $e');
  } finally {
    client.close();
  }
}

Future<void> main() async {
  print('═══════════════════════════════════════════════');
  print('  Bilyoner Bağlantı Testi');
  print('  ${DateTime.now().toIso8601String()}');
  print('═══════════════════════════════════════════════');

  // 1. Canlı iddaa (tabType=9999, bulletinType=1)
  await testGamelist(tabType: 9999, bulletinType: 1);

  // 2. İddaa / zamanlanmış (tabType=9999, bulletinType=2)
  await testGamelist(tabType: 9999, bulletinType: 2);

  // 3. Live-score endpoint — gamelist'ten ilk 5 futbol id'sini al
  final uri = Uri.parse(
    '$_bilyonerBase/api/v3/mobile/aggregator/gamelist/all/v1'
    '?tabType=9999&bulletinType=1',
  );
  final client = http.Client();
  try {
    final res = await client
        .get(uri, headers: getBilyonerHeaders(isLive: true))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 200) {
      final json    = jsonDecode(res.body) as Map<String, dynamic>;
      final events  = (json['events'] as Map<String, dynamic>? ?? {}).values
          .whereType<Map<String, dynamic>>()
          .where((e) => (e['st'] as int? ?? 0) == 1)
          .toList();
      final ids     = events.take(5).map((e) => (e['id'] as num).toInt()).toList();
      await testLiveScores(ids);
    }
  } catch (_) {} finally {
    client.close();
  }

  print('\n═══════════════════════════════════════════════');
  print('  Test tamamlandı');
  print('═══════════════════════════════════════════════');
  exit(0);
}
