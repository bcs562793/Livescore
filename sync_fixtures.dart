import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

const _teamsJsonUrl = 'https://raw.githubusercontent.com/bcs562793/H2Hscrape/main/data/teams.json';

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

// ── Normalizasyon ─────────────────────────────────────────────────────────────

String _norm(String name) {
  var s = name.toLowerCase().trim();

  // Karakter temizliği
  s = s.replaceAll('ş', 's').replaceAll('ğ', 'g').replaceAll('ü', 'u')
      .replaceAll('ö', 'o').replaceAll('ç', 'c').replaceAll('ı', 'i')
      .replaceAll(RegExp(r"[éèêë]"), 'e')
      .replaceAll(RegExp(r"[áàâãäå]"), 'a')
      .replaceAll(RegExp(r"[óòôõø]"), 'o')
      .replaceAll(RegExp(r"[úùûů]"), 'u')
      .replaceAll(RegExp(r"[íìî]"), 'i')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r"[ćč]"), 'c')
      .replaceAll('ž', 'z').replaceAll('š', 's')
      .replaceAll('ý', 'y').replaceAll('ř', 'r');

  // Noktalama işaretlerini boşluğa çevir, ancak kelimeleri (kısaltmaları) silme.
  s = s.replaceAll(RegExp(r"[.\-_/'\\()\[\]]"), ' ');
  
  // Fazla boşlukları temizle
  return s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).join(' ').trim();
}

// ── teams.json logo index ─────────────────────────────────────────────────────

class _LogoIndex {
  final Map<String, String> _exact = {};
  final List<String> _names = [];
  final List<String> _logos = [];
  final List<String> _countries = [];
  int matched = 0;
  int fallback = 0;

  _LogoIndex(List<dynamic> teams) {
    for (final t in teams) {
      final name    = (t['n'] as String? ?? '').trim(); // 'n' -> name
      final country = (t['c'] as String? ?? '').trim(); // 'c' -> country
      final logo    = (t['l'] as String? ?? '').trim(); // 'l' -> logo
      
      if (name.isEmpty || logo.isEmpty) continue;
      final n = _norm(name);
      
      // Ülke bazlı anahtar
      _exact['$n|${country.toLowerCase()}'] = logo;
      // Genel anahtar
      if (!_exact.containsKey('$n|')) {
        _exact['$n|'] = logo;
      }
      
      _names.add(n);
      _logos.add(logo);
      _countries.add(country.toLowerCase());
    }
    print('🗂  Logo index: ${_names.length} takım (teams.json)');
  }

  String resolve(String teamName, String leagueCountry, int? teamId) {
    if (teamName.isEmpty) return _mackolik(teamId);
    
    final q       = _norm(teamName);
    final country = leagueCountry.toLowerCase();

    // 1. Tam isim + ülke
    final exact = _exact['$q|$country'];
    if (exact != null && exact.isNotEmpty) { matched++; return exact; }

    // 2. Tam isim (ülkesiz fallback)
    final noCountry = _exact['$q|'];
    if (noCountry != null && noCountry.isNotEmpty) {
      matched++;
      return noCountry;
    }

    // 3. Akıllı Fuzzy Eşleşme
    String bestLogo    = '';
    double bestScore   = 0;
    String bestCountry = '';

    for (int i = 0; i < _names.length; i++) {
      final score = _tokenScore(q, _names[i]);
      if (score > bestScore) {
        bestScore   = score;
        bestLogo    = _logos[i];
        bestCountry = _countries[i];
      }
    }

    if (bestScore >= 0.70) { // Kısaltma silmediğimiz için eşik değerini biraz yükselttik
      if (country.isNotEmpty && bestCountry.isNotEmpty && country != bestCountry) {
        if (bestScore < 0.90) bestScore -= 0.10;
      }
      
      if (bestScore >= 0.65 && bestLogo.isNotEmpty) {
        matched++;
        return bestLogo;
      }
    }

    // 4. Mackolik CDN fallback
    fallback++;
    return _mackolik(teamId);
  }

  String _mackolik(int? teamId) =>
      teamId != null ? 'https://im.mackolik.com/img/logo/buyuk/$teamId.gif' : '';

