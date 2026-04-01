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

// ── Logo Mapping ──────────────────────────────────────────────────────────────

Future<Map<int, String>> _loadLogoMapping(SupabaseClient sb) async {
  try {
    final rows = await sb
        .from('team_logo_mapping')
        .select('live_team_id, api_logo')
        .eq('low_confidence', false)
        .not('api_logo', 'is', null)
        .neq('api_logo', '');

    final map = <int, String>{};
    for (final row in rows) {
      final id   = row['live_team_id'] as int?;
      final logo = row['api_logo']     as String?;
      if (id != null && logo != null && logo.isNotEmpty) {
        map[id] = logo;
      }
    }
    print('🖼  Logo mapping yüklendi: ${map.length} takım');
    return map;
  } catch (e) {
    print('⚠️  Logo mapping yüklenemedi (mackolik fallback kullanılacak): $e');
    return {};
  }
}

String _resolveLogo(int? teamId, Map<int, String> logoMap) {
  if (teamId == null) return '';
  return logoMap[teamId] ?? 'https://im.mackolik.com/img/logo/buyuk/$teamId.gif';
}

// ── Tarih yardımcıları ───────────────────────────────────────────────────────

String _toIsoTR(int esdMs) {
  if (esdMs == 0) return '';
  final utc = DateTime.fromMillisecondsSinceEpoch(esdMs, isUtc: true);
  final tr  = utc.add(const Duration(hours: 3));
  final pad = (int n) => n.toString().padLeft(2, '0');
  return '${tr.year}-${pad(tr.month)}-${pad(tr.day)}'
      'T${pad(tr.hour)}:${pad(tr.minute)}:00+03:00';
}

// ── Bilyoner API ─────────────────────────────────────────────────────────────

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

// ── raw_data builder ─────────────────────────────────────────────────────────

