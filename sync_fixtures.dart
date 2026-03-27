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

Map<String, String> _headers({bool isLive = true}) => {
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

// ─── Bilyoner esdl (ms) → "2026-03-27T22:45:00+03:00" ───────────
String _toIsoTR(int esdMs) {
  if (esdMs == 0) return '';
  final utc = DateTime.fromMillisecondsSinceEpoch(esdMs, isUtc: true);
  final tr  = utc.add(const Duration(hours: 3));
  final pad = (int n) => n.toString().padLeft(2, '0');
  return '${tr.year}-${pad(tr.month)}-${pad(tr.day)}'
      'T${pad(tr.hour)}:${pad(tr.minute)}:00+03:00';
}

// ─── API call ────────────────────────────────────────────────────
Future<List<Map<String, dynamic>>> _fetchGamelist({
  required int tabType,
  required int bulletinType,
}) async {
  final uri = Uri.parse(
    '$_bilyonerBase/api/v3/mobile/aggregator/gamelist/all/v1'
    '?tabType=$tabType&bulletinType=$bulletinType',
  );

  for (int attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 5));
    try {
      final res = await http
          .get(uri, headers: _headers(isLive: bulletinType == 1))
          .timeout(const Duration(seconds: 25));

      if (res.statusCode == 403 || res.statusCode == 429) {
        print('⚠️  Engel [${res.statusCode}] (deneme ${attempt + 1}/3)');
        await Future.delayed(Duration(seconds: (attempt + 1) * 10));
        continue;
      }
      if (res.statusCode != 200) {
        print('⚠️  HTTP ${res.statusCode} (deneme ${attempt + 1}/3)');
        continue;
      }

      final body      = jsonDecode(res.body) as Map<String, dynamic>;
      final eventsRaw = body['events'] as Map<String, dynamic>? ?? {};

      if (eventsRaw.isEmpty) {
        print('⚠️  events boş (bulletinType=$bulletinType, deneme ${attempt + 1}/3)');
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: (attempt + 1) * 15));
          continue;
        }
        return [];
      }

      // st=1 → futbol
      final football = eventsRaw.values
          .whereType<Map<String, dynamic>>()
          .where((e) => (e['st'] as int? ?? 0) == 1)
          .toList();

      print('📋 bulletinType=$bulletinType: ${eventsRaw.length} toplam → ${football.length} futbol');
      return football;
    } catch (e) {
      print('⚠️  Hata (deneme ${attempt + 1}/3): $e');
    }
  }
  return [];
}

