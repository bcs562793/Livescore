import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

// ── Sabitler ──────────────────────────────────────────────────────────────────

const _teamsJsonUrl =
    'https://raw.githubusercontent.com/bcs562793/H2Hscrape/main/data/teams.json';

const _mackolikBase = 'https://vd.mackolik.com';

// Mackolik m[] array alan indeksleri
// [0]  fixture_id (Mackolik internal ID)
// [1]  home_team_id
// [2]  home_team_name
// [3]  away_team_id
// [4]  away_team_name
// [5]  sport_type   (4=futbol, 13=basketbol, ...)
// [6]  status_text  ("MS"=bitti, "IY"=ilk yarı bitti, "45'"=dakika, "Pen", "UZ", "Ert.", ""=başlamadı)
// [7]  score        ("1-1" | "")
// [12] home_goals   (int)
// [13] away_goals   (int)
// [14] betradar_id
// [15] extra_obj    {aeleme, e, goal, h1, h2, k1, k2, ogd, tId}
// [16] time         ("17:00")
// [17] live_flag    (0/1)
// [34] tier         ("1","2","3","4")
// [35] date         ("DD/MM/YYYY")
// [36] league_array [country_id, country_name_tr, league_id, league_name_tr, season_id, season_str, "", cup, ?, league_code, ?, ?]
// [37] has_odds     (0/1)

// ── Normalizasyon ─────────────────────────────────────────────────────────────

const _nicknames = <String, String>{
  'spurs': 'tottenham',
  'inter': 'internazionale',
};

const _wordTrToEn = <String, String>{
  'munih': 'munich',
  'munchen': 'munich',
  'marsilya': 'marseille',
  'kopenhag': 'copenhagen',
  'bruksel': 'brussels',
  'prag': 'prague',
  'lizbon': 'lisbon',
  'viyana': 'vienna',
};

const _noise = <String>{
  'fc', 'sc', 'cf', 'ac', 'if', 'bk', 'sk', 'fk',
  'afc', 'bfc', 'cfc', 'sfc', 'rfc',
  'cp', 'cd', 'sd', 'ud', 'rc', 'rcd', 'as', 'ss',
};

String _norm(String name) {
  var s = name.toLowerCase().trim();
  if (_nicknames.containsKey(s)) s = _nicknames[s]!;
  s = s
      .replaceAll('ş', 's').replaceAll('ğ', 'g').replaceAll('ü', 'u')
      .replaceAll('ö', 'o').replaceAll('ç', 'c').replaceAll('ı', 'i')
      .replaceAll(RegExp(r'[éèê]'), 'e').replaceAll(RegExp(r'[áàâãäå]'), 'a')
      .replaceAll(RegExp(r'[óòôõø]'), 'o').replaceAll(RegExp(r'[úùûů]'), 'u')
      .replaceAll(RegExp(r'[íìî]'), 'i').replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[ćč]'), 'c').replaceAll('ž', 'z')
      .replaceAll('š', 's').replaceAll('ý', 'y').replaceAll('ř', 'r');
  s = s.replaceAll(RegExp(r"[.\-_/'\\()]"), ' ');
  final tokens = s
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !_noise.contains(t))
      .map((t) => _wordTrToEn[t] ?? t)
      .toList();
  return tokens.join(' ').trim();
}

// ── Logo index ────────────────────────────────────────────────────────────────

class _MatchResult {
  final String bilyonerName, country, matchedName, logoUrl, method;
  final double score;
  const _MatchResult({
    required this.bilyonerName, required this.country,
    required this.matchedName,  required this.score,
    required this.logoUrl,      required this.method,
  });
}

class _LogoIndex {
  final Map<String, String> _exact = {};
  final List<String> _names = [], _logos = [], _mackoliks = [], _countries = [];
  int matched = 0, fallback = 0;
  final Map<String, _MatchResult> _log = {};

