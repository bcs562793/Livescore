import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

class MackolikVisualService {
  // Mackolik maç detay URL yapısı
  final String _baseUrl = "https://www.mackolik.com/futbol/mac-detay/gamba-osaka-v-varen-nagasaki/"; // Örnek

  Future<String?> getVisualUrl(String matchId) async {
    try {
      // 1. Maç sayfasına istek at (User-Agent şart, yoksa engeller)
      final response = await http.get(
        Uri.parse("$_baseUrl$matchId"),
        headers: {
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        },
      );

      if (response.statusCode != 200) return null;

      // 2. HTML içinde iframe'i bul
      final document = parse(response.body);
      final iframe = document.querySelector('iframe');
      final src = iframe?.attributes['src'];

      if (src == null) return null;

      // 3. Token kontrolü ve doğrulama
      if (_isTokenExpired(src)) {
        // Eğer token ömrü bitmişse tekrar fetch et (refresh mantığı)
        return getVisualUrl(matchId); 
      }

      return src;
    } catch (e) {
      print("Hata: $e");
      return null;
    }
  }

  bool _isTokenExpired(String url) {
    try {
      // URL'den token'ı ayıkla
      final uri = Uri.parse(url);
      final token = uri.queryParameters['token'];
      if (token == null) return true;

      // JWT'nin payload kısmını al (xxx.payload.xxx)
      final parts = token.split('.');
      if (parts.length != 3) return true;

      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64.normalize(parts[1])))
      );

      // Token süresini kontrol et
      final exp = payload['exp'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // 60 saniye pay bırakıyoruz
      return (exp - now) < 60;
    } catch (e) {
      return true; // Token parse edilemiyorsa geçersiz say
    }
  }
}
