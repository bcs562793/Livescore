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

const _nicknames = <String, String>{
  'spurs': 'tottenham',
  'inter': 'internazionale',
};

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

const _noise = <String>{
  'fc','sc','cf','ac','if','bk','sk','fk',
  'afc','bfc','cfc','sfc','rfc',
  'cp','cd','sd','ud','rc','rcd','as','ss',
};

String _norm(String name) {
  var s = name.toLowerCase().trim();
  if (_nicknames.containsKey(s)) s = _nicknames[s]!;
  s = s.replaceAll('ş', 's').replaceAll('ğ', 'g').replaceAll('ü', 'u')
      .replaceAll('ö', 'o').replaceAll('ç', 'c').replaceAll('ı', 'i')
      .replaceAll(RegExp(r"[éèê]"), 'e')
      .replaceAll(RegExp(r"[áàâãäå]"), 'a')
      .replaceAll(RegExp(r"[óòôõø]"), 'o')
      .replaceAll(RegExp(r"[úùûů]"), 'u')
      .replaceAll(RegExp(r"[íìî]"), 'i')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r"[ćč]"), 'c')
      .replaceAll('ž', 'z').replaceAll('š', 's')
      .replaceAll('ý', 'y').replaceAll('ř', 'r');
  s = s.replaceAll(RegExp(r"[.\-_/'\\()]"), ' ');
  final tokens = s.split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !_noise.contains(t))
      .map((t) => _wordTrToEn[t] ?? t)
      .toList();
  return tokens.join(' ').trim();
}

// ── teams.json logo index ─────────────────────────────────────────────────────

class _MatchResult {
  final String bilyonerName;
  final String country;
  final String matchedName;
  final double score;
  final String logoUrl;
  final String method;
  const _MatchResult({
    required this.bilyonerName,
    required this.country,
    required this.matchedName,
    required this.score,
    required this.logoUrl,
    required this.method,
  });
}

class _LogoIndex {
  final Map<String, String> _exact = {};
  final List<String> _names     = [];
  final List<String> _logos     = [];
  final List<String> _mackoliks = [];
  final List<String> _countries = [];
  int matched  = 0;
  int fallback = 0;

  final Map<String, _MatchResult> _log = {};

  _LogoIndex(List<dynamic> teams) {
    for (final t in teams) {
      final name        = (t['n'] as String? ?? '').trim();
      final country     = (t['c'] as String? ?? '').trim();
      final logo        = (t['l'] as String? ?? '').trim();
      final mackolikUrl = (t['m'] as String? ?? '').trim();
      if (name.isEmpty || logo.isEmpty) continue;
      final normalized = _norm(name);
      _exact['$normalized|${country.toLowerCase()}'] = logo;
      _exact['$normalized|'] = logo;
      _names.add(normalized);
      _logos.add(logo);
      _mackoliks.add(mackolikUrl);
      _countries.add(country.toLowerCase());
    }
    print('🗂  Logo index: ${_names.length} takım (teams.json)');
  }

  String resolve(String teamName, String leagueCountry, int? teamId) {
    final logKey = '$teamName|$leagueCountry';

    String _record(_MatchResult r) {
      if (!_log.containsKey(logKey)) _log[logKey] = r;
      return r.logoUrl;
    }

    if (teamName.isEmpty) {
      return _record(_MatchResult(
        bilyonerName: teamName, country: leagueCountry,
        matchedName: '', score: -1,
        logoUrl: _fallbackUrl(null, teamId), method: 'empty',
      ));
    }

    final q       = _norm(teamName);
    final country = leagueCountry.toLowerCase();

    final exactWithCountry = _exact['$q|$country'];
    if (exactWithCountry != null && exactWithCountry.isNotEmpty) {
      matched++;
      return _record(_MatchResult(
        bilyonerName: teamName, country: leagueCountry,
        matchedName: q, score: 1.0,
        logoUrl: exactWithCountry, method: 'exact',
      ));
    }

    final exactNoCountry = _exact['$q|'];
    if (exactNoCountry != null && exactNoCountry.isNotEmpty) {
      matched++;
      return _record(_MatchResult(
        bilyonerName: teamName, country: leagueCountry,
        matchedName: q, score: 1.0,
        logoUrl: exactNoCountry, method: 'exact',
      ));
    }

    int    bestIdx   = -1;
    double bestScore = 0;
    for (int i = 0; i < _names.length; i++) {
      final score = _tokenScore(q, _names[i]);
      if (score > bestScore) { bestScore = score; bestIdx = i; }
    }

    if (bestIdx >= 0 && bestScore >= 0.55) {
      double adjustedScore = bestScore;
      if (country.isNotEmpty &&
          _countries[bestIdx].isNotEmpty &&
          country != _countries[bestIdx]) {
        if (bestScore < 0.80) adjustedScore -= 0.10;
      }
      if (adjustedScore >= 0.50 && _logos[bestIdx].isNotEmpty) {
        matched++;
        return _record(_MatchResult(
          bilyonerName: teamName, country: leagueCountry,
          matchedName: _names[bestIdx], score: adjustedScore,
          logoUrl: _logos[bestIdx], method: 'fuzzy',
        ));
      }
    }

    fallback++;
    final mackolikFromIndex = (bestIdx >= 0) ? _mackoliks[bestIdx] : '';
    final fallbackUrl = _fallbackUrl(mackolikFromIndex, teamId);
    final method = fallbackUrl.isEmpty
        ? 'empty'
        : (mackolikFromIndex.isNotEmpty ? 'fallback_m' : 'fallback_id');
    return _record(_MatchResult(
      bilyonerName: teamName, country: leagueCountry,
      matchedName: bestIdx >= 0 ? _names[bestIdx] : '',
      score: bestIdx >= 0 ? bestScore : -1,
      logoUrl: fallbackUrl, method: method,
    ));
  }

