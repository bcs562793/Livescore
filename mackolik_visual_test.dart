import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

/// Mackolik sayfasından rbid ve takım isimlerini çek
Future<Map<String, dynamic>?> getMackolikMatchInfo(int mackolikId) async {
  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  final response = await http.get(Uri.parse(url), headers: {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml',
    'Accept-Language': 'tr-TR,tr;q=0.9',
    'Referer': 'https://arsiv.mackolik.com/',
  }).timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) return null;
  final body = response.body;

  final matchIdMatch = RegExp(r'var matchId\s*=\s*(\d+)').firstMatch(body);
  final rbid = matchIdMatch?.group(1);
  final homeMatch = RegExp(r'homeTeam=([^&"\\]+)').firstMatch(body);
  final awayMatch = RegExp(r'awayTeam=([^&"\\]+)').firstMatch(body);

  return {
    'rbid': rbid,
    'homeTeam': Uri.decodeComponent(homeMatch?.group(1) ?? ''),
    'awayTeam': Uri.decodeComponent(awayMatch?.group(1) ?? ''),
    'pageUrl': url,
  };
}

/// Token endpoint — Referer olarak maç sayfasını ver
Future<String?> getVisualToken(String rbid, String pageUrl) async {
  final tokenUrl = 'https://visualisation.performgroup.com/getToken'
      '?rbid=$rbid&customerId=mackolikWeb';

  print('🔑 Token isteği: $tokenUrl');

  final response = await http.get(Uri.parse(tokenUrl), headers: {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'tr-TR,tr;q=0.9',
    'Referer': pageUrl,                        // ← maç sayfasını referer ver
    'Origin': 'https://arsiv.mackolik.com',    // ← origin ekle
    'X-Requested-With': 'XMLHttpRequest',      // ← jQuery $.get gibi davran
  }).timeout(const Duration(seconds: 15));

  print('📡 Status: ${response.statusCode}');
  print('📄 Response: ${response.body.substring(0, response.body.length.clamp(0, 300))}');

  if (response.statusCode != 200) return null;

  final body = response.body.trim();
  // Hata kontrolü: <errors> içeriyorsa başarısız
  if (body.contains('<errors>') || body.isEmpty) {
    print('❌ Token endpoint hata döndü');
    return null;
  }
  return body;
}

void analyzeToken(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) { print('ℹ️ JWT değil: $token'); return; }
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64.normalize(parts[1])))
    ) as Map<String, dynamic>;
    print('📦 Payload: $payload');
    final exp = payload['exp'] as int?;
    if (exp != null) {
      final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      final remaining = expiry.difference(DateTime.now());
      print('⏱ ${remaining.inMinutes} dk kaldı — ${remaining.isNegative ? "❌ DOLMUŞ" : "✅ GEÇERLİ"}');
    }
  } catch (e) { print('⚠️ $e'); }
}

void main() async {
  print('🚀 Mackolik Visual Token Test\n');

  final mackolikIds = [4314542];

  for (final id in mackolikIds) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 Mackolik ID: $id');

    final info = await getMackolikMatchInfo(id);
    if (info == null || info['rbid'] == null) { print('❌ Maç bilgisi yok'); continue; }
    print('📋 rbid=${info['rbid']} | ${info['homeTeam']} vs ${info['awayTeam']}');

    final token = await getVisualToken(info['rbid']!, info['pageUrl']!);
    if (token == null) { print('❌ Token alınamadı'); continue; }

    analyzeToken(token);

    final iframeUrl = 'https://visualisation.performgroup.com/csb/index.html'
        '?token=$token'
        '&homeTeam=${Uri.encodeComponent(info['homeTeam']!)}'
        '&awayTeam=${Uri.encodeComponent(info['awayTeam']!)}'
        '&matchId=${info['rbid']}'
        '&width=600&lang=tr&gacode=UA-241588-3&wbeventid=0'
        '&cssdiff=//arsiv.mackolik.com/matchcast/css_diff.css';

    print('\n🎯 iframe URL:\n$iframeUrl');
  }

  print('\n✅ Test tamamlandı.');
}
