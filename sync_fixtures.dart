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

String _toIsoTR(int esdMs) {
  if (esdMs == 0) return '';
  final utc = DateTime.fromMillisecondsSinceEpoch(esdMs, isUtc: true);
  final tr  = utc.add(const Duration(hours: 3));
  final pad = (int n) => n.toString().padLeft(2, '0');
  return '${tr.year}-${pad(tr.month)}-${pad(tr.day)}'
      'T${pad(tr.hour)}:${pad(tr.minute)}:00+03:00';
}

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

Map<String, dynamic> _buildRawData(Map<String, dynamic> ev) {
  final id    = (ev['id']   as num).toInt();
  final htpi  = (ev['htpi'] as num?)?.toInt();
  final atpi  = (ev['atpi'] as num?)?.toInt();
  final esdMs = (ev['esdl'] as num?)?.toInt() ?? 0;

  return {
    'fixture': {
      'id':        id,
      'timestamp': esdMs ~/ 1000,
      'date':      _toIsoTR(esdMs),   // frontend saat gösterimi için
      'timezone':  'Europe/Istanbul',
      'referee':   null,
      'periods':   {'first': null, 'second': null},
      'venue':     {'id': null, 'name': null, 'city': null},
      'status':    {'long': 'Not Started', 'short': 'NS', 'elapsed': null, 'extra': null},
    },
    'teams': {
      'home': {
        'id':     htpi,
        'name':   ev['htn'] ?? '',
        'logo':   htpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$htpi.gif' : '',
        'winner': null,
      },
      'away': {
        'id':     atpi,
        'name':   ev['atn'] ?? '',
        'logo':   atpi != null ? 'https://im.mackolik.com/img/logo/buyuk/$atpi.gif' : '',
        'winner': null,
      },
    },
    'league': {
      'id':        (ev['competitionId'] as num?)?.toInt() ?? 0,
      'name':      ev['lgn'] ?? '',
      'logo':      '',
      'country':   '',
      'flag':      null,
      'season':    null,
      'round':     null,
      'standings': false,
    },
    'goals': {'home': 0, 'away': 0},
    'score': {
      'halftime':  {'home': null, 'away': null},
      'fulltime':  {'home': null, 'away': null},
      'extratime': {'home': null, 'away': null},
      'penalty':   {'home': null, 'away': null},
    },
  };
}