// ─── Event → raw_data (API-Football uyumlu format) ───────────────
Map<String, dynamic> _buildRawData(
  Map<String, dynamic> ev, {
  int homeScore = 0,
  int awayScore = 0,
  String statusShort = 'NS',
}) {
  final id    = (ev['id']   as num).toInt();
  final htpi  = (ev['htpi'] as num?)?.toInt();
  final atpi  = (ev['atpi'] as num?)?.toInt();
  final esdMs = (ev['esdl'] as num?)?.toInt() ?? 0;
  final dateStr = _toIsoTR(esdMs);          // ✅ FIX: fixture.date eklendi

  return {
    'fixture': {
      'id':        id,
      'timestamp': esdMs ~/ 1000,
      'date':      dateStr,                 // ✅ frontend bu alanı okuyor
      'timezone':  'Europe/Istanbul',
      'referee':   null,
      'periods':   {'first': null, 'second': null},
      'venue':     {'id': null, 'name': null, 'city': null},
      'status': {
        'long':    statusShort == 'NS' ? 'Not Started' : statusShort,
        'short':   statusShort,
        'elapsed': null,
        'extra':   null,
      },
    },
    'teams': {
      'home': {
        'id':     htpi,
        'name':   ev['htn'] ?? '',
        'logo':   htpi != null
            ? 'https://im.mackolik.com/img/logo/buyuk/$htpi.gif'
            : '',
        'winner': null,
      },
      'away': {
        'id':     atpi,
        'name':   ev['atn'] ?? '',
        'logo':   atpi != null
            ? 'https://im.mackolik.com/img/logo/buyuk/$atpi.gif'
            : '',
        'winner': null,
      },
    },
    'league': {
      'id':       (ev['competitionId'] as num?)?.toInt() ?? 0,
      'name':     ev['lgn'] ?? '',
      'logo':     '',
      'country':  '',
      'flag':     null,
      'season':   null,
      'round':    null,
      'standings': false,
    },
    'goals': {'home': homeScore, 'away': awayScore},
    'score': {
      'halftime':  {'home': null, 'away': null},
      'fulltime':  {'home': null, 'away': null},
      'extratime': {'home': null, 'away': null},
      'penalty':   {'home': null, 'away': null},
    },
  };
}

Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

  if (sbUrl.isEmpty || sbKey.isEmpty) {
    print('❌ SUPABASE_URL veya SUPABASE_KEY eksik');
    exit(1);
  }

  final sb  = SupabaseClient(sbUrl, sbKey);
  final trNow    = DateTime.now().toUtc().add(const Duration(hours: 3));
  final todayStr = '${trNow.year}-${trNow.month.toString().padLeft(2,'0')}-${trNow.day.toString().padLeft(2,'0')}';

  print('📅 Fikstür senkronizasyonu — ${DateTime.now().toIso8601String()}');
  print('🗓  Bugün: $todayStr');

  // ═══ 1) Bugünkü maçlar: bulletinType=1 (live/NS) ════════════════
  print('\n── Bugünkü maçlar (bulletinType=1) ──');
  final todayEvents = await _fetchGamelist(tabType: 9999, bulletinType: 1);

  int todayUpserted = 0, todayFailed = 0;
  for (final ev in todayEvents) {
    final esd = ev['esd'] as String? ?? '';
    if (!esd.startsWith(todayStr)) continue;          // sadece bugün

    final id     = (ev['id']   as num).toInt();
    final htpi   = (ev['htpi'] as num?)?.toInt();
    final atpi   = (ev['atpi'] as num?)?.toInt();
    final compId = (ev['competitionId'] as num?)?.toInt() ?? 0;
    final brdId  = (ev['brdId'] as num?)?.toInt();
    final now    = DateTime.now().toIso8601String();
    final rawData = _buildRawData(ev);

    try {
      await sb.from('live_matches').upsert({
        'fixture_id':   id,
        'home_team':    ev['htn'] as String? ?? '',
        'away_team':    ev['atn'] as String? ?? '',
        'home_team_id': htpi,
        'away_team_id': atpi,
        'home_logo':    htpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$htpi.gif' : '',
        'away_logo':    atpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$atpi.gif' : '',
        'home_score':   0,
        'away_score':   0,
        'status_short': 'NS',
        'elapsed_time': null,
        'league_id':    compId,
        'league_name':  ev['lgn'] as String? ?? '',
        'league_logo':  '',
        'betradar_id':  brdId,
        'score_source': 'bilyoner',
        'raw_data':     jsonEncode(rawData),
        'updated_at':   now,
      }, onConflict: 'fixture_id');
      todayUpserted++;
    } catch (e) {
      print('  ⚠️  live_matches upsert ($id): $e');
      todayFailed++;
    }
  }
  print('✅ Bugün: $todayUpserted yazıldı${todayFailed > 0 ? ", $todayFailed hatalı" : ""}');

  // ═══ 2) Gelecek maçlar: bulletinType=2 (zamanlanmış/iddaa) ══════
  print('\n── Gelecek maçlar (bulletinType=2) ──');
  List<Map<String, dynamic>> futureEvents = await _fetchGamelist(tabType: 9999, bulletinType: 2);

  // Fallback: bulletinType=2 boşsa bulletinType=1'den gelecek günleri al
  if (futureEvents.isEmpty) {
    print('⚠️  bulletinType=2 boş — bulletinType=1 fallback');
    futureEvents = todayEvents;
  }

  final cutoffDate = trNow.add(const Duration(days: 5));
  final cutoffStr  = '${cutoffDate.year}-${cutoffDate.month.toString().padLeft(2,'0')}-${cutoffDate.day.toString().padLeft(2,'0')}';

  final byDate = <String, List<Map<String, dynamic>>>{};
  for (final ev in futureEvents) {
    final esd  = ev['esd'] as String? ?? '';
    final date = esd.length >= 10 ? esd.substring(0, 10) : '';
    // Sadece yarın ile cutoff arasındaki günler
    if (date.isEmpty || date.compareTo(todayStr) <= 0 || date.compareTo(cutoffStr) >= 0) continue;
    (byDate[date] ??= []).add(ev);
  }

  int futureUpserted = 0, futureFailed = 0;
  for (int i = 1; i <= 4; i++) {
    final d = trNow.add(Duration(days: i));
    final dateStr = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
    final dayEvs  = byDate[dateStr] ?? [];
    print('  📅 $dateStr: ${dayEvs.length} maç');

    for (final ev in dayEvs) {
      final id     = (ev['id'] as num).toInt();
      final compId = (ev['competitionId'] as num?)?.toInt() ?? 0;
      final rawData = _buildRawData(ev);

      try {
        await sb.from('future_matches').upsert({
          'fixture_id': id,
          'date':       dateStr,
          'league_id':  compId,
          'data':       rawData,            // future_matches.data JSONB (encoded olarak değil)
          'updated_at': DateTime.now().toIso8601String(),
        }, onConflict: 'fixture_id');
        futureUpserted++;
      } catch (e) {
        print('  ⚠️  future_matches upsert ($id): $e');
        futureFailed++;
      }
    }
  }
  print('✅ Gelecek: $futureUpserted yazıldı${futureFailed > 0 ? ", $futureFailed hatalı" : ""}');

  // ═══ Özet ════════════════════════════════════════════════════════
  final totalFailed = todayFailed + futureFailed;
  print('\n═══════════════════════════════');
  print('  ✅ Bugün    : $todayUpserted maç');
  print('  ✅ Gelecek  : $futureUpserted maç');
  if (totalFailed > 0) print('  ❌ Hatalı   : $totalFailed');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(totalFailed > 0 ? 1 : 0);
}
