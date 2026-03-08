import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
};

Future<String?> getVisualUrl(int mackolikId) async {
  // Canlı maç için www.mackolik.com dene
  final urls = [
    'https://www.mackolik.com/mac/$mackolikId/',
    'https://arsiv.mackolik.com/Mac/$mackolikId/',
  ];

  for (final url in urls) {
    print('🔗 Fetching: $url');
    try {
      final response = await http.get(Uri.parse(url), headers: {
        ..._headers,
        'Referer': url.contains('arsiv') ? 'https://arsiv.mackolik.com/' : 'https://www.mackolik.com/',
      }).timeout(const Duration(seconds: 15));

      print('📡 Status: ${response.statusCode}');
      if (response.statusCode != 200) continue;

      final document = parse(response.body);
      final iframes = document.querySelectorAll('iframe');
      print('🖼 iframe sayısı: ${iframes.length}');

      for (final iframe in iframes) {
        final src = iframe.attributes['src'] ?? '';
        print('  → $src');
        if (src.contains('performgroup') || src.contains('visualisation') || src.contains('opta')) {
          print('✅ Visual iframe: $src');
          _analyzeToken(src);
          return src;
        }
      }

      // Script içinde ara
      final scripts = document.querySelectorAll('script');
      for (final s in scripts) {
        final text = s.text;
        if (text.contains('performgroup') || text.contains('visualisation')) {
          final match = RegExp(r'https://[^\s"\']+performgroup[^\s"\']+').firstMatch(text);
          if (match != null) {
            print('✅ Script\'te bulundu: ${match.group(0)}');
            return match.group(0);
          }
        }
      }

      print('⚠️ Visual iframe bulunamadı bu URL\'de\n');
    } catch (e) {
      print('❌ Hata: $e\n');
    }
  }
  return null;
}

void _analyzeToken(String iframeSrc) {
  try {
    final uri = Uri.parse(iframeSrc);
    final token = uri.queryParameters['token'];
    if (token == null) {
      print('ℹ️ Token parametresi yok');
      return;
    }
    final parts = token.split('.');
    if (parts.length == 3) {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64.normalize(parts[1]))));
      print('📦 Token payload: $payload');
      final exp = payload['exp'] as int?;
      if (exp != null) {
        final expDate = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        final remaining = expDate.difference(DateTime.now());
        print('⏱ Token kalan: ${remaining.inMinutes} dakika');
      }
    }
  } catch (e) {
    print('⚠️ Token analiz hatası: $e');
  }
}

void main() async {
  print('🚀 Mackolik Visual Test\n');

  // CANLI BİR MAÇ ID\'Sİ GEREKİYOR — worker loglarından al
  // Örnek: bugün canlı olan bir maçın mackolik ID'si
  final testMatches = [
    {'id': 4314542, 'name': 'Gamba Osaka vs V-varen Nagasaki (arşiv)'},
    // Buraya canlı maç ID'si ekle:
    // {'id': CANLI_MAC_ID, 'name': 'Canlı Maç'},
  ];

  for (final match in testMatches) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 ${match['name']}');
    final url = await getVisualUrl(match['id'] as int);
    print('🎯 SONUÇ: ${url ?? 'URL alınamadı'}\n');
  }

  print('✅ Test tamamlandı.');
}