  _LogoIndex(List<dynamic> teams) {
    for (final t in teams) {
      final name = (t['n'] as String? ?? '').trim();
      final country = (t['c'] as String? ?? '').trim();
      final logo = (t['l'] as String? ?? '').trim();
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
    print('🗂  Logo index: ${_names.length} takım');
  }

  String resolve(String teamName, String country, int? teamId) {
    final logKey = '$teamName|$country';
    String record(_MatchResult r) {
      _log.putIfAbsent(logKey, () => r);
      return r.logoUrl;
    }

    if (teamName.isEmpty) {
      return record(_MatchResult(
        bilyonerName: teamName, country: country,
        matchedName: '', score: -1,
        logoUrl: _fallbackUrl(null, teamId), method: 'empty',
      ));
    }

    final q = _norm(teamName);
    final c = country.toLowerCase();

    final exactC = _exact['$q|$c'];
    if (exactC != null && exactC.isNotEmpty) {
      matched++;
      return record(_MatchResult(
        bilyonerName: teamName, country: country,
        matchedName: q, score: 1.0, logoUrl: exactC, method: 'exact',
      ));
    }

    final exactN = _exact['$q|'];
    if (exactN != null && exactN.isNotEmpty) {
      matched++;
      return record(_MatchResult(
        bilyonerName: teamName, country: country,
        matchedName: q, score: 1.0, logoUrl: exactN, method: 'exact',
      ));
    }

    int bestIdx = -1;
    double bestScore = 0;
    for (int i = 0; i < _names.length; i++) {
      final score = _tokenScore(q, _names[i]);
      if (score > bestScore) { bestScore = score; bestIdx = i; }
    }

    if (bestIdx >= 0 && bestScore >= 0.55) {
      double adj = bestScore;
      if (c.isNotEmpty && _countries[bestIdx].isNotEmpty && c != _countries[bestIdx]) {
        if (bestScore < 0.80) adj -= 0.10;
      }
      if (adj >= 0.50 && _logos[bestIdx].isNotEmpty) {
        matched++;
        return record(_MatchResult(
          bilyonerName: teamName, country: country,
          matchedName: _names[bestIdx], score: adj,
          logoUrl: _logos[bestIdx], method: 'fuzzy',
        ));
      }
    }

    fallback++;
    final mk = bestIdx >= 0 ? _mackoliks[bestIdx] : '';
    final url = _fallbackUrl(mk, teamId);
    return record(_MatchResult(
      bilyonerName: teamName, country: country,
      matchedName: bestIdx >= 0 ? _names[bestIdx] : '',
      score: bestIdx >= 0 ? bestScore : -1,
      logoUrl: url,
      method: url.isEmpty ? 'empty' : (mk.isNotEmpty ? 'fallback_m' : 'fallback_id'),
    ));
  }

  void printReport() {
    final results = _log.values.toList();
    final ok = results.where((r) => r.method == 'exact' || r.method == 'fuzzy').toList();
    final bad = results.where((r) => r.method.startsWith('fallback') || r.method == 'empty').toList();
    if (bad.isNotEmpty) {
      print('\n── ⚠️  Eşleşemeyen takımlar (${bad.length}) ──');
      for (final r in bad..sort((a, b) => a.bilyonerName.compareTo(b.bilyonerName))) {
        final s = r.score >= 0 ? ' (en yakın: ${r.score.toStringAsFixed(2)}, "${r.matchedName}")' : '';
        print('  ✗ [${r.method.padRight(11)}] "${r.bilyonerName}" [${r.country}]$s');
      }
    }
    print('\n── ✅ Eşleşen takımlar (${ok.length}) ──');
    for (final r in ok..sort((a, b) => a.bilyonerName.compareTo(b.bilyonerName))) {
      final d = r.method == 'fuzzy' ? ' → "${r.matchedName}" (${r.score.toStringAsFixed(2)})' : '';
      print('  ✓ [${r.method.padRight(5)}] "${r.bilyonerName}" [${r.country}]$d');
    }
  }

  String _fallbackUrl(String? mk, int? teamId) {
    if (mk != null && mk.isNotEmpty) return mk;
    if (teamId != null) return 'https://im.mackolik.com/img/logo/buyuk/$teamId.gif';
    return '';
  }

  double _tokenScore(String qStr, String tStr) {
    if (qStr == tStr) return 1.0;
    final qT = qStr.split(' '), tT = tStr.split(' ');
    if (qT.isEmpty || tT.isEmpty) return 0.0;
    if (qT.length == 1 && tT.length > 1) {
      final initials = tT.map((t) => t[0]).join('');
      if (initials == qT[0] || initials.startsWith(qT[0])) return 0.95;
    }
    double total = 0; int matched = 0;
    for (final qt in qT) {
      double best = 0;
      for (final tt in tT) {
        double cur = 0;
        if (qt == tt) { cur = 1.0; }
        else if (tt.startsWith(qt)) { cur = qt.length == 1 ? 0.85 : 0.85 + (qt.length / tt.length * 0.15); }
        else if (qt.startsWith(tt)) { cur = 0.80; }
        else {
          final min = qt.length < tt.length ? qt.length : tt.length;
          if (min >= 4 && qt.substring(0, 4) == tt.substring(0, 4)) { cur = 0.70; }
          else if ((tt.contains(qt) || qt.contains(tt)) && qt.length >= 3) { cur = 0.65; }
        }
        if (cur > best) best = cur;
      }
      total += best;
      if (best >= 0.65) matched++;
    }
    return (total / qT.length * 0.85) + (matched / tT.length * 0.15);
  }
}

Future<_LogoIndex> _loadLogoIndex() async {
  try {
    final res = await http.get(Uri.parse(_teamsJsonUrl))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) { print('⚠️  teams.json HTTP ${res.statusCode}'); return _LogoIndex([]); }
    return _LogoIndex(jsonDecode(res.body) as List);
  } catch (e) { print('⚠️  teams.json yüklenemedi: $e'); return _LogoIndex([]); }
}

