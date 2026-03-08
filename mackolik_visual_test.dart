import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

// ─── SERVİS (inline) ───
final _headers = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'tr-TR,tr;q=0.9,en-US;q=0.8',
  'Referer': 'https://www.mackolik.com/',
};

Future<String?> getVisualUrl(String slug, String matchId) async {
  final url = 'https://www.mackolik.com/futbol/mac-detay/$slug/$matchId';
  print('🔗 Fetching: $url');

  try {
    final response = await http.get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 15));

    print('📡 Status: ${response.statusCode}');

    if (response.statusCode != 200) {
      print('❌ HTTP ${response.statusCode}');
      // HTML'nin ilk 500 karakterini göster
      print('📄 Response preview:\n${response.body.substring(0, response.body.length.clamp(0, 500))}');
      return null;
    }

    final document = parse(response.body);

    // Tüm iframe'leri bul
    final iframes = document.querySelectorAll('iframe');
    print('🖼 Bulunan iframe sayısı: ${iframes.length}');
    for (final iframe in iframes) {
      print('  iframe src: ${iframe.attributes['src']}');
    }

    // Visual iframe'i bul (genellikle "visual" veya "animation" içerir)
    String? visualSrc;
    for (final iframe in iframes) {
      final src = iframe.attributes['src'] ?? '';
      if (src.contains('visual') || src.contains('animat') || src.contains('livescore')) {
        visualSrc = src;
        break;
      }
    }

    // Bulamazsa ilk iframe'i dene
    visualSrc ??= iframes.isNotEmpty ? iframes.first.attributes['src'] : null;

    if (visualSrc == null) {
      print('❌ Hiç iframe bulunamadı');
      // Script taglerini ara — bazı siteler JS ile yükler
      final scripts = document.querySelectorAll('script');
      for (final s in scripts) {
        final text = s.text;
        if (text.contains('visual') || text.contains('animat')) {
          print('📜 Potansiyel script bulundu:\n${text.substring(0, text.length.clamp(0, 300))}');
        }
      }
      return null;
    }

    print('✅ Visual URL bulundu: $visualSrc');

    // Token kontrolü
    final expired = _isTokenExpired(visualSrc);
    print('⏱ Token geçerli mi: ${!expired}');

    return visualSrc;
  } catch (e) {
    print('❌ Hata: $e');
    return null;
  }
}

bool _isTokenExpired(String url) {
  try {
    final uri = Uri.parse(url);
    final token = uri.queryParameters['token'];
    if (token == null) return false; // Token yoksa geçerli say

    final parts = token.split('.');
    if (parts.length != 3) return true;

    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64.normalize(parts[1])))
    );

    final exp = payload['exp'] as int?;
    if (exp == null) return false;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (exp - now) < 60;
  } catch (e) {
    return false;
  }
}

void main() async {
  print('🚀 Mackolik Visual Test Başlıyor...\n');

  // Test maçları: slug ve mackolik ID
  final testMatches = [
    {'slug': 'gamba-osaka-v-varen-nagasaki', 'id': '1506907'},
  ];

  for (final match in testMatches) {
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🏟 Maç: ${match['slug']}');
    final url = await getVisualUrl(match['slug']!, match['id']!);
    if (url != null) {
      print('🎯 SONUÇ: $url');
    } else {
      print('🎯 SONUÇ: URL alınamadı');
    }
    print('');
  }

  print('✅ Test tamamlandı.');
}
