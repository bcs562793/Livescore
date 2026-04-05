import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

const _teamsJsonUrl =
    'https://raw.githubusercontent.com/bcs562793/H2Hscrape/main/data/teams.json';

// ─── Normalizasyon ────────────────────────────────────────────────
const _nicknames  = <String, String>{'spurs': 'tottenham', 'inter': 'internazionale'};
const _wordTrToEn = <String, String>{
  'munih': 'munich', 'munchen': 'munich', 'marsilya': 'marseille',
  'kopenhag': 'copenhagen', 'bruksel': 'brussels', 'prag': 'prague',
  'lizbon': 'lisbon', 'viyana': 'vienna',
};
const _noise = <String>{
  'fc','sc','cf','ac','if','bk','sk','fk','afc','bfc','cfc','sfc','rfc',
  'cp','cd','sd','ud','rc','rcd','as','ss',
};

String _norm(String name) {
  var s = name.toLowerCase().trim();
  if (_nicknames.containsKey(s)) s = _nicknames[s]!;
  s = s
      .replaceAll('ş','s').replaceAll('ğ','g').replaceAll('ü','u')
      .replaceAll('ö','o').replaceAll('ç','c').replaceAll('ı','i')
      .replaceAll(RegExp(r'[éèê]'),'e').replaceAll(RegExp(r'[áàâãäå]'),'a')
      .replaceAll(RegExp(r'[óòôõø]'),'o').replaceAll(RegExp(r'[úùûů]'),'u')
      .replaceAll(RegExp(r'[íìî]'),'i').replaceAll('ñ','n')
      .replaceAll(RegExp(r'[ćč]'),'c').replaceAll('ž','z').replaceAll('š','s')
      .replaceAll('ý','y').replaceAll('ř','r')
      .replaceAll(RegExp(r"[.\-_/'\\()]"), ' ');
  return s
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !_noise.contains(t))
      .map((t) => _wordTrToEn[t] ?? t)
      .join(' ')
      .trim();
}

// ─── Logo Index ───────────────────────────────────────────────────
class _LogoIndex {
  final Map<String, String> _exact     = {};
  final List<String>        _names     = [];
  final List<String>        _logos     = [];
  final List<String>        _macs      = [];
  final List<String>        _countries = [];

  _LogoIndex(List<dynamic> teams) {
    for (final t in teams) {
      final name    = (t['n'] as String? ?? '').trim();
      final country = (t['c'] as String? ?? '').trim();
      final logo    = (t['l'] as String? ?? '').trim();
      final mac     = (t['m'] as String? ?? '').trim();
      if (name.isEmpty || logo.isEmpty) continue;
      final n = _norm(name);
      _exact['$n|${country.toLowerCase()}'] = logo;
      _exact['$n|']                          = logo;
      _names.add(n); _logos.add(logo); _macs.add(mac);
      _countries.add(country.toLowerCase());
    }
    print('🗂  Logo index: ${_names.length} takım');
  }

  String resolve(String teamName, String country, int? teamId) {
    if (teamName.isEmpty) return _fallback(null, teamId);
    final q = _norm(teamName);
    final c = country.toLowerCase();

    final e1 = _exact['$q|$c']; if (e1 != null && e1.isNotEmpty) return e1;
    final e2 = _exact['$q|'];   if (e2 != null && e2.isNotEmpty) return e2;

    int bestIdx = -1; double bestScore = 0;
    for (int i = 0; i < _names.length; i++) {
      final sc = _score(q, _names[i]);
      if (sc > bestScore) { bestScore = sc; bestIdx = i; }
    }
    if (bestIdx >= 0 && bestScore >= 0.55) {
      double adj = bestScore;
      if (c.isNotEmpty && _countries[bestIdx].isNotEmpty &&
          c != _countries[bestIdx] && bestScore < 0.80) adj -= 0.10;
      if (adj >= 0.50 && _logos[bestIdx].isNotEmpty) return _logos[bestIdx];
    }
    return _fallback(bestIdx >= 0 ? _macs[bestIdx] : null, teamId);
  }

  String _fallback(String? mac, int? id) {
    if (mac != null && mac.isNotEmpty) return mac;
    if (id != null) return 'https://im.mackolik.com/img/logo/buyuk/$id.gif';
    return '';
  }

  double _score(String q, String t) {
    if (q == t) return 1.0;
    final qt = q.split(' '); final tt = t.split(' ');
    if (qt.isEmpty || tt.isEmpty) return 0.0;
    if (qt.length == 1 && tt.length > 1) {
      final ini = tt.map((x) => x[0]).join('');
      if (ini == qt[0] || ini.startsWith(qt[0])) return 0.95;
    }
    double total = 0; int matched = 0;
    for (final a in qt) {
      double best = 0;
      for (final b in tt) {
        double sc = 0;
        if (a == b)                                                       sc = 1.0;
        else if (b.startsWith(a)) sc = a.length == 1 ? 0.85 : 0.85 + a.length / b.length * 0.15;
        else if (a.startsWith(b))                                         sc = 0.80;
        else if (a.length >= 4 && b.length >= 4 && a.substring(0,4) == b.substring(0,4)) sc = 0.70;
        else if ((b.contains(a) || a.contains(b)) && a.length >= 3)      sc = 0.65;
        if (sc > best) best = sc;
      }
      total += best; if (best >= 0.65) matched++;
    }
    return total / qt.length * 0.85 + matched / tt.length * 0.15;
  }
}