  void printReport() {
    final results  = _log.values.toList();
    final matched  = results.where((r) => r.method == 'exact' || r.method == 'fuzzy').toList();
    final fallbacks = results.where((r) => r.method.startsWith('fallback') || r.method == 'empty').toList();

    if (fallbacks.isNotEmpty) {
      print('\n── ⚠️  Eşleşemeyen takımlar (${fallbacks.length}) ──');
      for (final r in fallbacks..sort((a, b) => a.bilyonerName.compareTo(b.bilyonerName))) {
        final scoreStr = r.score >= 0 ? ' (en yakın skor: ${r.score.toStringAsFixed(2)}, "${r.matchedName}")' : '';
        print('  ✗ [${r.method.padRight(11)}] "${r.bilyonerName}" [${r.country}]$scoreStr');
      }
    }

    print('\n── ✅ Eşleşen takımlar (${matched.length}) ──');
    for (final r in matched..sort((a, b) => a.bilyonerName.compareTo(b.bilyonerName))) {
      final detail = r.method == 'fuzzy'
          ? ' → "${r.matchedName}" (skor: ${r.score.toStringAsFixed(2)})'
          : '';
      print('  ✓ [${r.method.padRight(5)}] "${r.bilyonerName}" [${r.country}]$detail');
    }
  }

  String _fallbackUrl(String? mackolikFromIndex, int? teamId) {
    if (mackolikFromIndex != null && mackolikFromIndex.isNotEmpty) return mackolikFromIndex;
    if (teamId != null) return 'https://im.mackolik.com/img/logo/buyuk/$teamId.gif';
    return '';
  }

  double _tokenScore(String qStr, String tStr) {
    if (qStr == tStr) return 1.0;
    final qTokens = qStr.split(' ');
    final tTokens = tStr.split(' ');
    if (qTokens.isEmpty || tTokens.isEmpty) return 0.0;

    if (qTokens.length == 1 && tTokens.length > 1) {
      final initials = tTokens.map((t) => t[0]).join('');
      if (initials == qTokens[0] || initials.startsWith(qTokens[0])) return 0.95;
    }

    double totalScore = 0.0;
    int matchedTargetTokens = 0;
    for (final qt in qTokens) {
      double bestMatch = 0.0;
      for (final tt in tTokens) {
        double currentScore = 0.0;
        if (qt == tt) {
          currentScore = 1.0;
        } else if (tt.startsWith(qt)) {
          currentScore = qt.length == 1 ? 0.85 : 0.85 + ((qt.length / tt.length) * 0.15);
        } else if (qt.startsWith(tt)) {
          currentScore = 0.80;
        } else {
          final minLen = qt.length < tt.length ? qt.length : tt.length;
          if (minLen >= 4) {
            if (qt.substring(0, 4) == tt.substring(0, 4)) currentScore = 0.70;
          } else if (tt.contains(qt) || qt.contains(tt)) {
            if (qt.length >= 3) currentScore = 0.65;
          }
        }
        if (currentScore > bestMatch) bestMatch = currentScore;
      }
      totalScore += bestMatch;
      if (bestMatch >= 0.65) matchedTargetTokens++;
    }
    final qRatio = totalScore / qTokens.length;
    final tRatio = matchedTargetTokens / tTokens.length;
    return (qRatio * 0.85) + (tRatio * 0.15);
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
    return _LogoIndex(jsonDecode(res.body) as List);
  } catch (e) {
    print('⚠️  teams.json yüklenemedi: $e');
    return _LogoIndex([]);
  }
}