// ── Mackolik status dönüşümleri ───────────────────────────────────────────────

String _statusShort(String s) {
  if (s.isEmpty) return 'NS';
  if (s == 'MS') return 'FT';
  if (s == 'IY') return 'HT';
  if (s == 'Ert.' || s == 'Ert') return 'PST';
  if (s == 'Pen') return 'PEN';
  if (s == 'UZ') return 'ET';
  final min = int.tryParse(s.replaceAll("'", ''));
  if (min != null) return min <= 45 ? '1H' : '2H';
  return 'NS';
}

int? _elapsedFrom(String s) => int.tryParse(s.replaceAll("'", ''));

String _statusLong(String short) => switch (short) {
  'NS'  => 'Not Started',
  'FT'  => 'Match Finished',
  'HT'  => 'Halftime',
  'PST' => 'Postponed',
  'PEN' => 'Penalty In Progress',
  'ET'  => 'Extra Time',
  '1H'  => 'First Half',
  '2H'  => 'Second Half',
  _     => 'Not Started',
};

// ── Tarih / saat yardımcıları ─────────────────────────────────────────────────

// "DD/MM/YYYY" + "HH:MM" → "YYYY-MM-DDTHH:MM:00+03:00"
String _toIso(String ddmmyyyy, String hhmm) {
  final dp = ddmmyyyy.split('/');
  if (dp.length != 3) return '';
  final d = dp[0].padLeft(2, '0'), mo = dp[1].padLeft(2, '0'), y = dp[2];
  final tp = hhmm.split(':');
  final h = tp.isNotEmpty ? tp[0].padLeft(2, '0') : '00';
  final mi = tp.length > 1 ? tp[1].padLeft(2, '0') : '00';
  return '$y-$mo-${d}T$h:$mi:00+03:00';
}

int _toTimestamp(String ddmmyyyy, String hhmm) {
  final iso = _toIso(ddmmyyyy, hhmm);
  if (iso.isEmpty) return 0;
  try { return DateTime.parse(iso).millisecondsSinceEpoch ~/ 1000; } catch (_) { return 0; }
}

// "DD/MM/YYYY" → "YYYY-MM-DD"
String _toDateKey(String ddmmyyyy) {
  final p = ddmmyyyy.split('/');
  if (p.length != 3) return '';
  return '${p[2]}-${p[1].padLeft(2, '0')}-${p[0].padLeft(2, '0')}';
}

// DateTime (TR) → "DD/MM/YYYY"
String _trDateToDDMMYYYY(DateTime tr) {
  final pad = (int n) => n.toString().padLeft(2, '0');
  return '${pad(tr.day)}/${pad(tr.month)}/${tr.year}';
}

