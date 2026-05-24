import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────
// ★ 請到 Google Cloud Console 建立 iOS OAuth 憑證後填入這裡 ★
//   1. https://console.cloud.google.com/
//   2. 建立專案 → 啟用「YouTube Data API v3」
//   3. 憑證 → 建立 OAuth 2.0 用戶端 ID（iOS 應用程式）
//      套件 ID: com.scoreboard.scoreboardapp
//   4. 複製「iOS 用戶端 ID」貼在下方，並更新 Info.plist 的
//      GIDClientID 與 CFBundleURLSchemes（reversed client ID）
// ─────────────────────────────────────────────────────────────
const kGoogleIosClientId =
    'REPLACE_WITH_YOUR_IOS_CLIENT_ID.apps.googleusercontent.com';

const _youtubeScope = 'https://www.googleapis.com/auth/youtube';
const _apiBase = 'https://www.googleapis.com/youtube/v3';

class YouTubeService {
  static final _gsi = GoogleSignIn(scopes: [_youtubeScope]);

  static GoogleSignInAccount? get currentUser => _gsi.currentUser;

  /// 嘗試靜默登入（App 啟動時還原上次登入狀態）
  static Future<GoogleSignInAccount?> signInSilently() =>
      _gsi.signInSilently();

  static Future<GoogleSignInAccount?> signIn() => _gsi.signIn();

  static Future<void> signOut() => _gsi.signOut();

  static Future<String> _token() async {
    final auth = await _gsi.currentUser!.authentication;
    final token = auth.accessToken;
    if (token == null) throw Exception('無法取得 access token');
    return token;
  }

  /// 建立直播活動、串流、綁定，回傳所有推流資訊
  static Future<LiveSetupResult> setupLive({required String title}) async {
    final token = await _token();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    // 1. 建立 liveBroadcast
    final bRes = await http.post(
      Uri.parse('$_apiBase/liveBroadcasts'
          '?part=snippet,contentDetails,status'),
      headers: headers,
      body: jsonEncode({
        'snippet': {
          'title': title,
          'scheduledStartTime':
              DateTime.now().toUtc().add(const Duration(seconds: 10)).toIso8601String(),
        },
        'contentDetails': {
          'enableAutoStart': true,
          'enableAutoStop': true,
          'monitorStream': {'enableMonitorStream': false},
        },
        'status': {
          'privacyStatus': 'public',
          'selfDeclaredMadeForKids': false,
        },
      }),
    );
    _check(bRes, '建立直播活動失敗');
    final bId = (jsonDecode(bRes.body) as Map)['id'] as String;

    // 2. 建立 liveStream
    final sRes = await http.post(
      Uri.parse('$_apiBase/liveStreams?part=snippet,cdn,contentDetails'),
      headers: headers,
      body: jsonEncode({
        'snippet': {'title': title},
        'cdn': {
          'frameRate': '30fps',
          'ingestionType': 'rtmp',
          'resolution': '720p',
        },
        'contentDetails': {'isReusable': false},
      }),
    );
    _check(sRes, '建立串流失敗');
    final sBody = jsonDecode(sRes.body) as Map;
    final sId = sBody['id'] as String;
    final ingestion = sBody['cdn']['ingestionInfo'] as Map;
    final rtmpUrl = ingestion['ingestionAddress'] as String;
    final streamKey = ingestion['streamName'] as String;

    // 3. 綁定 broadcast ↔ stream
    final bindRes = await http.post(
      Uri.parse(
          '$_apiBase/liveBroadcasts/bind?id=$bId&part=id,contentDetails&streamId=$sId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _check(bindRes, '綁定串流失敗');

    return LiveSetupResult(
      broadcastId: bId,
      rtmpUrl: rtmpUrl,
      streamKey: streamKey,
      watchUrl: 'https://www.youtube.com/watch?v=$bId',
    );
  }

  /// 停播（transition → complete）
  static Future<void> stopBroadcast(String broadcastId) async {
    try {
      final token = await _token();
      await http.post(
        Uri.parse('$_apiBase/liveBroadcasts/transition'
            '?broadcastStatus=complete&id=$broadcastId&part=status'),
        headers: {'Authorization': 'Bearer $token'},
      );
    } catch (_) {
      // 停播失敗不影響 App 主流程，靜默忽略
    }
  }

  static void _check(http.Response res, String label) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String msg = label;
      try {
        final body = jsonDecode(res.body) as Map;
        final err = body['error'] as Map?;
        msg = '$label: ${err?['message'] ?? res.body}';
      } catch (_) {}
      throw Exception(msg);
    }
  }
}

class LiveSetupResult {
  final String broadcastId;
  final String rtmpUrl;
  final String streamKey;
  final String watchUrl;

  const LiveSetupResult({
    required this.broadcastId,
    required this.rtmpUrl,
    required this.streamKey,
    required this.watchUrl,
  });
}