  double _tokenScore(String qStr, String tStr) {
    if (qStr == tStr) return 1.0;

    final qTokens = qStr.split(' ');
    final tTokens = tStr.split(' ');
    if (qTokens.isEmpty || tTokens.isEmpty) return 0.0;

    double totalScore = 0.0;
    int matchedCount = 0;

    for (final qt in qTokens) {
      double bestMatch = 0.0;
      for (final tt in tTokens) {
        double currentScore = 0.0;
        if (qt == tt) {
          currentScore = 1.0;
        } else if (tt.contains(qt) || qt.contains(tt)) {
          final minLen = qt.length < tt.length ? qt.length : tt.length;
          if (minLen >= 3) currentScore = 0.7;
        }
        if (currentScore > bestMatch) bestMatch = currentScore;
      }
      totalScore += bestMatch;
      if (bestMatch >= 0.7) matchedCount++;
    }

    return (totalScore / qTokens.length) * 0.8 + (matchedCount / tTokens.length) * 0.2;
  }
}

Future<_LogoIndex> _loadLogoIndex() async {
  try {
    final res = await http.get(Uri.parse(_teamsJsonUrl)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      print('⚠️  teams.json HTTP ${res.statusCode}');
      return _LogoIndex([]);
    }
    final teams = jsonDecode(res.body) as List;
    return _LogoIndex(teams);
  } catch (e) {
    print('⚠️  teams.json yüklenemedi: $e');
    return _LogoIndex([]);
  }
}

// ── Lig adından ülke çıkarma ──────────────────────────────────────────────────

const Map<String, String> _lgCountryMap = {
  'almanya':'Germany','ispanya':'Spain','italya':'Italy','fransa':'France',
  'hollanda':'Netherlands','portekiz':'Portugal','brezilya':'Brazil',
  'arjantin':'Argentina','turkiye':'Turkey','turk':'Turkey',
  'belcika':'Belgium','isvicre':'Switzerland','avustralya':'Australia',
  'japonya':'Japan','danimarka':'Denmark','norvec':'Norway','isvec':'Sweden',
  'finlandiya':'Finland','polonya':'Poland','hirvatistan':'Croatia',
  'slovenya':'Slovenia','slovakya':'Slovakia','cekya':'Czech Republic',
  'macaristan':'Hungary','romanya':'Romania','bulgaristan':'Bulgaria',
  'sirbistan':'Serbia','yunanistan':'Greece','avusturya':'Austria',
  'iskocya':'Scotland','ingiltere':'England','galler':'Wales',
  'kolombiya':'Colombia','meksika':'Mexico','sili':'Chile','misir':'Egypt',
  'fas':'Morocco','cezayir':'Algeria','nijerya':'Nigeria','gana':'Ghana',
  'abd':'USA','kanada':'Canada','arnavutluk':'Albania','karadag':'Montenegro',
  'letonya':'Latvia','litvanya':'Lithuania','estonya':'Estonia',
  'ukrayna':'Ukraine','rusya':'Russia','azerbaycan':'Azerbaijan',
  'gurcistan':'Georgia','ermenistan':'Armenia','honduras':'Honduras',
  'guatemala':'Guatemala','panama':'Panama','paraguay':'Paraguay',
  'uruguay':'Uruguay','bolivya':'Bolivia','peru':'Peru','ekvador':'Ecuador',
  'tanzanya':'Tanzania','kenya':'Kenya','tunus':'Tunisia','irak':'Iraq',
  'suriye':'Syria','iran':'Iran','katar':'Qatar','hindistan':'India',
  'cin':'China','endonezya':'Indonesia','tayland':'Thailand',
  'malezya':'Malaysia','izlanda':'Iceland','kibris':'Cyprus',
  'israil':'Israel','kazakistan':'Kazakhstan','ozbekistan':'Uzbekistan',
  'guney_afrika':'South Africa','kuzey_irlanda':'Northern Ireland',
  'kosta_rika':'Costa Rica','el_salvador':'El Salvador',
  'suudi_arabistan':'Saudi Arabia','faroe_adalari':'Faroe Islands',
  'guney_kore':'South Korea','yeni_zelanda':'New Zealand',
};

String _normForCountry(String s) => s.toLowerCase()
    .replaceAll('ş','s').replaceAll('ğ','g').replaceAll('ü','u')
    .replaceAll('ö','o').replaceAll('ç','c').replaceAll('ı','i')
    .replaceAll('İ','i').replaceAll('â','a').replaceAll('î','i').replaceAll('ô','o');