// ── Mackolik livedata — league_id haritası ────────────────────────────────────
//
// Endpoint: https://vd.mackolik.com/livedata?date=DD/MM/YYYY
//
// Yanıt listesinde iki tür giriş vardır:
//   Lig başlığı : [countryId, "ÜlkeAdı", ligSıraNo, "LigAdı", mackolikLigId, "Sezon", ...]
//   Maç kaydı  : [mackolikMatchId, homeId, "EvsahibiAdı", awayId, "MisafirAdı", ...]
//
// Ayrıştırıcı, lig başlığındaki index[4] değerini (örn. 70381) cari lig ID'si
// olarak tutar; ardından gelen her maç satırındaki index[0] (matchId) bu
// league_id ile eşlenir.  Böylece ev → future_matches.league_id doğru gelir.

/// [date] formatı: "DD/MM/YYYY"  (örn. "02/05/2026")
Future<Map<int, int>> _buildMackolikLeagueMap(Iterable<String> dates) async {
  final result = <int, int>{};
  bool firstResponse = true;

  for (final date in dates) {
    try {
      final url = Uri.parse('https://vd.mackolik.com/livedata?date=$date');
      final res = await http.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Referer':    'https://www.mackolik.com/',
        'Accept':     'application/json, text/plain, */*',
      }).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        print('⚠️  Mackolik livedata HTTP ${res.statusCode} ($date)');
        continue;
      }

      final body  = jsonDecode(res.body);
      final count = _parseMackolikResponse(body, result, debugFirst: firstResponse);
      firstResponse = false;
      print('📡 Mackolik livedata ($date): $count maç eklendi (toplam: ${result.length})');
    } catch (e) {
      print('⚠️  Mackolik livedata ($date): $e');
    }
  }

  return result;
}

/// Yanıt gövdesini ayrıştırır; eşleşen maç sayısını döndürür.
int _parseMackolikResponse(
  dynamic body,
  Map<int, int> out, {
  bool debugFirst = false,
}) {
  int count = 0;

  // Ana listeyi bul (d / data / matches / result veya root List)
  List? items;
  if (body is List) {
    items = body;
  } else if (body is Map) {
    items = body['d']       as List? ??
            body['data']    as List? ??
            body['matches'] as List? ??
            body['result']  as List?;
    if (items == null) {
      for (final v in body.values) {
        if (v is List && v.isNotEmpty) { items = v; break; }
      }
    }
  }

  if (items == null || items.isEmpty) {
    print('  ⚠️  Mackolik: liste boş veya bilinmeyen yapı — body tipi: ${body.runtimeType}');
    return 0;
  }

  if (debugFirst) {
    print('  🔍 Mackolik veri yapısı (ilk 2 öğe): ${items.take(2).toList()}');
  }

  int currentLeagueId = 0;

  for (final item in items) {
    if (item is! List || item.isEmpty) continue;

    // ── Lig başlığı tespiti ───────────────────────────────────────────────
    // Örnek: [1, "Türkiye", 1, "Süper Lig", 70381, "2025/2026", ...]
    //  • index[1] String (ülke adı)
    //  • index[3] String (lig adı)
    //  • index[4] num   (Mackolik lig ID — büyük tam sayı)
    if (item.length >= 5 &&
        item[1] is String &&
        item[3] is String &&
        item[4] is num) {
      final leagueId = (item[4] as num).toInt();
      if (leagueId > 0) {
        currentLeagueId = leagueId;
      }
      continue; // Bu satır maç değil, listeye eklenmiyor
    }

    // ── Maç kaydı tespiti ─────────────────────────────────────────────────
    // Örnek: [matchId, homeTeamId, "Ev Sahibi", awayTeamId, "Misafir", ...]
    //  • index[0] num (matchId)
    //  • currentLeagueId > 0 (bir lig başlığı görüldü)
    if (currentLeagueId > 0 && item[0] is num) {
      final matchId = (item[0] as num).toInt();
      if (matchId > 0) {
        out[matchId] = currentLeagueId;
        count++;
      }
    }
  }

  return count;
}