/// Eski apifootball/nesine-dışı kayıtları temizle.
/// 
/// NEDEN GEREKLİ:
/// Bilyoner fixture_id ≠ apifootball fixture_id (örn: Cordoba bilyoner=2838521, apifootball=1392111)
/// Temizlenmezse DB'de iki ayrı satır oluşur, frontend yanlış ID'yi okur → maç NS kalır.
/// 
/// KORUNAN kayıtlar:
/// - score_source='nesine'  → Nesine bahisli maçlar, skor oradan geliyor
/// - status_short != 'NS'  → Canlı veya bitmiş maçlara dokunma
Future<void> _cleanStaleRecords(String sbUrl, String sbKey) async {
  final h = {
    'apikey':        sbKey,
    'Authorization': 'Bearer $sbKey',
    'Prefer':        'return=minimal',
  };

  // live_matches: sadece NS + non-nesine olanları sil
  // (canlı/biten maçlar korunuyor)
  try {
    final r = await http.delete(
      Uri.parse('$sbUrl/rest/v1/live_matches'
          '?score_source=neq.nesine'
          '&status_short=eq.NS'),
      headers: h,
    ).timeout(const Duration(seconds: 15));
    print('🗑  live_matches NS non-nesine → silindi [${r.statusCode}]');
  } catch (e) {
    print('⚠️  live_matches temizleme: $e');
  }

  // future_matches: tümünü sil, güncel Bilyoner verisiyle yaz
  try {
    final r = await http.delete(
      Uri.parse('$sbUrl/rest/v1/future_matches?fixture_id=gte.0'),
      headers: h,
    ).timeout(const Duration(seconds: 15));
    print('🗑  future_matches → silindi [${r.statusCode}]');
  } catch (e) {
    print('⚠️  future_matches temizleme: $e');
  }
}

Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

  if (sbUrl.isEmpty || sbKey.isEmpty) {
    print('❌ SUPABASE_URL veya SUPABASE_KEY eksik');
    exit(1);
  }

  final sb    = SupabaseClient(sbUrl, sbKey);
  final trNow = DateTime.now().toUtc().add(const Duration(hours: 3));
  final pad   = (int n) => n.toString().padLeft(2, '0');
  final todayStr = '${trNow.year}-${pad(trNow.month)}-${pad(trNow.day)}';

  print('📅 Fikstür senkronizasyonu — ${DateTime.now().toIso8601String()}');
  print('🗓  Bugün (TR): $todayStr');

  // ═══ 0) Stale kayıt temizliği ═══════════════════════════════════
  print('\n── Eski kayıt temizliği ──');
  await _cleanStaleRecords(sbUrl, sbKey);

  // ═══ 1) Bugünkü maçlar: tabType=9999, bulletinType=1 ════════════
  print('\n── Bugünkü maçlar (tabType=9999&bulletinType=1) ──');
  final todayEvents = await _fetchGamelist(tabType: 1, bulletinType: 1);

  int todayOk = 0, todayErr = 0;
  for (final ev in todayEvents) {
    final esd = ev['esd'] as String? ?? '';
    if (!esd.startsWith(todayStr)) continue;

    final id     = (ev['id']   as num).toInt();
    final htpi   = (ev['htpi'] as num?)?.toInt();
    final atpi   = (ev['atpi'] as num?)?.toInt();
    final compId = (ev['competitionId'] as num?)?.toInt() ?? 0;
    final brdId  = (ev['brdId'] as num?)?.toInt();

    try {
      // Canlı maçların üzerine yazma
      final existing = await sb
          .from('live_matches')
          .select('status_short')
          .eq('fixture_id', id)
          .maybeSingle();
      final existingStatus = existing?['status_short'] as String? ?? '';
      final isLive = ['1H','2H','HT','ET','BT','P','LIVE'].contains(existingStatus);

      if (!isLive) {
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
          'raw_data':     jsonEncode(_buildRawData(ev)),
          'updated_at':   DateTime.now().toIso8601String(),
        }, onConflict: 'fixture_id');
      }

      // future_matches her zaman yaz
      await sb.from('future_matches').upsert({
        'fixture_id': id,
        'date':       todayStr,
        'league_id':  compId,
        'data':       _buildRawData(ev),
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'fixture_id');

      todayOk++;
    } catch (e) {
      print('  ⚠️  live ($id): $e');
      todayErr++;
    }
  }
  print('✅ Bugün: $todayOk yazıldı${todayErr > 0 ? ", $todayErr hatalı" : ""}');

  

  // ═══ 2) Gelecek maçlar: tabType=1, bulletinType=2 ═══════════════
  // HAR kanıtı: /iddaa sayfası → tabType=1&bulletinType=2 → 576 event
  // tabType=9999&bulletinType=2 → her zaman BOŞTUR
  print('\n── Gelecek maçlar (tabType=1&bulletinType=2) ──');
  List<Map<String, dynamic>> futureEvents =
      await _fetchGamelist(tabType: 1, bulletinType: 2);

  if (futureEvents.isEmpty) {
    print('⚠️  Fallback: bugünkü liste kullanılıyor');
    futureEvents = todayEvents;
  }

  final byDate = <String, List<Map<String, dynamic>>>{};
  for (final ev in futureEvents) {
    final esd  = ev['esd'] as String? ?? '';
    final date = esd.length >= 10 ? esd.substring(0, 10) : '';
    if (date.isEmpty || date.compareTo(todayStr) <= 0) continue;
    final cutoff = trNow.add(const Duration(days: 5));
    final cutoffStr = '${cutoff.year}-${pad(cutoff.month)}-${pad(cutoff.day)}';
    if (date.compareTo(cutoffStr) >= 0) continue;
    (byDate[date] ??= []).add(ev);
  }

  int futureOk = 0, futureErr = 0;
  for (int i = 1; i <= 4; i++) {
    final d       = trNow.add(Duration(days: i));
    final dateStr = '${d.year}-${pad(d.month)}-${pad(d.day)}';
    final dayEvs  = byDate[dateStr] ?? [];
    print('  📅 $dateStr: ${dayEvs.length} maç');

    for (final ev in dayEvs) {
      final id     = (ev['id'] as num).toInt();
      final compId = (ev['competitionId'] as num?)?.toInt() ?? 0;
      try {
        await sb.from('future_matches').upsert({
          'fixture_id': id,
          'date':       dateStr,
          'league_id':  compId,
          'data':       _buildRawData(ev),
          'updated_at': DateTime.now().toIso8601String(),
        }, onConflict: 'fixture_id');
        futureOk++;
      } catch (e) {
        print('  ⚠️  future ($id): $e');
        futureErr++;
      }
    }
  }
  print('✅ Gelecek: $futureOk yazıldı${futureErr > 0 ? ", $futureErr hatalı" : ""}');

  final totalErr = todayErr + futureErr;
  print('\n═══════════════════════════════');
  print('  ✅ Bugün    : $todayOk maç');
  print('  ✅ Gelecek  : $futureOk maç');
  if (totalErr > 0) print('  ❌ Hatalı   : $totalErr');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(totalErr > 0 ? 1 : 0);
}
