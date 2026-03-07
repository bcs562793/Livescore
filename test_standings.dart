import 'dart:convert';
import 'package:http/http.dart' as http;

// ─── GEREKLİ SABİTLER ───
final _macHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  'Accept': 'text/html,application/json,*/*',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
};

// ─── 1. MACKOLİK FETCH ───
Future<String> _macFetchStandings(int mackolikId) async {
  final url = 'https://arsiv.mackolik.com/AjaxHandlers/StandingHandler.aspx?command=matchStanding&id=$mackolikId&sv=1';
  try {
    final res = await http.get(Uri.parse(url), headers: {
      ..._macHeaders,
      'Referer': 'https://arsiv.mackolik.com/Mac/$mackolikId/',
    }).timeout(const Duration(seconds: 10));
    return res.statusCode == 200 ? res.body : '';
  } catch (e) {
    print('⚠️ Mackolik standings hatası ($mackolikId): $e');
    return '';
  }
}

// ─── 2. TRANSFORM FONKSİYONU (Ana koda ekleyeceğimiz fonksiyon) ───
List<Map<String, dynamic>>? _macTransformStandings(String html) {
  if (html.trim().length < 50) return null;
  final standings = <Map<String, dynamic>>[];
  
  final rowRe = RegExp(r'<tr[^>]+class="row alt[12]"[^>]*>([\s\S]*?)<\/tr>');
  
  for (final row in rowRe.allMatches(html)) {
    final block = row.group(0)!;
    
    final teamIdM = RegExp(r'data-teamid="(\d+)"').firstMatch(block);
    if (teamIdM == null) continue;
    final teamId = int.parse(teamIdM.group(1)!);
    
    final rankM = RegExp(r'<td[^>]*>\s*<b>(\d+)<\/b>\s*<\/td>').firstMatch(block);
    if (rankM == null) continue;
    final rank = int.parse(rankM.group(1)!);
    
    final nameM = RegExp(r'target="_blank"[^>]*>\s*([^<]+?)\s*<\/a>').firstMatch(block);
    final name = nameM?.group(1)?.trim() ?? '';
    
    final nums = RegExp(r'<td[^>]*align="right"[^>]*>(?:<b>)?(\d+)(?:<\/b>)?<\/td>')
        .allMatches(block).map((m) => int.parse(m.group(1)!)).toList();
        
    if (nums.length < 5) continue;
    
    standings.add({
      'rank': rank,
      'team': {'id': teamId, 'name': name, 'logo': 'https://im.mackolik.com/img/logo/buyuk/$teamId.gif'},
      'points': nums[4], 'goalsDiff': 0, 'group': '', 'form': '', 'status': 'same', 'description': '',
      'all': {'played': nums[0], 'win': nums[1], 'draw': nums[2], 'lose': nums[3], 'goals': {'for': 0, 'against': 0}},
      'home': {'played': 0, 'win': 0, 'draw': 0, 'lose': 0, 'goals': {'for': 0, 'against': 0}},
      'away': {'played': 0, 'win': 0, 'draw': 0, 'lose': 0, 'goals': {'for': 0, 'against': 0}},
      'update': DateTime.now().toIso8601String(),
    });
  }
  return standings.isNotEmpty ? standings : null;
}

// ─── ANA ÇALIŞTIRICI ───
void main() async {
  // TEST İÇİN GEÇERLİ BİR MACKOLİK MAÇ ID'Sİ GİRİNİZ (Puan durumu olan bir ligden)
  // Örneğin 3676100 veya veri çektiğinden emin olduğun güncel bir ID.
  int testMackolikId = 3676100; 
  int testLeagueId = 39; // Premier League örnek
  int testSeason = 2023;

  print('📡 Mackolik verisi çekiliyor (ID: $testMackolikId)...');
  String html = await _macFetchStandings(testMackolikId);

  if (html.isEmpty || html.trim().length < 50) {
    print('❌ HTML boş veya geçersiz. Mackolik ID ($testMackolikId) puan durumu olan bir maça ait olmayabilir.');
    return;
  }

  print('✅ HTML başarıyla çekildi. Parse ediliyor...');
  List<Map<String, dynamic>>? standingsList = _macTransformStandings(html);

  if (standingsList != null) {
    // BURASI_fetchAndSaveStandings İÇİNDEKİ SARMALAMA MANTIĞI
    final formattedData = {
      "get": "standings",
      "parameters": {"league": testLeagueId.toString(), "season": testSeason.toString()},
      "errors": [],
      "results": 1,
      "paging": {"current": 1, "total": 1},
      "response": [
        {
          "league": {
            "id": testLeagueId, "name": "Test League", "country": "Test Country",
            "logo": "https://media.api-sports.io/football/leagues/$testLeagueId.png",
            "flag": "", "season": testSeason,
            "standings": [standingsList] // Dizi içinde dizi formatı
          }
        }
      ]
    };

    print('\n🎯 DÖNÜŞTÜRÜLMÜŞ JSON ÇIKTISI:\n');
    const encoder = JsonEncoder.withIndent('  ');
    print(encoder.convert(formattedData));
  } else {
    print('❌ Puan durumu parse edilemedi.');
  }
}