String extractCountryFromLeague(String lgn) {
  if (lgn.isEmpty) return '';
  final words = lgn.trim().split(RegExp(r'\s+'));
  if (words.isEmpty) return '';
  if (words.length >= 2) {
    final k2 = '${_normForCountry(words[0])}_${_normForCountry(words[1])}';
    if (_lgCountryMap.containsKey(k2)) return _lgCountryMap[k2]!;
  }
  return _lgCountryMap[_normForCountry(words[0])] ?? '';
}

String _toIsoTR(int esdMs) {
  if (esdMs == 0) return '';
  final utc = DateTime.fromMillisecondsSinceEpoch(esdMs, isUtc: true);
  final tr  = utc.add(const Duration(hours: 3));
  final pad = (int n) => n.toString().padLeft(2, '0');
  return '${tr.year}-${pad(tr.month)}-${pad(tr.day)}'
      'T${pad(tr.hour)}:${pad(tr.minute)}:00+03:00';
}

Future<List<Map<String, dynamic>>> _fetchGamelist({required int tabType, required int bulletinType}) async {
  final uri = Uri.parse('$_bilyonerBase/api/v3/mobile/aggregator/gamelist/all/v1?tabType=$tabType&bulletinType=$bulletinType');
  for (int attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 5));
    try {
      final res = await http.get(uri, headers: _headers(isLive: bulletinType == 1)).timeout(const Duration(seconds: 25));
      if (res.statusCode == 403 || res.statusCode == 429) {
        await Future.delayed(Duration(seconds: (attempt + 1) * 10));
        continue;
      }
      if (res.statusCode != 200) continue;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final eventsRaw = body['events'] as Map<String, dynamic>? ?? {};
      if (eventsRaw.isEmpty) {
        if (attempt < 2) continue;
        return [];
      }
      return eventsRaw.values.whereType<Map<String, dynamic>>().where((e) => (e['st'] as int? ?? 0) == 1).toList();
    } catch (e) {
      print('⚠️ Bilyoner Hatası: $e');
    }
  }
  return [];
}

Map<String, dynamic> _buildRawData(Map<String, dynamic> ev, {required String homeLogo, required String awayLogo, required String country}) {
  final id    = (ev['id'] as num).toInt();
  final htpi  = (ev['htpi'] as num?)?.toInt();
  final atpi  = (ev['atpi'] as num?)?.toInt();
  final esdMs = (ev['esdl'] as num?)?.toInt() ?? 0;
  return {
    'fixture': {
      'id': id,
      'timestamp': esdMs ~/ 1000,
      'date': _toIsoTR(esdMs),
      'timezone': 'Europe/Istanbul',
      'referee': null,
      'periods': {'first': null, 'second': null},
      'venue': {'id': null, 'name': null, 'city': null},
      'status': {'long': 'Not Started', 'short': 'NS', 'elapsed': null, 'extra': null},
    },
    'teams': {
      'home': {'id': htpi, 'name': ev['htn'] ?? '', 'logo': homeLogo, 'winner': null},
      'away': {'id': atpi, 'name': ev['atn'] ?? '', 'logo': awayLogo, 'winner': null},
    },
    'league': {
      'id': (ev['competitionId'] as num?)?.toInt() ?? 0,
      'name': ev['lgn'] ?? '',
      'logo': '',
      'country': country,
      'flag': null,
      'season': null,
      'round': null,
      'standings': false,
    },
    'goals': {'home': 0, 'away': 0},
    'score': {
      'halftime': {'home': null, 'away': null},
      'fulltime': {'home': null, 'away': null},
      'extratime': {'home': null, 'away': null},
      'penalty': {'home': null, 'away': null},
    },
  };
}

Future<void> _cleanStaleRecords(String sbUrl, String sbKey) async {
  final h = {'apikey': sbKey, 'Authorization': 'Bearer $sbKey', 'Prefer': 'return=minimal'};
  try {
    await http.delete(Uri.parse('$sbUrl/rest/v1/live_matches?score_source=neq.nesine&status_short=eq.NS'), headers: h);
  } catch (e) {}
  try {
    await http.delete(Uri.parse('$sbUrl/rest/v1/future_matches?fixture_id=gte.0'), headers: h);
  } catch (e) {}
}

