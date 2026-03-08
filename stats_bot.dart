import 'dart:convert';

import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:supabase/supabase.dart';



// ─── SABİTLER ───

final _macHeaders = {

  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',

  'Accept': 'text/html,application/json,*/*',

  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',

};



const _statsNameMap = {

  'Topla Oynama': 'Ball Possession',

  'Toplam Şut': 'Total Shots',

  'İsabetli Şut': 'Shots on Goal',

  'İsabetsiz Şut': 'Shots off Goal',

  'Bloke Edilen Şut': 'Blocked Shots',

  'Başarılı Paslar': 'Passes accurate',

  'Pas Başarı(%)': 'Passes %',

  'Pas Başarı %': 'Passes %',

  'Korner': 'Corner Kicks',

  'Köşe Vuruşu': 'Corner Kicks',

  'Orta': 'Crosses',

  'Faul': 'Fouls',

  'Ofsayt': 'Offsides',

  'Sarı Kart': 'Yellow Cards',

  'Kırmızı Kart': 'Red Cards',

  'Kurtarış': 'Goalkeeper Saves',

  'Tehlikeli Ataklar': 'Dangerous Attacks',

  'Ataklar': 'Attacks',

};



// ─── FUZZY MATCH FONKSİYONLARI ───

String _normalize(String name) {

  return name.toLowerCase()

      .replaceAll('ı', 'i').replaceAll('ğ', 'g').replaceAll('ü', 'u')

      .replaceAll('ş', 's').replaceAll('ö', 'o').replaceAll('ç', 'c')

      .replaceAll('é', 'e').replaceAll('á', 'a').replaceAll('ñ', 'n')

      .replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

}



double _teamSimilarity(String name1, String name2) {

  final n1 = _normalize(name1);

  final n2 = _normalize(name2);

  if (n1 == n2) return 1.0;

  if (n1.contains(n2) || n2.contains(n1)) return 0.9;

  

  final w1 = n1.split(' ').toSet();

  final w2 = n2.split(' ').toSet();

  final inter = w1.intersection(w2);

  final union = w1.union(w2);

  final jaccard = union.isEmpty ? 0.0 : inter.length / union.length;

  

  if (jaccard >= 0.5) return 0.7 + jaccard * 0.2;

  if (n1.length >= 3 && n2.length >= 3 && n1.substring(0, 3) == n2.substring(0, 3)) return 0.6;

  return jaccard * 0.5;

}



// ─── OTOMATİK API-FOOTBALL EŞLEŞTİRME ───

Future<Map<String, dynamic>?> _getApiFootballMatchInfo(int mackolikId, String apiKey) async {

  print('  🔍 [LOG] Mackolik maç sayfası inceleniyor... ID: $mackolikId');



  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';

  print('  🔗 [LOG] İstek atılan URL: $url');



  final res = await http.get(Uri.parse(url), headers: _macHeaders).timeout(const Duration(seconds: 10));

  print('  📥 [LOG] Mackolik HTTP Status: ${res.statusCode}');



  final titleMatch = RegExp(r'<title>([^<(]+?)\s*-\s*([^<(]+?)\s*\((\d{1,2})\.(\d{1,2})\.(\d{4})\)').firstMatch(res.body);



  if (titleMatch == null) {

    print('  ❌ [HATA] Beklenen tarih formatı Regex ile eşleşmedi!');

    return null;

  }



  String macHome = titleMatch.group(1)!.trim();

  String macAway = titleMatch.group(2)!.trim();

  final day = titleMatch.group(3)!.padLeft(2, '0');

  final month = titleMatch.group(4)!.padLeft(2, '0');

  final year = titleMatch.group(5)!;

  final apiDate = '$year-$month-$day';



  print('  📅 [LOG] Parse edilen tarih: $apiDate');

  print('  ⚽ [LOG] Takımlar: $macHome vs $macAway');

  

  print('  📡 [LOG] API-Football üzerinde aranıyor... (Tarih: $apiDate)');

  final apiRes = await http.get(

    Uri.parse('https://v3.football.api-sports.io/fixtures?date=$apiDate'),

    headers: {'x-apisports-key': apiKey}

  ).timeout(const Duration(seconds: 15));

  

  if (apiRes.statusCode != 200) {

    print('  ❌ [HATA] API-Football isteği başarısız! Status: ${apiRes.statusCode}');

    return null;

  }

  

  final apiData = jsonDecode(apiRes.body);

  final fixtures = apiData['response'] as List? ?? [];

  

  Map<String, dynamic>? bestMatch;

  double bestScore = 0;

  

  for (final fixture in fixtures) {

    final teams = fixture['teams'];

    final apiHome = teams['home']['name'];

    final apiAway = teams['away']['name'];

    

    final homeSim = _teamSimilarity(macHome, apiHome);

    final awaySim = _teamSimilarity(macAway, apiAway);

    final combined = (homeSim + awaySim) / 2;

    

    if (combined > bestScore && homeSim >= 0.5 && awaySim >= 0.5) {

      bestScore = combined;

      bestMatch = fixture;

    }

  }

  

  if (bestMatch != null && bestScore >= 0.65) {

    print('  ✅ [BAŞARILI] Eşleşti! Fixture ID: ${bestMatch['fixture']['id']} (${(bestScore * 100).toStringAsFixed(0)}% benzerlik)');

    return bestMatch;

  }

  

  print('  ❌ [HATA] API-Football tarafında uygun eşleşme bulunamadı.');

  return null;

}