// DateTime (TR) → "YYYY-MM-DD"
String _trDateToYMD(DateTime tr) {
  final pad = (int n) => n.toString().padLeft(2, '0');
  return '${tr.year}-${pad(tr.month)}-${pad(tr.day)}';
}

// ── Ülke çıkarma ──────────────────────────────────────────────────────────────

const _lgCountryMap = <String, String>{
  'almanya': 'Germany', 'ispanya': 'Spain',   'italya': 'Italy',
  'fransa': 'France',   'hollanda': 'Netherlands', 'portekiz': 'Portugal',
  'brezilya': 'Brazil', 'arjantin': 'Argentina',   'turkiye': 'Turkey',
  'turk': 'Turkey',     'belcika': 'Belgium',       'isvicre': 'Switzerland',
  'avustralya': 'Australia', 'japonya': 'Japan',    'danimarka': 'Denmark',
  'norvec': 'Norway',   'isvec': 'Sweden',    'finlandiya': 'Finland',
  'polonya': 'Poland',  'hirvatistan': 'Croatia',   'slovenya': 'Slovenia',
  'slovakya': 'Slovakia', 'cekya': 'Czech Republic', 'macaristan': 'Hungary',
  'romanya': 'Romania', 'bulgaristan': 'Bulgaria',  'sirbistan': 'Serbia',
  'yunanistan': 'Greece', 'avusturya': 'Austria',   'iskocya': 'Scotland',
  'ingiltere': 'England', 'galler': 'Wales',         'kolombiya': 'Colombia',
  'meksika': 'Mexico',  'sili': 'Chile',       'misir': 'Egypt',
  'fas': 'Morocco',     'cezayir': 'Algeria',  'nijerya': 'Nigeria',
  'gana': 'Ghana',      'abd': 'USA',          'kanada': 'Canada',
  'arnavutluk': 'Albania', 'karadag': 'Montenegro', 'letonya': 'Latvia',
  'litvanya': 'Lithuania', 'estonya': 'Estonia',    'ukrayna': 'Ukraine',
  'rusya': 'Russia',    'azerbaycan': 'Azerbaijan', 'gurcistan': 'Georgia',
  'ermenistan': 'Armenia', 'honduras': 'Honduras',  'guatemala': 'Guatemala',
  'panama': 'Panama',   'paraguay': 'Paraguay',     'uruguay': 'Uruguay',
  'bolivya': 'Bolivia', 'peru': 'Peru',        'ekvador': 'Ecuador',
  'tanzanya': 'Tanzania', 'kenya': 'Kenya',    'tunus': 'Tunisia',
  'irak': 'Iraq',       'suriye': 'Syria',     'iran': 'Iran',
  'katar': 'Qatar',     'hindistan': 'India',  'cin': 'China',
  'endonezya': 'Indonesia', 'tayland': 'Thailand', 'malezya': 'Malaysia',
  'izlanda': 'Iceland', 'kibris': 'Cyprus',    'israil': 'Israel',
  'kazakistan': 'Kazakhstan', 'ozbekistan': 'Uzbekistan',
  'irlanda': 'Ireland', 'irland': 'Ireland',
  'guney_afrika': 'South Africa',  'kuzey_irlanda': 'Northern Ireland',
  'kosta_rika': 'Costa Rica',      'el_salvador': 'El Salvador',
  'suudi_arabistan': 'Saudi Arabia', 'guney_kore': 'South Korea',
  'yeni_zelanda': 'New Zealand',   'kuzey_makedonya': 'North Macedonia',
  'bosna_hersek': 'Bosnia and Herzegovina',
};

String _normC(String s) => s
    .toLowerCase()
    .replaceAll('ş', 's').replaceAll('ğ', 'g').replaceAll('ü', 'u')
    .replaceAll('ö', 'o').replaceAll('ç', 'c').replaceAll('ı', 'i')
    .replaceAll('İ', 'i').replaceAll('â', 'a').replaceAll('î', 'i')
    .replaceAll('ô', 'o');

