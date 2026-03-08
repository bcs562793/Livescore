import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
};

Future<void> scanPage(int mackolikId) async {
  final urls = [
    'https://www.mackolik.com/mac/$mackolikId/',
    'https://arsiv.mackolik.com/Mac/$mackolikId/',
  ];

  for (final url in urls) {
    print('\n🔗 $url');
    try {
      final response = await http.get(Uri.parse(url), headers: {
        ..._headers,
        'Referer': url.contains('arsiv')
            ? 'https://arsiv.mackolik.com/'
            : 'https://www.mackolik.com/',
      }).timeout(const Duration(seconds: 15));

      print('📡 ${response.statusCode}');
      if (response.statusCode != 200) continue;

      final body = response.body;

      // 1. Ham HTML'de performgroup ara
      if (body.contains('performgroup')) {
        print('✅ HTML içinde "performgroup" bulundu!');
        // Etrafındaki 500 karakteri göster
        final idx = body.indexOf('performgroup');
        final start = (idx - 200).clamp(0, body.length);
        final end = (idx + 300).clamp(0, body.length);
        print('📄 Bağlam:\n${body.substring(start, end)}');
      } else {
        print('❌ HTML içinde "performgroup" yok');
      }

      // 2. Token ara
      if (body.contains('token=')) {
        print('\n✅ "token=" bulundu!');
        final idx = body.indexOf('token=');
        final end = (idx + 200).clamp(0, body.length);
        print('📄 Token bağlamı: ${body.substring(idx, end)}');
      }

      // 3. csb ara
      if (body.contains('/csb/')) {
        print('\n✅ "/csb/" bulundu!');
        final idx = body.indexOf('/csb/');
        final start = (idx - 100).clamp(0, body.length);
        final end = (idx + 200).clamp(0, body.length);
        print('📄 CSB bağlamı:\n${body.substring(start, end)}');
      }

      // 4. Tüm script tag'lerinde ara
      final document = parse(body);
      final scripts = document.querySelectorAll('script');
      print('\n📜 ${scripts.length} script tag:');
      for (int i = 0; i < scripts.length; i++) {
        final text = scripts[i].text;
        final src = scripts[i].attributes['src'] ?? '';
        if (text.contains('visual') || text.contains('token') || text.contains('csb') ||
            src.contains('visual') || src.contains('matchcast')) {
          print('  script[$i] src=$src snippet=${text.substring(0, text.length.clamp(0, 150))}');
        }
      }

    } catch (e) {
      print('❌ $e');
    }
  }
}

void main() async {
  print('🚀 Mackolik Ham HTML Tarama\n');

  final ids = [
    4314542, // FC Orenburg vs Zenit
  ];

  for (final id in ids) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 Mackolik ID: $id');
    await scanPage(id);
  }

  print('\n✅ Tarama tamamlandı.');
}