// ─── 1. MACKOLİK STATS HTML FETCH ───

Future<String> _macFetchStats(int mackolikId) async {

  final url = 'https://arsiv.mackolik.com/AjaxHandlers/MatchHandler.aspx?command=optaStats&id=$mackolikId';

  try {

    final res = await http.get(Uri.parse(url), headers: {

      ..._macHeaders,

      'Referer': 'https://arsiv.mackolik.com/Mac/$mackolikId/',

    }).timeout(const Duration(seconds: 10));

    return res.statusCode == 200 ? res.body : '';

  } catch (e) {

    print('  ⚠️ Mackolik stats hatası ($mackolikId): $e');

    return '';

  }

}



// ─── 2. TRANSFORM FONKSİYONU (FIREBASE FORMATI) ───

// Firebase formatına dönüştür: [{type: '...', homeVal: ..., awayVal: ...}]

List<Map<String, dynamic>>? _macTransformStatistics(String text, Map<String, dynamic> teams) {

  if (text.trim().length < 20) return null;

  if (text.trim().startsWith('{') || text.trim().startsWith('[')) return null;



  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();



  if (lines.isEmpty) return null;



  final stats = <Map<String, dynamic>>[];

  int startIndex = lines[0].contains('İstatistikler') ? 1 : 0;



  for (int i = startIndex; i + 2 < lines.length; i += 3) {

    final awayValue = lines[i];

    final title = lines[i + 1];

    final homeValue = lines[i + 2];



    if (title.isEmpty) continue;



    final titleEN = _statsNameMap[title] ?? _statsNameMap[title.replaceAll('(%)', '').trim()] ?? title;



    dynamic fmtVal(String raw) {

      raw = raw.trim();

      if (raw.startsWith('%')) return raw;

      if (raw.contains('/')) return raw;

      final n = int.tryParse(raw);

      return n ?? raw;

    }

    // Firebase formatı: homeVal ve awayVal ayrı alanlarda

    stats.add(<String, dynamic>{

      'type': titleEN,

      'homeVal': fmtVal(homeValue),

      'awayVal': fmtVal(awayValue),

    });

  }



  if (stats.isEmpty) {

    print('  ⚠️ [UYARI] Parse edilen istatistik bulunamadı, alternatif yöntem deneniyor...');



    final altLines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.contains('İstatistikler')).toList();



    for (int i = 0; i + 2 < altLines.length; i++) {

      final line1 = altLines[i];

      final line2 = altLines[i + 1];

      final line3 = altLines[i + 2];



      String? title;

      String? homeVal;

      String? awayVal;



      if (!_isNumeric(line1) && !line1.startsWith('%') && !line1.contains('/')) {

        title = line1;

        homeVal = line2;

        awayVal = line3;

      } else if (!_isNumeric(line2) && !line2.startsWith('%') && !line2.contains('/')) {

        title = line2;

        homeVal = line1;

        awayVal = line3;

      } else {

        continue;

      }



      if (title == null || homeVal == null || awayVal == null) continue;



      final titleEN = _statsNameMap[title] ?? _statsNameMap[title.replaceAll('(%)', '').trim()] ?? title;



      dynamic fmtVal(String raw) {

        raw = raw.trim();

        if (raw.startsWith('%')) return raw;

        if (raw.contains('/')) return raw;

        final n = int.tryParse(raw);

        return n ?? raw;

      }



      if (!stats.any((s) => s['type'] == titleEN)) {

        stats.add(<String, dynamic>{

          'type': titleEN,

          'homeVal': fmtVal(homeVal),

          'awayVal': fmtVal(awayVal),

        });

      }

    }

  }



  if (stats.isEmpty) return null;



  print('  📊 [LOG] ${stats.length} istatistik başlığı işlendi.');



  return stats;

}



