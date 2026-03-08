import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
};

class VisualData {
  final String iframeUrl;
  final String token;
  final DateTime expiry;

  VisualData({required this.iframeUrl, required this.token, required this.expiry});

  bool get isValid => DateTime.now().isBefore(expiry.subtract(const Duration(minutes: 5)));
}

Future<VisualData?> getVisualData(int mackolikId) async {
  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  print('🔗 Fetching: $url');

  try {
    final response = await http.get(Uri.parse(url), headers: {
      ..._headers,
      'Referer': 'https://arsiv.mackolik.com/',
    }).timeout(const Duration(seconds: 15));

    print('📡 Status: ${response.statusCode}');
    if (response.statusCode != 200) return null;

    final document = parse(response.body);
    final iframes = document.querySelectorAll('iframe');

    for (final iframe in iframes) {
      var src = iframe.attributes['src'] ?? '';
      if (!src.contains('performgroup') && !src.contains('visualisation')) continue;

      // // ile başlıyorsa https: ekle
      if (src.startsWith('//')) src = 'https:$src';

      // & işaretini düzelt
      src = src.replaceAll('&amp;', '&');

      print('✅ Visual iframe bulundu');

      final uri = Uri.parse(src);
      final token = uri.queryParameters['token'];
      if (token == null) {
        print('⚠️ Token yok');
        return null;
      }

      // JWT decode
      final parts = token.split('.');
      if (parts.length != 3) {
        print('⚠️ Geçersiz JWT formatı');
        return null;
      }

      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64.normalize(parts[1])))
      ) as Map<String, dynamic>;

      print('📦 Payload: $payload');

      final exp = payload['exp'] as int?;
      if (exp == null) {
        print('⚠️ exp alanı yok');
        return null;
      }

      final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      final remaining = expiry.difference(DateTime.now());

      print('⏱ Token süresi: $expiry (${remaining.inMinutes} dakika kaldı)');
      print(remaining.isNegative ? '❌ Token SÜRESI DOLMUŞ' : '✅ Token GEÇERLİ');
      print('🔗 Full URL: $src');

      return VisualData(iframeUrl: src, token: token, expiry: expiry);
    }

    print('❌ performgroup iframe bulunamadı');
    return null;
  } catch (e) {
    print('❌ Hata: $e');
    return null;
  }
}

void main() async {
  print('🚀 Mackolik Visual Token Test\n');

  // Canlı maç ID'leri buraya — worker loglarından al
  final testMatches = [
    // {'id': CANLI_MACKOLIK_ID, 'name': 'Maç Adı'},
    {'id': 4675932, 'name': 'FC Orenburg vs Zenit (canlı test)'},
  ];

  for (final match in testMatches) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 ${match['name']}');
    final data = await getVisualData(match['id'] as int);
    if (data != null) {
      print('🎯 BAŞARILI — Token ${data.isValid ? "geçerli" : "geçersiz"}');
    } else {
      print('🎯 BAŞARISIZ');
    }
    print('');
  }

  print('✅ Test tamamlandı.');
}
