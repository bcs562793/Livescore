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

// ─── FUZZY MATCH FONKSİYONLARI (Takım İsimlerini Eşleştirmek İçin) ───
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
  print('  🔍 Mackolik maç sayfası inceleniyor...');
  
  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  final res = await http.get(Uri.parse(url), headers: _macHeaders).timeout(const Duration(seconds: 10));
  
  // HTML <title> etiketinden takımları ve maç tarihini Regex ile ayıkla
  // Örn: <title>Fenerbahçe vs Galatasaray, 19.05.2024 ...
  final titleMatch = RegExp(r'<title>\s*(.*?)\s*(?:vs|\s+-\s+|\d+\s*-\s*\d+)\s*(.*?),\s*(\d{2})\.(\d{2})\.(\d{4})').firstMatch(res.body);
  
  if (titleMatch == null) {
    print('  ❌ Başlık(title) bulunamadı. ID hatalı olabilir.');
    return null;
  }
  
  final macHome = titleMatch.group(1)!.trim();
  final macAway = titleMatch.group(2)!.trim();
  final day = titleMatch.group(3)!;
  final month = titleMatch.group(4)!;
  final year = titleMatch.group(5)!;
  final apiDate = '$year-$month-$day';
  
  print('  📅 Tarih ve Takımlar bulundu: $macHome vs $macAway ($apiDate)');
  print('  📡 API-Football üzerinde aranıyor...');
  
  // API-Football'a o tarihteki maçları sor
  final apiRes = await http.get(
    Uri.parse('https://v3.football.api-sports.io/fixtures?date=$apiDate'),
    headers: {'x-apisports-key': apiKey}
  ).timeout(const Duration(seconds: 15));
  
  if (apiRes.statusCode != 200) {
    print('  ❌ API-Football isteği başarısız: HTTP ${apiRes.statusCode}');
    return null;
  }
  
  final apiData = jsonDecode(apiRes.body);
  final fixtures = apiData['response'] as List? ?? [];
  
  Map<String, dynamic>? bestMatch;
  double bestScore = 0;
  
  // Bulunan tüm maçlar arasında takım isimlerini eşleştir
  for (final fixture in fixtures) {
    final teams = fixture['teams'];
    final apiHome = teams['home']['name'];
    final apiAway = teams['away']['name'];
    
    final homeSim = _teamSimilarity(macHome, apiHome);
    final awaySim = _teamSimilarity(macAway, apiAway);
    final combined = (homeSim + awaySim) / 2;
    
    // Yüzde 65 ve üzeri benzerliği olan en iyi sonucu al
    if (combined > bestScore && homeSim >= 0.5 && awaySim >= 0.5) {
      bestScore = combined;
      bestMatch = fixture;
    }
  }
  
  if (bestMatch != null && bestScore >= 0.65) {
    print('  ✅ API-Football ile eşleşti! Fixture ID: ${bestMatch['fixture']['id']} (${(bestScore * 100).toStringAsFixed(0)}% benzerlik)');
    return bestMatch;
  }
  
  print('  ❌ API-Football tarafında $apiDate tarihinde uygun eşleşme bulunamadı.');
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