bool _isNumeric(String str) {

  return int.tryParse(str.trim()) != null;

}



// ─── ANA ÇALIŞTIRICI ───

void main() async {

  print('🚀 Otomatik İstatistik Botu Başlatılıyor...\n');



  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';

  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';

  final apiKey = Platform.environment['API_FOOTBALL_KEY'] ?? '';



  if (sbUrl.isEmpty || sbKey.isEmpty || apiKey.isEmpty) {

    print('❌ [HATA] Ortam değişkenleri eksik!');

    print('Gerekenler: SUPABASE_URL, SUPABASE_KEY, API_FOOTBALL_KEY');

    exit(1);

  }



  final sb = SupabaseClient(sbUrl, sbKey);



  final List<int> mackolikIds = [

    4418306,

  ];



  int basarili = 0;

  int hatali = 0;



  print('📋 Toplam ${mackolikIds.length} maçın istatistikleri işlenecek.\n');



  for (final mackolikId in mackolikIds) {

    print('----------------------------------------------------');

    print('⚙️ İşleniyor: Mackolik ID $mackolikId');

    

    final apiMatch = await _getApiFootballMatchInfo(mackolikId, apiKey);

    

    if (apiMatch == null) {

      hatali++;

      continue;

    }



    final fixtureId = apiMatch['fixture']['id'];

    final teams = apiMatch['teams'];



    print('  📊 Mackolik istatistikleri çekiliyor...');

    final statsHtml = await _macFetchStats(mackolikId);



    if (statsHtml.isEmpty || statsHtml.trim().length < 20) {

      print('  ❌ [HATA] İstatistik HTML boş veya geçersiz.');

      hatali++;

      continue;

    }



    final statsData = _macTransformStatistics(statsHtml, teams);



    if (statsData != null) {

      // ============================================================

      // DEBUG: Supabase'e yazılacak JSON'u yazdır

      // ============================================================

      final supabasePayload = {

        'fixture_id': fixtureId,

        'data': statsData,

        'updated_at': DateTime.now().toUtc().toIso8601String(),

      };



      final encoder = JsonEncoder.withIndent('  ');

      print('\n');

      print('═══════════════════════════════════════════════════════════');

      print('🔍 [DEBUG] SUPABASE\'E YAZILACAK JSON VERİSİ (FIREBASE FORMATI)');

      print('═══════════════════════════════════════════════════════════');

      print(encoder.convert(supabasePayload));

      print('═══════════════════════════════════════════════════════════');

      print('\n');



      // 4. Supabase'e Yaz

      try {

        await sb.from('match_statistics').upsert(supabasePayload, onConflict: 'fixture_id');

        

        print('  🎉 [BAŞARILI] Veri Supabase tablosuna yazıldı.');

        basarili++;

      } catch (e) {

        print('  ❌ [HATA] Supabase Yazma Hatası: $e');

        hatali++;

      }

    } else {

      print('  ❌ [HATA] İstatistikler parse edilemedi.');

      hatali++;

    }



    await Future.delayed(const Duration(seconds: 2));

  }



  print('\n🏁 İŞLEM TAMAMLANDI!');

  print('✅ Başarılı: $basarili');

  print('❌ Hatalı: $hatali');

  exit(0);

}
