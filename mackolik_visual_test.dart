import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

/// Cookie-aware HTTP client
class CookieClient {
  final Map<String, String> _cookies = {};
  final _client = http.Client();

  Future<http.Response> get(String url, {Map<String, String>? headers}) async {
    final cookieHeader = _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final response = await _client.get(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
      'Accept-Encoding': 'gzip, deflate, br',
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      ...?headers,
    });

    // Set-Cookie header'larını parse et
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      for (final cookie in setCookie.split(',')) {
        final parts = cookie.trim().split(';')[0].split('=');
        if (parts.length >= 2) {
          _cookies[parts[0].trim()] = parts.sublist(1).join('=').trim();
        }
      }
      print('🍪 Cookie alındı: ${_cookies.keys.toList()}');
    }

    return response;
  }

  void close() => _client.close();
}

Future<void> testVisualToken(int mackolikId) async {
  final client = CookieClient();

  try {
    final pageUrl = 'https://arsiv.mackolik.com/Mac/$mackolikId/';

    // 1. Önce ana sayfayı ziyaret et (session cookie için)
    print('🌐 Ana sayfa ziyareti...');
    await client.get('https://arsiv.mackolik.com/', headers: {
      'Referer': 'https://www.google.com/',
    });

    // 2. Maç sayfasını yükle
    print('🔗 Maç sayfası: $pageUrl');
    final pageResponse = await client.get(pageUrl, headers: {
      'Referer': 'https://arsiv.mackolik.com/',
    });

    print('📡 Sayfa: ${pageResponse.statusCode}');
    if (pageResponse.statusCode != 200) return;

    final body = pageResponse.body;

    // rbid ve takım isimlerini parse et
    final matchIdMatch = RegExp(r'var matchId\s*=\s*(\d+)').firstMatch(body);
    final rbid = matchIdMatch?.group(1);
    final homeMatch = RegExp(r'homeTeam=([^&"\\]+)').firstMatch(body);
    final awayMatch = RegExp(r'awayTeam=([^&"\\]+)').firstMatch(body);

    if (rbid == null) { print('❌ rbid bulunamadı'); return; }
    print('📋 rbid=$rbid | ${homeMatch?.group(1)} vs ${awayMatch?.group(1)}');

    // 3. Token endpoint — artık session cookie var
    final tokenUrl = 'https://visualisation.performgroup.com/getToken?rbid=$rbid&customerId=mackolikWeb';
    print('\n🔑 Token isteği: $tokenUrl');

    final tokenResponse = await client.get(tokenUrl, headers: {
      'Referer': pageUrl,
      'Origin': 'https://arsiv.mackolik.com',
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'text/plain, */*; q=0.01',
    });

    print('📡 Token status: ${tokenResponse.statusCode}');
    print('📄 Token body: ${tokenResponse.body.substring(0, tokenResponse.body.length.clamp(0, 400))}');

    final token = tokenResponse.body.trim();
    if (token.contains('<errors>') || token.isEmpty) {
      print('❌ Geçerli token alınamadı');
      return;
    }

    // JWT decode
    final parts = token.split('.');
    if (parts.length == 3) {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64.normalize(parts[1])))
      ) as Map<String, dynamic>;
      print('\n📦 Token payload: $payload');
      final exp = payload['exp'] as int?;
      if (exp != null) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        print('⏱ ${expiry.difference(DateTime.now()).inMinutes} dk geçerli');
      }
    }

    final iframeUrl = 'https://visualisation.performgroup.com/csb/index.html'
        '?token=$token'
        '&homeTeam=${homeMatch?.group(1) ?? ''}'
        '&awayTeam=${awayMatch?.group(1) ?? ''}'
        '&matchId=$rbid&width=600&lang=tr'
        '&gacode=UA-241588-3&wbeventid=0'
        '&cssdiff=//arsiv.mackolik.com/matchcast/css_diff.css';

    print('\n🎯 iframe URL:\n$iframeUrl');

  } finally {
    client.close();
  }
}

void main() async {
  print('🚀 Mackolik Visual Token (Cookie-aware) Test\n');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  await testVisualToken(4314542);
  print('\n✅ Test tamamlandı.');
}
