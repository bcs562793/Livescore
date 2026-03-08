import 'dart:convert';
import 'package:http/http.dart' as http;

class CookieClient {
  final Map<String, String> _cookies = {};
  final _client = http.Client();

  Future<http.Response> get(String url, {Map<String, String>? extra}) async {
    final cookieHeader = _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final response = await _client.get(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept-Language': 'tr-TR,tr;q=0.9',
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      ...?extra,
    });
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      for (final c in setCookie.split(',')) {
        final kv = c.trim().split(';')[0].split('=');
        if (kv.length >= 2) _cookies[kv[0].trim()] = kv.sublist(1).join('=').trim();
      }
    }
    return response;
  }

  void close() => _client.close();
}

/// Mackolik sayfasından performgroup rbid'yi çek
Future<String?> getRbid(CookieClient client, int mackolikId) async {
  final pageUrl = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  final page = await client.get(pageUrl, extra: {'Referer': 'https://arsiv.mackolik.com/'});
  if (page.statusCode != 200) return null;

  final body = page.body;

  // getMatchCast(rbid, width) çağrısını bul
  final call = RegExp(r'getMatchCast\s*\(\s*(\d+)').firstMatch(body);
  if (call != null) {
    print('✅ getMatchCast rbid: ${call.group(1)}');
    return call.group(1);
  }

  // tokenURI içindeki rbid= parametresini bul
  final uri = RegExp(r'rbid=(\d+)').firstMatch(body);
  if (uri != null) {
    print('✅ tokenURI rbid: ${uri.group(1)}');
    return uri.group(1);
  }

  // Debug — getMatchCast etrafı
  if (body.contains('getMatchCast')) {
    final idx = body.indexOf('getMatchCast');
    print('📄 getMatchCast:\n${body.substring((idx-50).clamp(0, body.length), (idx+300).clamp(0, body.length))}');
  } else {
    print('⚠️ getMatchCast yok — isMatchCastEnabled kontrol:');
    if (body.contains('isMatchCastEnabled')) {
      final idx = body.indexOf('isMatchCastEnabled');
      print(body.substring(idx, (idx+300).clamp(0, body.length)));
    }
  }

  return null;
}

/// Token al ve minimal URL döndür
Future<String?> getVisualUrl(int mackolikId) async {
  final client = CookieClient();
  try {
    await client.get('https://arsiv.mackolik.com/', extra: {'Referer': 'https://www.google.com/'});

    final pageUrl = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
    final rbid = await getRbid(client, mackolikId);
    if (rbid == null) { print('❌ rbid bulunamadı'); return null; }

    final token = await _fetchToken(client, rbid, pageUrl);
    if (token == null) return null;

    // Minimal URL — sadece token yeterli
    return 'https://visualisation.performgroup.com/csb/index.html?token=$token';
  } finally {
    client.close();
  }
}

Future<String?> _fetchToken(CookieClient client, String rbid, String pageUrl) async {
  final tokenUrl = 'https://visualisation.performgroup.com/getToken?rbid=$rbid&customerId=mackolikWeb';
  print('🔑 $tokenUrl');

  final resp = await client.get(tokenUrl, extra: {
    'Referer': pageUrl,
    'Origin': 'https://arsiv.mackolik.com',
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': 'text/plain, */*; q=0.01',
  });

  print('📡 ${resp.statusCode} | ${resp.body.substring(0, resp.body.length.clamp(0, 80))}');

  final token = resp.body.trim();
  if (token.contains('<errors>') || token.length < 20) {
    print('❌ Token hatası: $token');
    return null;
  }

  // JWT exp kontrolü
  final parts = token.split('.');
  if (parts.length == 3) {
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64.normalize(parts[1])))) as Map;
      final exp = payload['exp'] as int?;
      if (exp != null) {
        final mins = DateTime.fromMillisecondsSinceEpoch(exp * 1000).difference(DateTime.now()).inMinutes;
        print('✅ Token geçerli — $mins dk kaldı');
      }
    } catch (_) {}
  }
  return token;
}

void main() async {
  print('🚀 Mackolik Visual URL Test\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  final url = await getVisualUrl(4314542);
  print('\n🎯 ${url ?? "BAŞARISIZ"}');
  print('\n✅ Tamamlandı.');
}
