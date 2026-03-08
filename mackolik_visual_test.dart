import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  'Referer': 'https://arsiv.mackolik.com/',
};

/// Mackolik sayfasından rbid (matchId) ve takım isimlerini çek
Future<Map<String, dynamic>?> getMackolikMatchInfo(int mackolikId) async {
  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  final response = await http.get(Uri.parse(url), headers: _headers)
      .timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) return null;

  final body = response.body;

  // matchId (rbid) — JS'de: var matchId = 4314542;
  final matchIdMatch = RegExp(r'var matchId\s*=\s*(\d+)').firstMatch(body);
  final rbid = matchIdMatch?.group(1);

  // Takım isimleri
  final homeMatch = RegExp(r'homeTeam=([^&"]+)').firstMatch(body);
  final awayMatch = RegExp(r'awayTeam=([^&"]+)').firstMatch(body);

  return {
    'rbid': rbid,
    'homeTeam': homeMatch?.group(1) ?? '',
    'awayTeam': awayMatch?.group(1) ?? '',
  };
}

/// Token endpoint'ini direkt çağır
Future<String?> getVisualToken(String rbid) async {
  final url = 'https://visualisation.performgroup.com/getToken?rbid=$rbid&customerId=mackolikWeb';
  print('🔑 Token URL: $url');

  final response = await http.get(Uri.parse(url), headers: _headers)
      .timeout(const Duration(seconds: 15));

  print('📡 Token status: ${response.statusCode}');
  print('📄 Token response: ${response.body.substring(0, response.body.length.clamp(0, 300))}');

  if (response.statusCode != 200) return null;
  return response.body.trim();
}

/// Token decode ve süre kontrolü
void analyzeToken(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) {
      print('ℹ️ JWT değil, ham token: $token');
      return;
    }
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64.normalize(parts[1])))
    ) as Map<String, dynamic>;
    print('📦 Payload: $payload');
    final exp = payload['exp'] as int?;
    if (exp != null) {
      final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      final remaining = expiry.difference(DateTime.now());
      print('⏱ Geçerlilik: $expiry (${remaining.inMinutes} dk kaldı)');
      print(remaining.isNegative ? '❌ SÜRESI DOLMUŞ' : '✅ GEÇERLİ');
    }
  } catch (e) {
    print('⚠️ Token parse hatası: $e');
  }
}

String buildIframeUrl(String token, String rbid, String homeTeam, String awayTeam) {
  return 'https://visualisation.performgroup.com/csb/index.html'
      '?token=$token'
      '&homeTeam=$homeTeam'
      '&awayTeam=$awayTeam'
      '&matchId=$rbid'
      '&width=600'
      '&lang=tr'
      '&gacode=UA-241588-3'
      '&wbeventid=0'
      '&cssdiff=//arsiv.mackolik.com/matchcast/css_diff.css';
}

void main() async {
  print('🚀 Mackolik Visual Token Test\n');

  final mackolikIds = [4314542]; // FC Orenburg vs Zenit

  for (final id in mackolikIds) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 Mackolik ID: $id');

    // 1. Maç bilgilerini al
    final info = await getMackolikMatchInfo(id);
    print('📋 Maç info: $info');
    if (info == null || info['rbid'] == null) {
      print('❌ Maç bilgisi alınamadı');
      continue;
    }

    final rbid = info['rbid'] as String;
    final homeTeam = info['homeTeam'] as String;
    final awayTeam = info['awayTeam'] as String;

    // 2. Token endpoint'ini çağır
    final token = await getVisualToken(rbid);
    if (token == null || token.isEmpty) {
      print('❌ Token alınamadı');
      continue;
    }

    // 3. Token analizi
    analyzeToken(token);

    // 4. iframe URL
    final iframeUrl = buildIframeUrl(token, rbid, homeTeam, awayTeam);
    print('\n🎯 iframe URL:\n$iframeUrl');
  }

  print('\n✅ Test tamamlandı.');
}