/// DD/MM/YYYY dizisi üretir: [bugün, bugün+1, ..., bugün+(days-1)]
List<String> _mackolikDates(DateTime trNow, int days) {
  final pad = (int n) => n.toString().padLeft(2, '0');
  return List.generate(days, (i) {
    final d = trNow.add(Duration(days: i));
    return '${pad(d.day)}/${pad(d.month)}/${d.year}';
  });
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
      if (football.isNotEmpty) {
        print('🔑 Event keys: ${football.first.keys.toList()}');
        print('🔍 First event sample: ${football.first}');
      }
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
  required int leagueId,       // ← Mackolik league_id
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
      'id':        leagueId,   // ← Mackolik'ten gelen gerçek ID
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

  // ═══ 1) Mackolik livedata → league_id haritası ═══════════════════
  //
  // Bugün dahil 6 gün boyunca (bugün + 5 gün) Mackolik'ten lig ID'lerini çekiyoruz.
  // Bu, Bilyoner'den gelen tüm maçların (live + prematch) tarih aralığını kapsar.
  print('\n── Mackolik league_id haritası oluşturuluyor ──');
  final mackolikDates  = _mackolikDates(trNow, 6);   // ["02/05/2026", "03/05/2026", ...]
  final leagueIdMap    = await _buildMackolikLeagueMap(mackolikDates);
  print('🏆 Toplam ${leagueIdMap.length} maç için Mackolik league_id bulundu');

  // ═══ 2) Temizlik ════════════════════════════════════════════════
  print('\n── Eski kayıt temizliği ──');
  await _cleanStaleRecords(sbUrl, sbKey);

  // ═══ 3) Bilyoner verilerini çek ═════════════════════════════════
  print('\n── Canlı maçlar çekiliyor (bulletinType=1) ──');
  final liveEvents     = await _fetchGamelist(tabType: 1, bulletinType: 1);
  print('\n── Maç önü bülteni çekiliyor (bulletinType=2) ──');
  final prematchEvents = await _fetchGamelist(tabType: 1, bulletinType: 2);

  final Map<int, Map<String, dynamic>> allEventsMap = {};
  for (final ev in prematchEvents) { allEventsMap[(ev['id'] as num).toInt()] = ev; }
  for (final ev in liveEvents)     { allEventsMap[(ev['id'] as num).toInt()] = ev; }
  final allEvents = allEventsMap.values.toList();

  // ═══ 4) Aktif canlı maçları al ══════════════════════════════════
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

  // ═══ 5) Kayıtları hazırla ════════════════════════════════════════
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

    // Mackolik league_id: haritada varsa kullan, yoksa 0
    final mackolikLeagueId = leagueIdMap[id] ?? 0;

    final country  = extractCountryFromLeague(lgn);
    final homeLogo = logoIndex.resolve(htn, country, htpi);
    final awayLogo = logoIndex.resolve(atn, country, atpi);
    final rawData  = _buildRawData(
      ev,
      homeLogo:  homeLogo,
      awayLogo:  awayLogo,
      country:   country,
      leagueId:  mackolikLeagueId,   // ← artık doğru değer
    );

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
          'league_id':    mackolikLeagueId,   // ← Mackolik'ten gelen ID
          'league_name':  lgn,
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
        'league_id':  mackolikLeagueId,   // ← Mackolik'ten gelen ID
        'data':       rawData,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } else if (date.isNotEmpty &&
               date.compareTo(todayStr) > 0 &&
               date.compareTo(cutoffStr) < 0) {
      futureUpserts.add({
        'fixture_id': id,
        'date':       date,
        'league_id':  mackolikLeagueId,   // ← Mackolik'ten gelen ID
        'data':       rawData,
        'updated_at': DateTime.now().toIso8601String(),
      });
    }
  }

  // ═══ 6) Batch upsert ════════════════════════════════════════════
  print('\n── Yazılıyor ──');
  print('  live_matches  : ${liveUpserts.length} kayıt');
  print('  future_matches: ${futureUpserts.length} kayıt');

  final liveErr   = await _batchUpsert(sb, 'live_matches',   liveUpserts,   'fixture_id');
  final futureErr = await _batchUpsert(sb, 'future_matches', futureUpserts, 'fixture_id');

  final totalErr  = liveErr + futureErr;

  // ═══ 7) Eşleşme raporu ══════════════════════════════════════════
  logoIndex.printReport();

  // league_id bulunamayan maçları raporla
  final missingLeague = allEvents.where((ev) {
    final id = (ev['id'] as num).toInt();
    return (leagueIdMap[id] ?? 0) == 0;
  }).length;
  if (missingLeague > 0) {
    print('\n── ⚠️  Mackolik league_id bulunamayan maç sayısı: $missingLeague ──');
  }

  print('\n═══════════════════════════════');
  print('  🗂  Logo index   : ${logoIndex._names.length} takım');
  print('  ✅ Logo eşleşti  : ${logoIndex.matched}');
  print('  ⬜ Logo bulunamadı: ${logoIndex.fallback} (m alanı / Mackolik CDN)');
  print('  🏆 League ID     : ${leagueIdMap.length} eşleşti, $missingLeague eksik');
  print('  ✅ live_matches  : ${liveUpserts.length - liveErr} yazıldı');
  print('  ✅ future_matches: ${futureUpserts.length - futureErr} yazıldı');
  if (liveFixtureIds.isNotEmpty) print('  ⚽ Canlı korunan : ${liveFixtureIds.length}');
  if (totalErr > 0) print('  ❌ Hatalı        : $totalErr');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(totalErr > 0 ? 1 : 0);
}