Map<String, dynamic> _buildRawData(
  Map<String, dynamic> ev, {
  required String homeLogo,
  required String awayLogo,
}) {
  final id    = (ev['id']   as num).toInt();
  final htpi  = (ev['htpi'] as num?)?.toInt();
  final atpi  = (ev['atpi'] as num?)?.toInt();
  final esdMs = (ev['esdl'] as num?)?.toInt() ?? 0;

  return {
    'fixture': {
      'id':        id,
      'timestamp': esdMs ~/ 1000,
      'date':      _toIsoTR(esdMs),
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
        'logo':   homeLogo,
        'winner': null,
      },
      'away': {
        'id':     atpi,
        'name':   ev['atn'] ?? '',
        'logo':   awayLogo,
        'winner': null,
      },
    },
    'league': {
      'id':        (ev['competitionId'] as num?)?.toInt() ?? 0,
      'name':      ev['lgn'] ?? '',
      'logo':      '',
      'country':   extractCountryFromLeague(ev['lgn'] as String? ?? ''),
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

// ── Temizlik ─────────────────────────────────────────────────────────────────

Future<void> _cleanStaleRecords(String sbUrl, String sbKey) async {
  final h = {
    'apikey':        sbKey,
    'Authorization': 'Bearer $sbKey',
    'Prefer':        'return=minimal',
  };

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

// ── Batch upsert ─────────────────────────────────────────────────────────────

const _batchSize = 200;

Future<int> _batchUpsert(
  SupabaseClient sb,
  String table,
  List<Map<String, dynamic>> records,
  String onConflict,
) async {
  int errors = 0;
  for (int i = 0; i < records.length; i += _batchSize) {
    final chunk = records.sublist(
      i, (i + _batchSize).clamp(0, records.length),
    );
    try {
      await sb.from(table).upsert(chunk, onConflict: onConflict);
    } catch (e) {
      print('  ⚠️  $table batch upsert hatası (${i}–${i + chunk.length}): $e');
      errors += chunk.length;
    }
  }
  return errors;
}

// ── Logo güncelleme RPC ───────────────────────────────────────────────────────

/// İki RPC çağrılır — her ikisi de maçlar yazıldıktan SONRA çalışır.
///
/// sync_live_match_logos : live_matches.home_logo / away_logo kolonlarını günceller.
/// sync_future_match_logos: future_matches.data JSON içindeki
///                          teams.home.logo / teams.away.logo alanlarını günceller.
///
/// NEDEN: logoMap başlangıçta yüklendiğinde yeni takımlar mapping'de olmayabilir.
/// RPC'ler yazma bittikten sonra doğrudan JOIN yaparak her iki tabloyu da düzeltir.
Future<void> _syncLogos(SupabaseClient sb) async {
  try {
    await sb.rpc('sync_live_match_logos', {});
    print('🖼  sync_live_match_logos      → live_matches logoları güncellendi');
  } catch (e) {
    print('⚠️  sync_live_match_logos RPC hatası: $e');
  }

  try {
    await sb.rpc('sync_future_match_logos', {});
    print('🖼  sync_future_match_logos    → future_matches.data logoları güncellendi');
  } catch (e) {
    print('⚠️  sync_future_match_logos RPC hatası: $e');
  }
}

// ── main ─────────────────────────────────────────────────────────────────────

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
  final todayStr  = '${trNow.year}-${pad(trNow.month)}-${pad(trNow.day)}';
  final cutoff    = trNow.add(const Duration(days: 5));
  final cutoffStr = '${cutoff.year}-${pad(cutoff.month)}-${pad(cutoff.day)}';

  print('📅 Fikstür senkronizasyonu — ${DateTime.now().toIso8601String()}');
  print('🗓  Bugün (TR): $todayStr  |  Kesim: $cutoffStr');

  // ═══ 0) Logo mapping — başlangıçta yükle (bilinen takımlar için) ══════════
  print('\n── Logo mapping yükleniyor ──');
  final logoMap = await _loadLogoMapping(sb);

  // ═══ 1) Temizlik ════════════════════════════════════════════════
  print('\n── Eski kayıt temizliği ──');
  await _cleanStaleRecords(sbUrl, sbKey);

  // ═══ 2) Bilyoner verilerini çek ═════════════════════════════════
  print('\n── Canlı maçlar çekiliyor (bulletinType=1) ──');
  final liveEvents = await _fetchGamelist(tabType: 1, bulletinType: 1);

  print('\n── Maç önü bülteni çekiliyor (bulletinType=2) ──');
  final prematchEvents = await _fetchGamelist(tabType: 1, bulletinType: 2);

  final Map<int, Map<String, dynamic>> allEventsMap = {};
  for (final ev in prematchEvents) {
    allEventsMap[(ev['id'] as num).toInt()] = ev;
  }
  for (final ev in liveEvents) {
    allEventsMap[(ev['id'] as num).toInt()] = ev;
  }
  final allEvents = allEventsMap.values.toList();

  // ═══ 3) Aktif canlı maçları tek sorguda al ══════════════════════
  print('\n── Mevcut live durum sorgulanıyor ──');
  final Set<int> liveFixtureIds = {};
  try {
    final liveRows = await sb
        .from('live_matches')
        .select('fixture_id')
        .inFilter('status_short', ['1H', '2H', 'HT', 'ET', 'BT', 'P', 'LIVE']);
    for (final row in liveRows) {
      final fid = row['fixture_id'] as int?;
      if (fid != null) liveFixtureIds.add(fid);
    }
    print('  ⚽ Aktif canlı maç: ${liveFixtureIds.length}');
  } catch (e) {
    print('  ⚠️  Canlı durum sorgulanamadı, tümü yazılacak: $e');
  }

  // ═══ 4) Kayıtları hazırla ════════════════════════════════════════
  print('\n── Maçlar işleniyor ──');

  final List<Map<String, dynamic>> liveUpserts   = [];
  final List<Map<String, dynamic>> futureUpserts = [];

  for (final ev in allEvents) {
    final esd  = ev['esd'] as String? ?? '';
    final date = esd.length >= 10 ? esd.substring(0, 10) : '';

    final id     = (ev['id']   as num).toInt();
    final htpi   = (ev['htpi'] as num?)?.toInt();
    final atpi   = (ev['atpi'] as num?)?.toInt();
    final compId = (ev['competitionId'] as num?)?.toInt() ?? 0;
    final brdId  = (ev['brdId'] as num?)?.toInt();

    // logoMap'te varsa doğru logo, yoksa mackolik — RPC sonradan düzeltecek
    final homeLogo = _resolveLogo(htpi, logoMap);
    final awayLogo = _resolveLogo(atpi, logoMap);
    final rawData  = _buildRawData(ev, homeLogo: homeLogo, awayLogo: awayLogo);

    if (date == todayStr) {
      if (!liveFixtureIds.contains(id)) {
        liveUpserts.add({
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
          'updated_at':   DateTime.now().toIso8601String(),
        });
      }
      futureUpserts.add({
        'fixture_id': id,
        'date':       todayStr,
        'league_id':  compId,
        'data':       rawData,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } else if (date.isNotEmpty &&
               date.compareTo(todayStr) > 0 &&
               date.compareTo(cutoffStr) < 0) {
      futureUpserts.add({
        'fixture_id': id,
        'date':       date,
        'league_id':  compId,
        'data':       rawData,
        'updated_at': DateTime.now().toIso8601String(),
      });
    }
  }

  // ═══ 5) Batch upsert ════════════════════════════════════════════
  print('\n── Yazılıyor ──');
  print('  live_matches  : ${liveUpserts.length} kayıt');
  print('  future_matches: ${futureUpserts.length} kayıt');

  final liveErr   = await _batchUpsert(sb, 'live_matches',   liveUpserts,   'fixture_id');
  final futureErr = await _batchUpsert(sb, 'future_matches', futureUpserts, 'fixture_id');

  // Logo senkronizasyonu team_logo_sync.py (Python) tarafından yapılır.
  // O script hem sync_live_match_logos hem sync_future_match_logos RPC'lerini çağırır.

  final totalErr = liveErr + futureErr;

  print('\n═══════════════════════════════');
  print('  🖼  Logo mapping : ${logoMap.length} takım');
  print('  ✅ live_matches  : ${liveUpserts.length - liveErr} yazıldı');
  print('  ✅ future_matches: ${futureUpserts.length - futureErr} yazıldı');
  if (liveFixtureIds.isNotEmpty) {
    print('  ⚽ Canlı korunan : ${liveFixtureIds.length}');
  }
  if (totalErr > 0) print('  ❌ Hatalı        : $totalErr');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(totalErr > 0 ? 1 : 0);
}
// fixture_sync.dart içine ekle — _buildRawData'dan önce

// ── Lig adından ülke çıkarma ──────────────────────────────────────────────────
// lgn örneği: "Almanya 2. Bundesliga" → "Germany"
//             "El Salvador Primera" → "El Salvador"
//             "Kosta Rika Primera" → "Costa Rica"

const Map<String, String> _lgCountryMap = {
  // Tek kelime
  'almanya':    'Germany',
  'ispanya':    'Spain',
  'italya':     'Italy',
  'fransa':     'France',
  'hollanda':   'Netherlands',
  'portekiz':   'Portugal',
  'brezilya':   'Brazil',
  'arjantin':   'Argentina',
  'turkiye':    'Turkey',
  'belcika':    'Belgium',
  'isvicre':    'Switzerland',
  'avustralya': 'Australia',
  'japonya':    'Japan',
  'danimarka':  'Denmark',
  'norvec':     'Norway',
  'isvec':      'Sweden',
  'finlandiya': 'Finland',
  'polonya':    'Poland',
  'hirvatistan':'Croatia',
  'slovenya':   'Slovenia',
  'slovakya':   'Slovakia',
  'cekya':      'Czech Republic',
  'macaristan': 'Hungary',
  'romanya':    'Romania',
  'bulgaristan':'Bulgaria',
  'sirbistan':  'Serbia',
  'yunanistan': 'Greece',
  'avusturya':  'Austria',
  'iskocya':    'Scotland',
  'ingiltere':  'England',
  'galler':     'Wales',
  'kolombiya':  'Colombia',
  'meksika':    'Mexico',
  'sili':       'Chile',
  'misir':      'Egypt',
  'fas':        'Morocco',
  'cezayir':    'Algeria',
  'nijerya':    'Nigeria',
  'gana':       'Ghana',
  'abd':        'USA',
  'kanada':     'Canada',
  'arnavutluk': 'Albania',
  'karadag':    'Montenegro',
  'letonya':    'Latvia',
  'litvanya':   'Lithuania',
  'estonya':    'Estonia',
  'ukrayna':    'Ukraine',
  'rusya':      'Russia',
  'azerbaycan': 'Azerbaijan',
  'gurcistan':  'Georgia',
  'ermenistan': 'Armenia',
  'honduras':   'Honduras',
  'guatemala':  'Guatemala',
  'panama':     'Panama',
  'paraguay':   'Paraguay',
  'uruguay':    'Uruguay',
  'bolivya':    'Bolivia',
  'peru':       'Peru',
  'ekvador':    'Ecuador',
  'tanzanya':   'Tanzania',
  'kenya':      'Kenya',
  'tunus':      'Tunisia',
  'irak':       'Iraq',
  'suriye':     'Syria',
  'iran':       'Iran',
  'katar':      'Qatar',
  'hindistan':  'India',
  'cin':        'China',
  'endonezya':  'Indonesia',
  'tayland':    'Thailand',
  'malezya':    'Malaysia',
  'izlanda':    'Iceland',
  'kibris':     'Cyprus',
  'israil':     'Israel',
  'kazakistan': 'Kazakhstan',
  'ozbekistan': 'Uzbekistan',
  'azerbaycan': 'Azerbaijan',

  // İki kelime (birleşik anahtar: "gueney_afrika" vb.)
  'gueney_afrika':  'South Africa',
  'kuzey_irlanda':  'Northern Ireland',
  'kosta_rika':     'Costa Rica',
  'el_salvador':    'El Salvador',
  'suudi_arabistan':'Saudi Arabia',
  'faroe_adalari':  'Faroe Islands',
  'guney_kore':     'South Korea',
  'yeni_zelanda':   'New Zealand',
};

String _normalizeForCountry(String s) => s
    .toLowerCase()
    .replaceAll('ş', 's').replaceAll('ğ', 'g').replaceAll('ü', 'u')
    .replaceAll('ö', 'o').replaceAll('ç', 'c').replaceAll('ı', 'i')
    .replaceAll('İ', 'i').replaceAll('é', 'e').replaceAll('ó', 'o')
    .replaceAll('ú', 'u').replaceAll('ñ', 'n').replaceAll('â', 'a')
    .replaceAll('î', 'i').replaceAll('ô', 'o');

/// lgn'den İngilizce ülke adı çıkarır.
/// "Almanya 2. Bundesliga" → "Germany"
/// "El Salvador Primera" → "El Salvador"
/// Bilinmeyenler → ""
String extractCountryFromLeague(String lgn) {
  if (lgn.isEmpty) return '';
  final words = lgn.trim().split(RegExp(r'\s+'));
  if (words.isEmpty) return '';

  // Önce iki kelimeyi birleştirip dene
  if (words.length >= 2) {
    final twoKey = '${_normalizeForCountry(words[0])}_${_normalizeForCountry(words[1])}';
    if (_lgCountryMap.containsKey(twoKey)) return _lgCountryMap[twoKey]!;
  }

  // Tek kelime
  final oneKey = _normalizeForCountry(words[0]);
  return _lgCountryMap[oneKey] ?? '';
}
