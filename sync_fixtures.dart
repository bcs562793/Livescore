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

// Bilyoner Türkçe şehir/takım adı parçaları → İngilizce karşılıkları
const _wordTrToEn = <String, String>{
  'munih':    'munich',
  'munchen':  'munich',
  'marsilya': 'marseille',
  'kopenhag': 'copenhagen',
  'bruksel':  'brussels',
  'prag':     'prague',
  'lizbon':   'lisbon',
  'viyana':   'vienna',
};

// Normalize edilmeyecek kelimeler (prefix/suffix gürültüsü)
const _noise = <String>{
  'fc','sc','cf','ac','if','bk','sk',
  'afc','bfc','cfc','sfc','rfc',
  'cp','cd','sd','ud','rc','rcd',
};

String _norm(String name) {
  var s = name
      .replaceAll('ş', 's').replaceAll('Ş', 's')
      .replaceAll('ğ', 'g').replaceAll('Ğ', 'g')
      .replaceAll('ü', 'u').replaceAll('Ü', 'u')
      .replaceAll('ö', 'o').replaceAll('Ö', 'o')
      .replaceAll('ç', 'c').replaceAll('Ç', 'c')
      .replaceAll('ı', 'i').replaceAll('İ', 'i')
      .replaceAll('é', 'e').replaceAll('è', 'e').replaceAll('ê', 'e')
      .replaceAll('á', 'a').replaceAll('à', 'a').replaceAll('â', 'a').replaceAll('ã', 'a').replaceAll('ä', 'a')
      .replaceAll('ó', 'o').replaceAll('ò', 'o').replaceAll('ô', 'o').replaceAll('õ', 'o')
      .replaceAll('ú', 'u').replaceAll('ù', 'u').replaceAll('û', 'u')
      .replaceAll('í', 'i').replaceAll('ì', 'i').replaceAll('î', 'i')
      .replaceAll('ñ', 'n').replaceAll('ø', 'o').replaceAll('å', 'a')
      .replaceAll('ć', 'c').replaceAll('č', 'c').replaceAll('ž', 'z').replaceAll('š', 's')
      .replaceAll('ý', 'y').replaceAll('ř', 'r').replaceAll('ů', 'u')
      .replaceAll(RegExp(r"[.\-_/'\\()]"), ' ')
      .toLowerCase();
  final tokens = s.split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !_noise.contains(t))
      .map((t) => _wordTrToEn[t] ?? t)
      .toList();
  return tokens.join(' ').trim();
}

// ── teams.json logo index ─────────────────────────────────────────────────────

class _LogoIndex {
  /// {(normName, countryLower): logo}  — tam eşleşme
  final Map<String, String> _exact = {};
  /// normalize isim listesi — fuzzy için
  final List<String> _names = [];
  /// _names ile aynı sıra
  final List<String> _logos = [];
  final List<String> _countries = [];
  int matched = 0;
  int fallback = 0;

  _LogoIndex(List<dynamic> teams) {
    for (final t in teams) {
      final name    = (t['name']    as String? ?? '').trim();
      final country = (t['country'] as String? ?? '').trim();
      final logo    = (t['api_logo'] as String? ?? '').trim();
      if (name.isEmpty || logo.isEmpty) continue;
      final n = _norm(name);
      _exact['$n|${country.toLowerCase()}'] = logo;
      _exact['$n|'] = logo;   // ülkesiz fallback
      _names.add(n);
      _logos.add(logo);
      _countries.add(country.toLowerCase());
    }
    print('🗂  Logo index: ${_names.length} takım (teams.json)');
  }

  /// teamName: Bilyoner'den gelen ham isim
  /// leagueCountry: extractCountryFromLeague() ile çıkarılmış İngilizce ülke
  String resolve(String teamName, String leagueCountry, int? teamId) {
    if (teamName.isEmpty) return _mackolik(teamId);
    final q       = _norm(teamName);
    final country = leagueCountry.toLowerCase();

    // 1. Tam isim + ülke
    final exact = _exact['\$q|\$country'];
    if (exact != null && exact.isNotEmpty) { matched++; return exact; }

    // 2. Tam isim + ülkesiz fallback
    final noCountry = _exact['\$q|'];
    if (noCountry != null && noCountry.isNotEmpty) {
      matched++;
      return noCountry;
    }

    // 3. Fuzzy
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

    if (bestScore >= 0.62) {
      // Ülke farklıysa büyük ceza
      if (country.isNotEmpty && bestCountry.isNotEmpty && country != bestCountry) {
        bestScore -= 0.25;
      }
      if (bestScore >= 0.58 && bestLogo.isNotEmpty) {
        matched++;
        return bestLogo;
      }
    }

    // 4. Mackolik CDN fallback — en azından bir logo göster
    fallback++;
    return _mackolik(teamId);
  }