// Mackolik'te ülke adı direkt geliyor (m[36][1] = "Türkiye"), tek kelime → map
String _countryFromTr(String trName) {
  if (trName.isEmpty) return '';
  final words = trName.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    final k2 = '${_normC(words[0])}_${_normC(words[1])}';
    if (_lgCountryMap.containsKey(k2)) return _lgCountryMap[k2]!;
  }
  return _lgCountryMap[_normC(words[0])] ?? trName;
}

// ── Mackolik API ──────────────────────────────────────────────────────────────

Map<String, String> _mackolikHeaders() => {
  'accept': 'application/json, text/plain, */*',
  'accept-language': 'tr-TR,tr;q=0.9',
  'accept-encoding': 'gzip, deflate, br',
  'cache-control': 'no-cache',
  'pragma': 'no-cache',
  'referer': 'https://www.mackolik.com/',
  'origin': 'https://www.mackolik.com',
  'user-agent':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
};

/// Bir güne ait Mackolik verilerini çeker.
/// Sadece futbol (sport_type == 4) ve geçerli uzunluktaki (>=38) kayıtları döner.
Future<List<List<dynamic>>> _fetchMackolikDay(String ddmmyyyy) async {
  final uri = Uri.parse('$_mackolikBase/livedata?date=$ddmmyyyy');
  for (int attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 8));
    try {
      final res = await http
          .get(uri, headers: _mackolikHeaders())
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 403 || res.statusCode == 429) {
        print('⚠️  Mackolik engel [${res.statusCode}] ($ddmmyyyy, deneme ${attempt + 1}/3)');
        await Future.delayed(Duration(seconds: (attempt + 1) * 15));
        continue;
      }
      if (res.statusCode != 200) {
        print('⚠️  Mackolik HTTP ${res.statusCode} ($ddmmyyyy, deneme ${attempt + 1}/3)');
        continue;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final raw = body['m'] as List<dynamic>? ?? [];

      // Futbol filtresi: m[5] == 4, minimum 38 alan
      final football = raw
          .whereType<List<dynamic>>()
          .where((m) {
  if (m.length < 38) return false;
  final lgArr = m[36] as List<dynamic>? ?? const [];
  if (lgArr.length <= 11) return false;
  final sportType = (lgArr[11] as num?)?.toInt();
  return sportType == 1;
})
          .toList();

      print('📋 Mackolik $ddmmyyyy: ${raw.length} toplam → ${football.length} futbol');
      return football;
    } catch (e) {
      print('⚠️  Mackolik $ddmmyyyy hata (deneme ${attempt + 1}/3): $e');
    }
  }
  return [];
}

// ── raw_data builder ──────────────────────────────────────────────────────────

Map<String, dynamic> _buildRawData(
  List<dynamic> m, {
  required String homeLogo,
  required String awayLogo,
  required String country,
}) {
  final id       = (m[0] as num).toInt();
  final homeId   = (m[1] as num?)?.toInt();
  final awayId   = (m[3] as num?)?.toInt();
  final statusTx = (m[6]  as String?) ?? '';
  final scoreTx  = (m[7]  as String?) ?? '';
  final timeStr  = (m[16] as String?) ?? '';
  final dateStr  = (m[35] as String?) ?? '';   // "DD/MM/YYYY"
  final lgArr    = m[36] as List<dynamic>? ?? const [];

  final short    = _statusShort(statusTx);
  final elapsed  = _elapsedFrom(statusTx);
  final isoDate  = _toIso(dateStr, timeStr);
  final timestamp = _toTimestamp(dateStr, timeStr);

  int? homeGoals, awayGoals;
  if (scoreTx.contains('-')) {
    final parts = scoreTx.split('-');
    homeGoals = int.tryParse(parts[0].trim());
    awayGoals = int.tryParse(parts.length > 1 ? parts[1].trim() : '');
  }

  return {
    'fixture': {
      'id':        id,
      'timestamp': timestamp,
      'date':      isoDate,
      'timezone':  'Europe/Istanbul',
      'referee':   null,
      'periods':   {'first': null, 'second': null},
      'venue':     {'id': null, 'name': null, 'city': null},
      'status':    {'long': _statusLong(short), 'short': short, 'elapsed': elapsed, 'extra': null},
    },
    'teams': {
      'home': {'id': homeId, 'name': m[2] ?? '', 'logo': homeLogo, 'winner': null},
      'away': {'id': awayId, 'name': m[4] ?? '', 'logo': awayLogo, 'winner': null},
    },
    'league': {
      'id':        lgArr.length > 2 ? (lgArr[2] as num?)?.toInt() ?? 0 : 0,
      'name':      lgArr.length > 3 ? lgArr[3] as String? ?? '' : '',
      'logo':      '',
      'country':   country,
      'flag':      null,
      'season':    lgArr.length > 5 ? lgArr[5] as String? : null,
      'round':     null,
      'standings': false,
    },
    'goals': {'home': homeGoals ?? 0, 'away': awayGoals ?? 0},
    'score': {
      'halftime':  {'home': null, 'away': null},
      'fulltime':  {'home': null, 'away': null},
      'extratime': {'home': null, 'away': null},
      'penalty':   {'home': null, 'away': null},
    },
  };
}