Future<int> _batchUpsert(SupabaseClient sb, String table, List<Map<String, dynamic>> records, String onConflict) async {
  int errors = 0;
  for (int i = 0; i < records.length; i += 200) {
    final chunk = records.sublist(i, (i + 200).clamp(0, records.length));
    try {
      await sb.from(table).upsert(chunk, onConflict: onConflict);
    } catch (e) {
      print('⚠️ $table Hatası: $e');
      errors += chunk.length;
    }
  }
  return errors;
}

Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';
  if (sbUrl.isEmpty || sbKey.isEmpty) exit(1);

  final sb = SupabaseClient(sbUrl, sbKey);
  final trNow = DateTime.now().toUtc().add(const Duration(hours: 3));
  final pad = (int n) => n.toString().padLeft(2, '0');
  final todayStr = '${trNow.year}-${pad(trNow.month)}-${pad(trNow.day)}';
  final cutoff = trNow.add(const Duration(days: 5));
  final cutoffStr = '${cutoff.year}-${pad(cutoff.month)}-${pad(cutoff.day)}';

  print('📅 Fikstür senkronizasyonu — ${DateTime.now().toIso8601String()}');
  final logoIndex = await _loadLogoIndex();

  await _cleanStaleRecords(sbUrl, sbKey);

  final liveEvents = await _fetchGamelist(tabType: 1, bulletinType: 1);
  final prematchEvents = await _fetchGamelist(tabType: 1, bulletinType: 2);

  final Map<int, Map<String, dynamic>> allEventsMap = {};
  for (final ev in prematchEvents) { allEventsMap[(ev['id'] as num).toInt()] = ev; }
  for (final ev in liveEvents) { allEventsMap[(ev['id'] as num).toInt()] = ev; }
  final allEvents = allEventsMap.values.toList();

  final Set<int> liveFixtureIds = {};
  try {
    final liveRows = await sb.from('live_matches').select('fixture_id').inFilter('status_short', ['1H', '2H', 'HT', 'ET', 'BT', 'P', 'LIVE']);
    for (final row in liveRows) { if (row['fixture_id'] != null) liveFixtureIds.add(row['fixture_id'] as int); }
  } catch (e) {}

  final List<Map<String, dynamic>> liveUpserts = [];
  final List<Map<String, dynamic>> futureUpserts = [];

  for (final ev in allEvents) {
    final esd = ev['esd'] as String? ?? '';
    final date = esd.length >= 10 ? esd.substring(0, 10) : '';
    final id = (ev['id'] as num).toInt();
    final country = extractCountryFromLeague(ev['lgn'] ?? '');
    
    final homeLogo = logoIndex.resolve(ev['htn'] ?? '', country, ev['htpi'] as int?);
    final awayLogo = logoIndex.resolve(ev['atn'] ?? '', country, ev['atpi'] as int?);
    
    final rawData = _buildRawData(ev, homeLogo: homeLogo, awayLogo: awayLogo, country: country);

    if (date == todayStr) {
      if (!liveFixtureIds.contains(id)) {
        liveUpserts.add({
          'fixture_id': id,
          'home_team': ev['htn'],
          'away_team': ev['atn'],
          'home_team_id': ev['htpi'],
          'away_team_id': ev['atpi'],
          'home_logo': homeLogo,
          'away_logo': awayLogo,
          'home_score': 0,
          'away_score': 0,
          'status_short': 'NS',
          'league_id': ev['competitionId'],
          'league_name': ev['lgn'],
          'score_source': 'bilyoner',
          'raw_data': rawData,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
      futureUpserts.add({'fixture_id': id, 'date': todayStr, 'league_id': ev['competitionId'], 'data': rawData, 'updated_at': DateTime.now().toIso8601String()});
    } else if (date.isNotEmpty && date.compareTo(todayStr) > 0 && date.compareTo(cutoffStr) < 0) {
      futureUpserts.add({'fixture_id': id, 'date': date, 'league_id': ev['competitionId'], 'data': rawData, 'updated_at': DateTime.now().toIso8601String()});
    }
  }

  await _batchUpsert(sb, 'live_matches', liveUpserts, 'fixture_id');
  await _batchUpsert(sb, 'future_matches', futureUpserts, 'fixture_id');

  print('✅ Bitti. Eşleşen: ${logoIndex.matched}, Fallback: ${logoIndex.fallback}');
  await sb.dispose();
}
