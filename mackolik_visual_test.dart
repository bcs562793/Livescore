import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

const testFixtureId = 1394657;
const testMackolikId = 4308537;

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
    await client.get('https://arsiv.mackolik.com/',
        referer: 'https://www.google.com/');

    final pageUrl = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
    final page = await client.get(pageUrl, referer: 'https://arsiv.mackolik.com/');
    if (page.statusCode != 200) { print('❌ Sayfa ${page.statusCode}'); return null; }

    final body = page.body;
    final rbid = RegExp(r'getMatchCast\s*\(\s*(\d+)').firstMatch(body)?.group(1)
               ?? RegExp(r'rbid=(\d+)').firstMatch(body)?.group(1);
    if (rbid == null) { print('❌ rbid bulunamadı'); return null; }
    print('📋 rbid: $rbid');

    final tokenResp = await client.get(
      'https://visualisation.performgroup.com/getToken?rbid=$rbid&customerId=mackolikWeb',
      referer: pageUrl,
      extra: {
        'Origin': 'https://arsiv.mackolik.com',
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'text/plain, */*; q=0.01',
      },
    );

    final token = tokenResp.body.trim();
    print('📡 Token status: ${tokenResp.statusCode} | length: ${token.length}');
    if (token.contains('<errors>') || token.length < 20) { print('❌ $token'); return null; }

    final parts = token.split('.');
    if (parts.length == 3) {
      try {
        final payload = jsonDecode(utf8.decode(base64Url.decode(base64.normalize(parts[1])))) as Map;
        final exp = payload['exp'] as int?;
        if (exp != null) {
          final mins = DateTime.fromMillisecondsSinceEpoch(exp * 1000).difference(DateTime.now()).inMinutes;
          print('⏱ Token: $mins dk geçerli');
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

  // GitHub Actions secrets'tan oku
  final supabaseUrl = Platform.environment['SUPABASE_URL'];
  final supabaseKey = Platform.environment['SUPABASE_KEY']
                   ?? Platform.environment['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null || supabaseKey == null) {
    print('❌ SUPABASE_URL veya SUPABASE_SERVICE_KEY env değişkeni eksik');
    exit(1);
  }

  final visualUrl = await fetchVisualUrl(testMackolikId);
  if (visualUrl == null) { print('❌ URL alınamadı'); exit(1); }
  print('🎯 URL alındı\n');

  print('💾 Supabase\'e yazılıyor...');
  final supabase = SupabaseClient(supabaseUrl, supabaseKey);

  try {
    final result = await supabase
        .from('live_matches')
        .update({'visual_url': visualUrl})
        .eq('fixture_id', testFixtureId)
        .select('fixture_id, visual_url');

    print('✅ Supabase: $result');
  } catch (e) {
    print('❌ Supabase hatası: $e');
  }

  print('\n✅ Test tamamlandı.');
}
