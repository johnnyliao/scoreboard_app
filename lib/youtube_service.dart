import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

const kGoogleIosClientId =
    '78131088279-gs5a1kvq3fbc12o01om6leshn0tsmag1.apps.googleusercontent.com';

const _youtubeScope = 'https://www.googleapis.com/auth/youtube';
const _apiBase = 'https://www.googleapis.com/youtube/v3';

class YouTubeService {
  static final _gsi = GoogleSignIn(scopes: [_youtubeScope]);

  static GoogleSignInAccount? get currentUser => _gsi.currentUser;

  static Future<GoogleSignInAccount?> signInSilently() =>
      _gsi.signInSilently();

  static Future<GoogleSignInAccount?> signIn() => _gsi.signIn();

  static Future<void> signOut() => _gsi.signOut();

  static Future<String> _token() async {
    final user = _gsi.currentUser;
    if (user == null) throw Exception('未登入');

    final granted = await _gsi.requestScopes([_youtubeScope]);
    if (!granted) throw Exception('需要 YouTube 管理權限，請在 Google 同意畫面按「允許」');

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

    // 1. 建立 liveBroadcast（關閉 autoStart，改用手動 transition）
    final bRes = await http.post(
      Uri.parse('$_apiBase/liveBroadcasts?part=snippet,contentDetails,status'),
      headers: headers,
      body: jsonEncode({
        'snippet': {
          'title': title,
          'scheduledStartTime':
              DateTime.now().toUtc().add(const Duration(seconds: 30)).toIso8601String(),
        },
        'contentDetails': {
          'enableAutoStart': false,
          'enableAutoStop': false,
          'monitorStream': {'enableMonitorStream': false},
        },
        'status': {
          'privacyStatus': 'unlisted',
          'selfDeclaredMadeForKids': false,
        },
      }),
    );
    _check(bRes, '建立直播活動失敗');
    final bId = (jsonDecode(bRes.body) as Map)['id'] as String;

    // 2 & 3: 建立 liveStream 和 bind — 若任一步失敗，刪除已建立的 broadcast
    try {
      final sRes = await http.post(
        Uri.parse('$_apiBase/liveStreams?part=snippet,cdn,contentDetails'),
        headers: headers,
        body: jsonEncode({
          'snippet': {'title': title},
          'cdn': {
            'frameRate': '30fps',
            'ingestionType': 'rtmp',
            'resolution': '1080p',
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

      final bindRes = await http.post(
        Uri.parse(
            '$_apiBase/liveBroadcasts/bind?id=$bId&part=id,contentDetails&streamId=$sId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      _check(bindRes, '綁定串流失敗');

      return LiveSetupResult(
        broadcastId: bId,
        streamId: sId,
        rtmpUrl: rtmpUrl,
        streamKey: streamKey,
        watchUrl: 'https://www.youtube.com/watch?v=$bId',
      );
    } catch (_) {
      await deleteBroadcast(bId);
      rethrow;
    }
  }

  /// 查詢 liveStream 目前的 streamStatus
  static Future<String?> getStreamStatus(String streamId) async {
    final token = await _token();
    final res = await http.get(
      Uri.parse('$_apiBase/liveStreams?part=status&id=$streamId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _check(res, '查詢串流狀態失敗');
    final body = jsonDecode(res.body) as Map;
    final items = body['items'] as List;
    if (items.isEmpty) return null;
    return items.first['status']?['streamStatus'] as String?;
  }

  /// 輪詢直到 YouTube 確認收到 RTMP（streamStatus == active），最多等 60 秒
  static Future<void> waitUntilStreamActive(String streamId) async {
    final token = await _token();
    for (var i = 0; i < 30; i++) {
      final res = await http.get(
        Uri.parse('$_apiBase/liveStreams?part=status&id=$streamId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      _check(res, '查詢串流狀態失敗');
      final items = (jsonDecode(res.body) as Map)['items'] as List;
      if (items.isNotEmpty) {
        final status = items.first['status']?['streamStatus'] as String?;
        if (status == 'active') return;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    throw Exception('YouTube 未收到 RTMP 串流（等待逾時 60 秒），請確認網路');
  }

  /// 手動將 broadcast 切換為 live
  static Future<void> transitionToLive(String broadcastId) async {
    final token = await _token();
    final res = await http.post(
      Uri.parse('$_apiBase/liveBroadcasts/transition'
          '?broadcastStatus=live&id=$broadcastId&part=status'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _check(res, '切換直播狀態為 live 失敗');
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
    } catch (_) {}
  }

  /// 刪除從未開播的直播活動（建立失敗時清理垃圾用）
  static Future<void> deleteBroadcast(String broadcastId) async {
    try {
      final token = await _token();
      await http.delete(
        Uri.parse('$_apiBase/liveBroadcasts?id=$broadcastId'),
        headers: {'Authorization': 'Bearer $token'},
      );
    } catch (_) {}
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
  final String streamId;
  final String rtmpUrl;
  final String streamKey;
  final String watchUrl;

  const LiveSetupResult({
    required this.broadcastId,
    required this.streamId,
    required this.rtmpUrl,
    required this.streamKey,
    required this.watchUrl,
  });
}