// ─── Lig adından ülke ─────────────────────────────────────────────
const Map<String, String> _lgCountryMap = {
  'almanya':'Germany','ispanya':'Spain','italya':'Italy','fransa':'France',
  'hollanda':'Netherlands','portekiz':'Portugal','brezilya':'Brazil',
  'arjantin':'Argentina','turkiye':'Turkey','turk':'Turkey',
  'belcika':'Belgium','isvicre':'Switzerland','avustralya':'Australia',
  'japonya':'Japan','danimarka':'Denmark','norvec':'Norway','isvec':'Sweden',
  'finlandiya':'Finland','polonya':'Poland','hirvatistan':'Croatia',
  'iskocya':'Scotland','ingiltere':'England','galler':'Wales',
  'kolombiya':'Colombia','meksika':'Mexico','misir':'Egypt',
  'fas':'Morocco','abd':'USA','ukrayna':'Ukraine','rusya':'Russia',
  'guney_kore':'South Korea','suudi_arabistan':'Saudi Arabia',
};
String _nc(String s) => s.toLowerCase()
    .replaceAll('ş','s').replaceAll('ğ','g').replaceAll('ü','u')
    .replaceAll('ö','o').replaceAll('ç','c').replaceAll('ı','i');

String _extractCountry(String lgn) {
  if (lgn.isEmpty) return '';
  final words = lgn.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    final k2 = '${_nc(words[0])}_${_nc(words[1])}';
    if (_lgCountryMap.containsKey(k2)) return _lgCountryMap[k2]!;
  }
  return _lgCountryMap[_nc(words[0])] ?? '';
}

// ─── main ─────────────────────────────────────────────────────────
Future<void> main() async {
  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';
  if (sbUrl.isEmpty || sbKey.isEmpty) { print('❌ SUPABASE env eksik'); exit(1); }

  final sb = SupabaseClient(sbUrl, sbKey);
  print('🖼  Live Logo Sync — ${DateTime.now().toIso8601String()}');

  // 1) teams.json → logo index
  late _LogoIndex idx;
  try {
    final res = await http
        .get(Uri.parse(_teamsJsonUrl))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      print('❌ teams.json ${res.statusCode}'); await sb.dispose(); exit(1);
    }
    idx = _LogoIndex(jsonDecode(res.body) as List);
  } catch (e) { print('❌ teams.json: $e'); await sb.dispose(); exit(1); }

  // 2) home_logo veya away_logo boş/null olan kayıtları çek
  print('\n── Logo eksik kayıtlar sorgulanıyor ──');
  List rows;
  try {
    rows = await sb
        .from('live_matches')
        .select('fixture_id, home_team, away_team, home_team_id, away_team_id, '
                'league_name, home_logo, away_logo, raw_data')
        .or('home_logo.is.null,home_logo.eq.,away_logo.is.null,away_logo.eq.');
  } catch (e) { print('❌ Sorgu hatası: $e'); await sb.dispose(); exit(1); }

  if (rows.isEmpty) {
    print('✅ Tüm kayıtlarda logo mevcut, işlem yok.');
    await sb.dispose(); exit(0);
  }
  print('  📦 ${rows.length} kayıt logo güncellemesi bekliyor');

  // 3) Her kayıt için logo çöz ve güncelle
  int updated = 0, skipped = 0, errors = 0;

  for (final row in rows) {
    final fid  = row['fixture_id']   as int;
    final htn  = row['home_team']    as String? ?? '';
    final atn  = row['away_team']    as String? ?? '';
    final htpi = row['home_team_id'] as int?;
    final atpi = row['away_team_id'] as int?;
    final lgn  = row['league_name']  as String? ?? '';

    // Doluysa koru, boşsa çöz
    final curH = row['home_logo'] as String? ?? '';
    final curA = row['away_logo'] as String? ?? '';
    final country  = _extractCountry(lgn);
    final homeLogo = curH.isNotEmpty ? curH : idx.resolve(htn, country, htpi);
    final awayLogo = curA.isNotEmpty ? curA : idx.resolve(atn, country, atpi);

    if (homeLogo.isEmpty && awayLogo.isEmpty) { skipped++; continue; }

    // raw_data içindeki logo alanlarını da güncelle
    Map<String, dynamic>? updatedRaw;
    try {
      final rawStr = row['raw_data'] as String? ?? '{}';
      if (rawStr.length > 2) {
        updatedRaw = Map<String, dynamic>.from(jsonDecode(rawStr) as Map);
        if (homeLogo.isNotEmpty) (updatedRaw['teams'] as Map)['home']['logo'] = homeLogo;
        if (awayLogo.isNotEmpty) (updatedRaw['teams'] as Map)['away']['logo'] = awayLogo;
      }
    } catch (_) {}

    try {
      await sb.from('live_matches').update({
        if (homeLogo.isNotEmpty) 'home_logo': homeLogo,
        if (awayLogo.isNotEmpty) 'away_logo': awayLogo,
        if (updatedRaw != null)  'raw_data':  jsonEncode(updatedRaw),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('fixture_id', fid);

      print('  🖼  $fid | $htn - $atn'
            '  H:${homeLogo.isNotEmpty ? "✓" : "✗"}'
            '  A:${awayLogo.isNotEmpty ? "✓" : "✗"}');
      updated++;
    } catch (e) {
      print('  ⚠️  $fid güncelleme hatası: $e');
      errors++;
    }
  }

  print('\n═══════════════════════════════');
  print('  🖼  Güncellenen : $updated');
  print('  ⏭  Atlanan     : $skipped (logo çözülemedi)');
  if (errors > 0) print('  ❌ Hatalı      : $errors');
  print('═══════════════════════════════');

  await sb.dispose();
  exit(errors > 0 ? 1 : 0);
}
