import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

const _bilyonerBase           = 'https://www.bilyoner.com';
const _bilyonerPlatformToken  = '40CAB7292CD83F7EE0631FC35A0AFC75';
const _bilyonerDeviceId       = 'C1A34687-8F75-47E8-9FF9-1D231F05782E';
const _bilyonerAppVersion     = '3.95.2';
const _bilyonerChromeVersion  = '146';
const _bilyonerBrowserVersion = 'Chrome / v146.0.0.0';

Map<String, String> _headers() => {
  'accept':                   'application/json, text/plain, */*',
  'accept-language':          'tr',
  'accept-encoding':          'gzip, deflate, br',
  'cache-control':            'no-cache',
  'pragma':                   'no-cache',
  'referer':                  '$_bilyonerBase/canli-iddaa',
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

Future<List<Map<String, dynamic>>> fetchFixtures() async {
  final uri = Uri.parse(
    '$_bilyonerBase/api/v3/mobile/aggregator/gamelist/all/v1'
    '?tabType=9999&bulletinType=1',
  );

  for (int attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 5));
    try {
      final res = await http.get(uri, headers: _headers())
          .timeout(const Duration(seconds: 25));

      if (res.statusCode != 200) {
        print('⚠️  HTTP ${res.statusCode} (deneme ${attempt + 1}/3)');
        continue;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final events = (body['events'] as Map<String, dynamic>? ?? {})
          .values
          .whereType<Map<String, dynamic>>()
          .where((e) => (e['st'] as int? ?? 0) == 1)
          .toList();

      print('✅ ${events.length} futbol maçı alındı');
      return events;
    } catch (e) {
      print('⚠️  Hata (deneme ${attempt + 1}/3): $e');
    }
  }
  return [];
}

Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

  if (sbUrl.isEmpty || sbKey.isEmpty) {
    print('❌ SUPABASE_URL veya SUPABASE_KEY eksik');
    exit(1);
  }

  final sb = SupabaseClient(sbUrl, sbKey);
  print('📅 Fikstür senkronizasyonu — ${DateTime.now().toIso8601String()}');

  final events = await fetchFixtures();
  if (events.isEmpty) {
    print('❌ Veri alınamadı, çıkılıyor');
    exit(1);
  }

  final trNow    = DateTime.now().toUtc().add(const Duration(hours: 3));
  final todayStr = '${trNow.year}-${trNow.month.toString().padLeft(2,'0')}-${trNow.day.toString().padLeft(2,'0')}';
  final cutoffDate = trNow.add(const Duration(days: 5));
  final cutoffStr  = '${cutoffDate.year}-${cutoffDate.month.toString().padLeft(2,'0')}-${cutoffDate.day.toString().padLeft(2,'0')}';

  final filtered = events.where((ev) {
    final esd = ev['esd'] as String? ?? '';
    return esd.compareTo(todayStr) >= 0 && esd.compareTo(cutoffStr) < 0;
  }).toList();

  print('📋 $todayStr → $cutoffStr: ${filtered.length} maç');

  int upserted = 0;
  int failed   = 0;

  for (final ev in filtered) {
    final id     = (ev['id'] as num).toInt();
    final htpi   = (ev['htpi'] as num?)?.toInt();
    final atpi   = (ev['atpi'] as num?)?.toInt();
    final compId = (ev['competitionId'] as num?)?.toInt() ?? 0;
    final brdId  = (ev['brdId'] as num?)?.toInt();
    final esd    = ev['esd'] as String? ?? '';
    final dateStr = esd.length >= 10 ? esd.substring(0, 10) : todayStr;
    final isToday = dateStr == todayStr;
    final now     = DateTime.now().toIso8601String();

    final homeLogo = htpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$htpi.gif' : '';
    final awayLogo = atpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$atpi.gif' : '';
    final rawData  = jsonEncode({
      'fixture': {
        'id':        id,
        'timestamp': ((ev['esdl'] as num?)?.toInt() ?? 0) ~/ 1000,
        'status':    {'short': 'NS', 'elapsed': null},
      },
      'teams': {
        'home': {'id': htpi, 'name': ev['htn'] ?? '', 'logo': homeLogo},
        'away': {'id': atpi, 'name': ev['atn'] ?? '', 'logo': awayLogo},
      },
      'league': {'id': compId, 'name': ev['lgn'] ?? ''},
      'goals':   {'home': 0, 'away': 0},
    });

    try {
      if (isToday) {
        // live_matches — date kolonu YOK, gönderme
        await sb.from('live_matches').upsert({
          'fixture_id':   id,
          'home_team':    ev['htn'] as String? ?? '',
          'away_team':    ev['atn'] as String? ?? '',
          'home_team_id': htpi,
          'away_team_id': atpi,
          'home_logo':    homeLogo,
          'away_logo':    awayLogo,
          'home_score':   0,
          'away_score':   0,
          'status_short': 'NS',
          'elapsed_time': null,
          'league_id':    compId,
          'league_name':  ev['lgn'] as String? ?? '',
          'league_logo':  '',
          'betradar_id':  brdId,
          'score_source': 'bilyoner',
          'raw_data':     rawData,
          'updated_at':   now,
        }, onConflict: 'fixture_id');
      } else {
        // future_matches — date kolonu VAR
        await sb.from('future_matches').upsert({
          'fixture_id': id,
          'date':       dateStr,
          'league_id':  compId,
          'data':       jsonDecode(rawData),
          'updated_at': now,
        }, onConflict: 'fixture_id');
      }
      upserted++;
    } catch (e) {
      print('  ⚠️  upsert ($id): $e');
      failed++;
    }
  }

  print('');
  print('═══════════════════════════════');
  print('  ✅ Yazılan : $upserted maç');
  if (failed > 0) print('  ❌ Hatalı  : $failed maç');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(failed > 0 ? 1 : 0);
}