// ─── 2. TRANSFORM FONKSİYONU ───
List<Map<String, dynamic>>? _macTransformStatistics(String html, Map<String, dynamic> teams) {
  if (html.trim().length < 20) return null;
  if (html.trim().startsWith('{') || html.trim().startsWith('[')) return null;

  final homeValues = RegExp(r'team-1-statistics-text">\s*([^<]+)\s*<')
      .allMatches(html).map((m) => m.group(1)!.trim()).toList();
  final titles = RegExp(r'statistics-title-text">\s*([^<]+)\s*<')
      .allMatches(html).map((m) => m.group(1)!.trim()).toList();
  final awayValues = RegExp(r'team-2-statistics-text">\s*([^<]+)\s*<')
      .allMatches(html).map((m) => m.group(1)!.trim()).toList();

  final count = [homeValues.length, titles.length, awayValues.length].reduce((a, b) => a < b ? a : b);
  if (count == 0) return null;

  dynamic fmtVal(String raw) {
    raw = raw.trim();
    if (raw.startsWith('%')) return '${raw.substring(1)}%';
    if (raw.contains('/')) return raw;
    final n = int.tryParse(raw);
    return n ?? raw; 
  }

  final homeStats = <Map<String, dynamic>>[];
  final awayStats = <Map<String, dynamic>>[];

  for (int i = 0; i < count; i++) {
    final titleEN = _statsNameMap[titles[i]] ?? titles[i]; 
    homeStats.add(<String, dynamic>{'type': titleEN, 'value': fmtVal(homeValues[i])});
    awayStats.add(<String, dynamic>{'type': titleEN, 'value': fmtVal(awayValues[i])});
  }

  return [
    {
      'team': {'id': teams['home']?['id'], 'name': teams['home']?['name'] ?? '', 'logo': teams['home']?['logo'] ?? ''}, 
      'statistics': homeStats
    },
    {
      'team': {'id': teams['away']?['id'], 'name': teams['away']?['name'] ?? '', 'logo': teams['away']?['logo'] ?? ''}, 
      'statistics': awayStats
    },
  ];
}

// ─── ANA ÇALIŞTIRICI ───
void main() async {
  print('🚀 Otomatik İstatistik Botu Başlatılıyor...\n');

  final sbUrl = Platform.environment['SUPABASE_URL'] ?? '';
  final sbKey = Platform.environment['SUPABASE_KEY'] ?? '';
  final apiKey = Platform.environment['API_FOOTBALL_KEY'] ?? '';

  if (sbUrl.isEmpty || sbKey.isEmpty || apiKey.isEmpty) {
    print('❌ SUPABASE_URL, SUPABASE_KEY veya API_FOOTBALL_KEY eksik!');
    exit(1);
  }

  final sb = SupabaseClient(sbUrl, sbKey);

  // ─── SADECE MAÇKOLİK ID'LERİNİ BURAYA YAZACAKSIN ───
  final List<int> mackolikIds = [
    4305437, // Galatasaray - Fenerbahçe (Örnek)
    // Virgül koyarak istediğin kadar maç ID'si girebilirsin
  ];

  int basarili = 0;
  int hatali = 0;

  print('📋 Toplam ${mackolikIds.length} maçın istatistikleri işlenecek.\n');

  for (final mackolikId in mackolikIds) {
    print('----------------------------------------------------');
    print('⚙️ İşleniyor: Mackolik ID $mackolikId');
    
    // 1. API-Football Eşleşmesini Bul
    final apiMatch = await _getApiFootballMatchInfo(mackolikId, apiKey);
    
    if (apiMatch == null) {
      hatali++;
      continue;
    }

    // Eşleşen API-Football bilgileri
    final fixtureId = apiMatch['fixture']['id'];
    final teams = apiMatch['teams'];

    // 2. Mackolik İstatistiklerini Çek
    print('  📊 Mackolik istatistikleri çekiliyor...');
    final statsHtml = await _macFetchStats(mackolikId);

    if (statsHtml.isEmpty || statsHtml.trim().length < 20) {
      print('  ❌ İstatistik HTML boş veya geçersiz.');
      hatali++;
      continue;
    }

    // 3. Veriyi API-Sports Formatına Çevir
    final statsData = _macTransformStatistics(statsHtml, teams);

    if (statsData != null) {
      // 4. Supabase'e Yaz
      try {
        await sb.from('match_statistics').upsert({
          'fixture_id': fixtureId,
          'data': statsData,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'fixture_id');
        
        print('  🎉 BAŞARILI! Veri Supabase tablosuna yazıldı.');
        basarili++;
      } catch (e) {
        print('  ❌ Supabase Yazma Hatası: $e');
        hatali++;
      }
    } else {
      print('  ❌ İstatistikler parse edilemedi.');
      hatali++;
    }

    // Rate-limit'e takılmamak için her maç arasına bekleme koyuyoruz
    await Future.delayed(const Duration(seconds: 2));
  }

  print('\n🏁 İŞLEM TAMAMLANDI!');
  print('✅ Başarılı: $basarili');
  print('❌ Hatalı: $hatali');
  exit(0);
}