// ── Temizlik ──────────────────────────────────────────────────────────────────

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

// ── Batch upsert ──────────────────────────────────────────────────────────────

const _batchSize = 200;

Future<int> _batchUpsert(
  SupabaseClient sb, String table,
  List<Map<String, dynamic>> records, String onConflict,
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

// ── main ──────────────────────────────────────────────────────────────────────

Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';
  if (sbUrl.isEmpty || sbKey.isEmpty) {
    print('❌ SUPABASE_URL veya SUPABASE_KEY eksik');
    exit(1);
  }

  final sb = SupabaseClient(sbUrl, sbKey);

  // Türkiye saatine göre bugün + 4 gün (toplam 5 gün)
  final trNow = DateTime.now().toUtc().add(const Duration(hours: 3));
  const totalDays = 5;

  final days = List.generate(totalDays, (i) {
    final d = trNow.add(Duration(days: i));
    return (
      ddmmyyyy: _trDateToDDMMYYYY(d),   // Mackolik API formatı
      ymd:      _trDateToYMD(d),         // DB formatı
    );
  });

  final todayYMD = days[0].ymd;

  print('📅 Fixture sync (Mackolik) — ${DateTime.now().toIso8601String()}');
  print('🗓  Bugün (TR): $todayYMD  |  Bitiş: ${days.last.ymd}');

  // ═══ 0) Logo index ═══════════════════════════════════════════════════
  print('\n── Logo index yükleniyor ──');
  final logoIndex = await _loadLogoIndex();

  // ═══ 1) Temizlik ════════════════════════════════════════════════════
  print('\n── Eski kayıt temizliği ──');
  await _cleanStaleRecords(sbUrl, sbKey);

  // ═══ 2) Aktif canlı maçların fixture_id listesi ═══════════════════
  print('\n── Mevcut live durum sorgulanıyor ──');
  final Set<int> liveFixtureIds = {};
  try {
    final rows = await sb
        .from('live_matches')
        .select('fixture_id')
        .inFilter('status_short', ['1H', '2H', 'HT', 'ET', 'BT', 'P', 'LIVE']);
    for (final row in rows) {
      final fid = row['fixture_id'] as int?;
      if (fid != null) liveFixtureIds.add(fid);
    }
    print('  ⚽ Aktif canlı maç: ${liveFixtureIds.length}');
  } catch (e) { print('  ⚠️  Canlı durum sorgulanamadı: $e'); }

  // ═══ 3) Mackolik verilerini çek ve işle ══════════════════════════
  print('\n── Mackolik verileri çekiliyor (${totalDays} gün) ──');

  final List<Map<String, dynamic>> liveUpserts   = [];
  final List<Map<String, dynamic>> futureUpserts = [];

  for (final day in days) {
    print('\n  📆 ${day.ddmmyyyy}');
    await Future.delayed(const Duration(milliseconds: 300)); // nazik davran

    final matches = await _fetchMackolikDay(day.ddmmyyyy);

    for (final m in matches) {
      final id     = (m[0] as num).toInt();
      final homeId = (m[1] as num?)?.toInt();
      final awayId = (m[3] as num?)?.toInt();
      final htn    = (m[2] as String?) ?? '';
      final atn    = (m[4] as String?) ?? '';
      final statusTx = (m[6] as String?) ?? '';
      final scoreTx  = (m[7] as String?) ?? '';
      final brdId  = (m[14] as num?)?.toInt();
      final lgArr  = m[36] as List<dynamic>? ?? const [];
      final lgId   = lgArr.length > 2 ? (lgArr[2] as num?)?.toInt() ?? 0 : 0;
      final lgName = lgArr.length > 3 ? lgArr[3] as String? ?? '' : '';
      final cntryTr = lgArr.length > 1 ? lgArr[1] as String? ?? '' : '';

      final country  = _countryFromTr(cntryTr);
      final homeLogo = logoIndex.resolve(htn, country, homeId);
      final awayLogo = logoIndex.resolve(atn, country, awayId);
      final rawData  = _buildRawData(m, homeLogo: homeLogo, awayLogo: awayLogo, country: country);

      final short = _statusShort(statusTx);

      // ── future_matches: tüm günler, tüm maçlar ──
      futureUpserts.add({
        'fixture_id': id,
        'date':       day.ymd,
        'league_id':  lgId,
        'data':       rawData,
        'updated_at': DateTime.now().toIso8601String(),
      });

      // ── live_matches: sadece bugün, sadece NS ve henüz canlı olmayan maçlar ──
      if (day.ymd == todayYMD && short == 'NS' && !liveFixtureIds.contains(id)) {
        int? homeGoals, awayGoals;
        if (scoreTx.contains('-')) {
          final parts = scoreTx.split('-');
          homeGoals = int.tryParse(parts[0].trim());
          awayGoals = int.tryParse(parts.length > 1 ? parts[1].trim() : '');
        }

        liveUpserts.add({
          'fixture_id':   id,
          'home_team':    htn,
          'away_team':    atn,
          'home_team_id': homeId,
          'away_team_id': awayId,
          'home_logo':    homeLogo,
          'away_logo':    awayLogo,
          'home_score':   homeGoals ?? 0,
          'away_score':   awayGoals ?? 0,
          'status_short': 'NS',
          'elapsed_time': null,
          'league_id':    lgId,
          'league_name':  lgName,
          'league_logo':  '',
          'betradar_id':  brdId,
          'score_source': 'mackolik',
          'raw_data':     rawData,
          'updated_at':   DateTime.now().toIso8601String(),
        });
      }
    }
  }

  // ═══ 4) Batch upsert öncesi deduplicate ═══
final Map<int, Map<String, dynamic>> liveMap = {};
for (final r in liveUpserts) {
  liveMap[r['fixture_id'] as int] = r;
}
final Map<int, Map<String, dynamic>> futureMap = {};
for (final r in futureUpserts) {
  futureMap[r['fixture_id'] as int] = r;
}
    
  // ═══ 4) Batch upsert ════════════════════════════════════════════════
  print('\n── Yazılıyor ──');
  print('  live_matches  : ${liveUpserts.length} kayıt');
  print('  future_matches: ${futureUpserts.length} kayıt');

  final liveErr   = await _batchUpsert(sb, 'live_matches',   liveUpserts,   'fixture_id');
  final futureErr = await _batchUpsert(sb, 'future_matches', futureUpserts, 'fixture_id');

  // ═══ 5) Rapor ═══════════════════════════════════════════════════════
  logoIndex.printReport();

  final totalErr = liveErr + futureErr;
  print('\n═══════════════════════════════════════════');
  print('  🗂  Logo index     : ${logoIndex._names.length} takım');
  print('  ✅ Logo eşleşti   : ${logoIndex.matched}');
  print('  ⬜ Logo fallback   : ${logoIndex.fallback}');
  print('  ✅ live_matches   : ${liveUpserts.length - liveErr} yazıldı');
  print('  ✅ future_matches : ${futureUpserts.length - futureErr} yazıldı');
  if (liveFixtureIds.isNotEmpty) print('  ⚽ Canlı korunan  : ${liveFixtureIds.length}');
  if (totalErr > 0) print('  ❌ Hatalı         : $totalErr');
  print('═══════════════════════════════════════════');

  await sb.dispose();
  exit(totalErr > 0 ? 1 : 0);
}