  /// Mackolik CDN URL'i — teamId Bilyoner htpi/atpi
  String _mackolik(int? teamId) =>
      teamId != null ? 'https://im.mackolik.com/img/logo/buyuk/\$teamId.gif' : '';

  /// Gelişmiş token skoru:
  ///   - Tam token eşleşmesi (Jaccard)
  ///   - Prefix eşleşmesi: "f" → "fortuna", "b" → "borussia
  ///   - Suffix eşleşmesi: "sittard" ∈ "fortuna sittard"
  double _tokenScore(String a, String b) {
    if (a == b) return 1.0;
    final ta = a.split(' ');
    final tb = b.split(' ');
    if (ta.isEmpty || tb.isEmpty) return 0.0;

    // Her a token'i için en iyi eşleşmeyi bul
    int matched = 0;
    for (final at in ta) {
      bool found = false;
      for (final bt in tb) {
        if (at == bt) { found = true; break; }
        // Prefix: kısa token uzun tokenin başı olabilir
        // tek karakter bile prefix sayılır (F. Sittard → Fortuna Sittard)
        if (bt.startsWith(at)) { found = true; break; }
        if (at.startsWith(bt)) { found = true; break; }
        // 3+ karakter prefix
        if (at.length >= 3 && bt.length >= 3) {
          final minLen = at.length < bt.length ? at.length : bt.length;
          final prefLen = minLen < 4 ? minLen : 4;
          if (at.substring(0, prefLen) == bt.substring(0, prefLen)) {
            found = true; break;
          }
        }
      }
      if (found) matched++;
    }

    // Sorgunun TÜM tokenleri eşleştiyse yüksek puan — "Hannover" → "Hannover 96" gibi
    final tokenRatio = ta.isEmpty ? 0.0 : matched / ta.length;

    // b'deki önemli tokenler a'da geçiyor mu?
    int bInA = 0;
    for (final bt in tb) {
      if (bt.length < 3) continue;
      for (final at in ta) {
        if (at == bt || at.contains(bt) || bt.contains(at)) { bInA++; break; }
      }
    }
    final bRatio = tb.isEmpty ? 0.0 : bInA / tb.length;

    return (tokenRatio * 0.7 + bRatio * 0.3).clamp(0.0, 1.0);
  }
}

Future<_LogoIndex> _loadLogoIndex() async {
  try {
    final res = await http.get(Uri.parse(_teamsJsonUrl))
        .timeout(const Duration(seconds: 20));
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
  // İki kelimeli
  'guney_afrika':'South Africa','kuzey_irlanda':'Northern Ireland',
  'kosta_rika':'Costa Rica','el_salvador':'El Salvador',
  'suudi_arabistan':'Saudi Arabia','faroe_adalari':'Faroe Islands',
  'guney_kore':'South Korea','yeni_zelanda':'New Zealand',
};

String _normForCountry(String s) => s
    .toLowerCase()
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
        if (attempt < 2) { await Future.delayed(Duration(seconds: (attempt + 1) * 15)); continue; }
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
  required String country,
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
      'home': {'id': htpi, 'name': ev['htn'] ?? '', 'logo': homeLogo, 'winner': null},
      'away': {'id': atpi, 'name': ev['atn'] ?? '', 'logo': awayLogo, 'winner': null},
    },
    'league': {
      'id':        (ev['competitionId'] as num?)?.toInt() ?? 0,
      'name':      ev['lgn'] ?? '',
      'logo':      '',
      'country':   country,
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
      Uri.parse('$sbUrl/rest/v1/live_matches?score_source=neq.nesine&status_short=eq.NS'),
      headers: h,
    ).timeout(const Duration(seconds: 15));
    print('🗑  live_matches NS non-nesine → silindi [${r.statusCode}]');
  } catch (e) { print('⚠️  live_matches temizleme: $e'); }
  try {
    final r = await http.delete(
      Uri.parse('$sbUrl/rest/v1/future_matches?fixture_id=gte.0'),
      headers: h,
    ).timeout(const Duration(seconds: 15));
    print('🗑  future_matches → silindi [${r.statusCode}]');
  } catch (e) { print('⚠️  future_matches temizleme: $e'); }
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
    final chunk = records.sublist(i, (i + _batchSize).clamp(0, records.length));
    try {
      await sb.from(table).upsert(chunk, onConflict: onConflict);
    } catch (e) {
      print('  ⚠️  $table batch upsert hatası (${i}–${i + chunk.length}): $e');
      errors += chunk.length;
    }
  }
  return errors;
}

