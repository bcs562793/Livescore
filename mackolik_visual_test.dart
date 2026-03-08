import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

// ─── Supabase config ───────────────────────────────────────────────
const supabaseUrl = 'YOUR_SUPABASE_URL';
const supabaseKey = 'YOUR_SUPABASE_ANON_KEY';
const testFixtureId = 1400190; // FC Orenburg vs Zenit — API-Football fixture ID
const testMackolikId = 4314542; // Mackolik ID
// ───────────────────────────────────────────────────────────────────

class _CookieClient {
  final Map<String, String> _cookies = {};
  final _client = http.Client();

  Future<http.Response> get(String url,
      {String? referer, Map<String, String>? extra}) async {
    final cookieHeader =
        _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final response = await _client.get(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept-Language': 'tr-TR,tr;q=0.9',
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      if (referer != null) 'Referer': referer,
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

Future<String?> fetchVisualUrl(int mackolikId) async {
  final client = _CookieClient();
  try {
    // 1. Session başlat
    await client.get('https://arsiv.mackolik.com/',
        referer: 'https://www.google.com/');

    // 2. Maç sayfası
    final pageUrl = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
    final page = await client.get(pageUrl,
        referer: 'https://arsiv.mackolik.com/');
    if (page.statusCode != 200) {
      print('❌ Sayfa ${page.statusCode}');
      return null;
    }

    // 3. rbid
    final body = page.body;
    final call = RegExp(r'getMatchCast\s*\(\s*(\d+)').firstMatch(body);
    final uri  = RegExp(r'rbid=(\d+)').firstMatch(body);
    final rbid = call?.group(1) ?? uri?.group(1);
    if (rbid == null) { print('❌ rbid bulunamadı'); return null; }
    print('📋 rbid: $rbid');

    // 4. Token
    final tokenUrl = 'https://visualisation.performgroup.com/getToken'
        '?rbid=$rbid&customerId=mackolikWeb';
    final tokenResp = await client.get(tokenUrl,
        referer: pageUrl,
        extra: {
          'Origin': 'https://arsiv.mackolik.com',
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'text/plain, */*; q=0.01',
        });

    final token = tokenResp.body.trim();
    print('📡 Token status: ${tokenResp.statusCode} | length: ${token.length}');

    if (token.contains('<errors>') || token.length < 20) {
      print('❌ Token hatası: $token');
      return null;
    }

    // 5. JWT exp
    DateTime? expiresAt;
    final parts = token.split('.');
    if (parts.length == 3) {
      try {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64.normalize(parts[1])))
        ) as Map;
        final exp = payload['exp'] as int?;
        if (exp != null) {
          expiresAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
          print('⏱ Token: ${expiresAt.difference(DateTime.now()).inMinutes} dk geçerli');
        }
      } catch (_) {}
    }

    return 'https://visualisation.performgroup.com/csb/index.html?token=$token';
  } finally {
    client.close();
  }
}

void main() async {
  print('🚀 Mackolik Visual → Supabase Test\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  // 1. Visual URL al
  final visualUrl = await fetchVisualUrl(testMackolikId);
  if (visualUrl == null) { print('❌ URL alınamadı'); return; }
  print('🎯 URL: $visualUrl\n');

  // 2. Supabase'e yaz
  print('💾 Supabase\'e yazılıyor...');
  final supabase = SupabaseClient(supabaseUrl, supabaseKey);

  try {
    final result = await supabase
        .from('live_matches')
        .update({'visual_url': visualUrl})
        .eq('fixture_id', testFixtureId)
        .select('fixture_id, visual_url');

    print('✅ Supabase sonuç: $result');
  } catch (e) {
    print('❌ Supabase hatası: $e');
  }

  print('\n✅ Test tamamlandı.');
}
