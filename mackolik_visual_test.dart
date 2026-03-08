import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
  'Referer': 'https://arsiv.mackolik.com/',
};

Future<String?> getVisualUrl(int mackolikId) async {
  final url = 'https://arsiv.mackolik.com/Mac/$mackolikId/';
  print('🔗 Fetching: $url');

  try {
    final response = await http.get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 15));

    print('📡 Status: ${response.statusCode}');

    if (response.statusCode != 200) {
      print('❌ HTTP ${response.statusCode}');
      print('📄 Response preview:\n${response.body.substring(0, response.body.length.clamp(0, 300))}');
      return null;
    }

    final document = parse(response.body);

    // Tüm iframe'leri listele
    final iframes = document.querySelectorAll('iframe');
    print('🖼 Bulunan iframe sayısı: ${iframes.length}');
    for (final iframe in iframes) {
      print('  iframe src: ${iframe.attributes['src']}');
    }

    // Visual iframe'i bul
    String? visualSrc;
    for (final iframe in iframes) {
      final src = iframe.attributes['src'] ?? '';
      if (src.contains('visual') || src.contains('animat') || src.contains('live') || src.contains('opta')) {
        visualSrc = src;
        break;
      }
    }
    visualSrc ??= iframes.isNotEmpty ? iframes.first.attributes['src'] : null;

    if (visualSrc == null) {
      print('❌ Hiç iframe bulunamadı');
      // Script taglerini tara
      final scripts = document.querySelectorAll('script');
      for (final s in scripts) {
        final text = s.text;
        if (text.contains('visual') || text.contains('opta') || text.contains('animat')) {
          print('📜 Script bulundu:\n${text.substring(0, text.length.clamp(0, 400))}');
        }
      }
      // data- attribute'larını tara
      final divs = document.querySelectorAll('[data-src],[data-url],[data-visual]');
      for (final d in divs) {
        print('📦 data attr: ${d.attributes}');
      }
      return null;
    }

    print('✅ Visual URL: $visualSrc');
    return visualSrc;
  } catch (e) {
    print('❌ Hata: $e');
    return null;
  }
}

void main() async {
  print('🚀 Mackolik Visual Test Başlıyor...\n');

  // Gamba Osaka vs V-varen Nagasaki
  final testMatches = [
    {'id': 4437669, 'name': 'Gamba Osaka vs V-varen Nagasaki'},
  ];

  for (final match in testMatches) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 Maç: ${match['name']}');
    final url = await getVisualUrl(match['id'] as int);
    print('🎯 SONUÇ: ${url ?? 'URL alınamadı'}');
    print('');
  }

  print('✅ Test tamamlandı.');
}