// ── main ─────────────────────────────────────────────────────────────────────

Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';
  if (sbUrl.isEmpty || sbKey.isEmpty) { print('❌ SUPABASE_URL veya SUPABASE_KEY eksik'); exit(1); }

  final sb    = SupabaseClient(sbUrl, sbKey);
  final trNow = DateTime.now().toUtc().add(const Duration(hours: 3));
  final pad   = (int n) => n.toString().padLeft(2, '0');
  final todayStr  = '${trNow.year}-${pad(trNow.month)}-${pad(trNow.day)}';
  final cutoff    = trNow.add(const Duration(days: 5));
  final cutoffStr = '${cutoff.year}-${pad(cutoff.month)}-${pad(cutoff.day)}';

  print('📅 Fikstür senkronizasyonu — ${DateTime.now().toIso8601String()}');
  print('🗓  Bugün (TR): $todayStr  |  Kesim: $cutoffStr');

  // ═══ 0) teams.json → logo index ══════════════════════════════════
  print('\n── Logo index yükleniyor (teams.json) ──');
  final logoIndex = await _loadLogoIndex();

  // ═══ 1) Temizlik ════════════════════════════════════════════════
  print('\n── Eski kayıt temizliği ──');
  await _cleanStaleRecords(sbUrl, sbKey);

  // ═══ 2) Bilyoner verilerini çek ═════════════════════════════════
  print('\n── Canlı maçlar çekiliyor (bulletinType=1) ──');
  final liveEvents    = await _fetchGamelist(tabType: 1, bulletinType: 1);
  print('\n── Maç önü bülteni çekiliyor (bulletinType=2) ──');
  final prematchEvents = await _fetchGamelist(tabType: 1, bulletinType: 2);

  final Map<int, Map<String, dynamic>> allEventsMap = {};
  for (final ev in prematchEvents) { allEventsMap[(ev['id'] as num).toInt()] = ev; }
  for (final ev in liveEvents)     { allEventsMap[(ev['id'] as num).toInt()] = ev; }
  final allEvents = allEventsMap.values.toList();

  // ═══ 3) Aktif canlı maçları al ══════════════════════════════════
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
  } catch (e) { print('  ⚠️  Canlı durum sorgulanamadı: $e'); }

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
    final lgn    = ev['lgn'] as String? ?? '';
    final htn    = ev['htn'] as String? ?? '';
    final atn    = ev['atn'] as String? ?? '';

    // Ülkeyi bir kez çıkar, hem logo lookup hem league.country için kullan
    final country  = extractCountryFromLeague(lgn);
    final homeLogo = logoIndex.resolve(htn, country, htpi);
    final awayLogo = logoIndex.resolve(atn, country, atpi);
    final rawData  = _buildRawData(ev, homeLogo: homeLogo, awayLogo: awayLogo, country: country);

    if (date == todayStr) {
      if (!liveFixtureIds.contains(id)) {
        liveUpserts.add({
          'fixture_id':   id,
          'home_team':    htn,
          'away_team':    atn,
          'home_team_id': htpi,
          'away_team_id': atpi,
          'home_logo':    homeLogo,
          'away_logo':    awayLogo,
          'home_score':   0,
          'away_score':   0,
          'status_short': 'NS',
          'elapsed_time': null,
          'league_id':    compId,
          'league_name':  lgn,
          'league_logo':  '',
          'betradar_id':  brdId,
          'score_source': 'bilyoner',
          'raw_data':     rawData,
          'updated_at':   DateTime.now().toIso8601String(),
        });
      }
      futureUpserts.add({
        'fixture_id': id, 'date': todayStr,
        'league_id':  compId, 'data': rawData,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } else if (date.isNotEmpty &&
               date.compareTo(todayStr) > 0 &&
               date.compareTo(cutoffStr) < 0) {
      futureUpserts.add({
        'fixture_id': id, 'date': date,
        'league_id':  compId, 'data': rawData,
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

  final totalErr = liveErr + futureErr;

  print('\n═══════════════════════════════');
  print('  🗂  Logo index   : ${logoIndex._names.length} takım');
  print('  ✅ Logo eşleşti  : ${logoIndex.matched}');
  print('  ⬜ Logo bulunamadı: ${logoIndex.fallback} (boş bırakıldı)');
  print('  ✅ live_matches  : ${liveUpserts.length - liveErr} yazıldı');
  print('  ✅ future_matches: ${futureUpserts.length - futureErr} yazıldı');
  if (liveFixtureIds.isNotEmpty) print('  ⚽ Canlı korunan : ${liveFixtureIds.length}');
  if (totalErr > 0) print('  ❌ Hatalı        : $totalErr');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(totalErr > 0 ? 1 : 0);
}
