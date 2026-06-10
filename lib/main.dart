import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:share_plus/share_plus.dart';
import 'youtube_service.dart';

const _streamChannel = MethodChannel('com.scoreboard/streaming');

// 球員名冊 — 順序即選號 grid 排版順序(左上→右下,每列 4 格,可上下滑動)。
// tile = 格子上顯示的文字(球衣號碼,或租借球員的姓氏);name = 進球慶祝顯示的名字。
// 前 12 位是隊上球員(號碼非連續,沒有 3/12/13);最後 2 位是別隊租借、無號碼,
// 格子只顯示姓氏(簡/林),慶祝仍顯示名字(以諾/言瑀)。
const List<({String tile, String name})> _players = [
  (tile: '1', name: '胤丞'),  (tile: '2', name: '秉諺'),  (tile: '4', name: '浩宇'),  (tile: '5', name: '胤銘'),
  (tile: '6', name: '梓敬'),  (tile: '7', name: '祐翼'),  (tile: '8', name: '學濬'),  (tile: '9', name: '宥愷'),
  (tile: '10', name: '岳辰'), (tile: '11', name: '翰墨'), (tile: '14', name: '祥宇'), (tile: '15', name: '祐瑀'),
  (tile: '簡', name: '以諾'),  (tile: '林', name: '言瑀'),
];

// 隊伍顏色調色盤。橘/紫為兩隊共用的單一來源,避免值不一致。
const int _kOrange = 0xFFF57C00;
const int _kPurple = 0xFF8E24AA;

// 客隊可選的完整 10 色(常見足球隊服配色),預設黃。
const List<({String name, int value})> _awayColors = [
  (name: '紅',   value: 0xFFE53935),
  (name: '橘',   value: _kOrange),
  (name: '黃',   value: 0xFFFDD835),
  (name: '綠',   value: 0xFF43A047),
  (name: '淺藍', value: 0xFF29B6F6),
  (name: '深藍', value: 0xFF1565C0),
  (name: '紫',   value: _kPurple),
  (name: '黑',   value: 0xFF212121),
  (name: '白',   value: 0xFFFFFFFF),
  (name: '桃紅', value: 0xFFEC407A),
];

// 主隊只有橘、紫兩套球衣,預設橘。
const List<({String name, int value})> _homeColors = [
  (name: '橘', value: _kOrange),
  (name: '紫', value: _kPurple),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ScoreboardApp());
}

class ScoreboardApp extends StatelessWidget {
  const ScoreboardApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scoreboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const ScoreboardPage(),
    );
  }
}

class ScoreboardPage extends StatefulWidget {
  const ScoreboardPage({super.key});
  @override
  State<ScoreboardPage> createState() => _ScoreboardPageState();
}

class _ScoreboardPageState extends State<ScoreboardPage> {
  int _homeScore = 0;
  int _awayScore = 0;
  String _homeName = '安和';
  String _awayName = '客隊';

  // Team colors — synced to the YouTube overlay. Defaults: home 橘, away 黃.
  Color _homeColor = const Color(_kOrange);
  Color _awayColor = const Color(0xFFFDD835);

  bool _isStreaming = false;
  bool _isLoading = false;
  bool _showCamera = false;
  bool _isReconnecting = false;
  String _loadingStatus = '';
  String _nativeDebugStatus = '';

  GoogleSignInAccount? _account;
  String? _watchUrl;
  String? _broadcastId;

  // Status bar
  final _battery = Battery();
  Timer? _clockTimer;
  Timer? _batteryTimer;
  int _batteryLevel = -1;
  DateTime? _streamStartTime;

  // Match clock — wall-clock anchored so pause/resume never drifts.
  // _clockAccumMs holds time from completed runs; _clockRunStart marks the
  // current run (null when paused). _matchTimer only drives the 1s refresh+sync.
  int _clockAccumMs = 0;
  DateTime? _clockRunStart;
  Timer? _matchTimer;

  bool get _isClockRunning => _clockRunStart != null;

  int get _matchSeconds {
    var ms = _clockAccumMs;
    if (_clockRunStart != null) {
      ms += DateTime.now().difference(_clockRunStart!).inMilliseconds;
    }
    return ms ~/ 1000;
  }

  String get _clockText {
    final s = _matchSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  late final TextEditingController _titleCtrl;

  @override
  void initState() {
    super.initState();
    _streamChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'debugStatus':
          final message = '${call.arguments ?? ''}';
          if (!mounted) return;
          setState(() {
            _nativeDebugStatus = message;
            _loadingStatus = message;
          });
        case 'connectionState':
          _handleConnectionState('${call.arguments ?? ''}');
      }
    });
    final now = DateTime.now();
    _titleCtrl = TextEditingController(
      text:
          'Live Scoreboard ${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}',
    );
    _tryRestoreSignIn();
    _fetchBattery();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchBattery());
  }

  Future<void> _fetchBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    } catch (_) {}
  }

  Future<void> _tryRestoreSignIn() async {
    final account = await YouTubeService.signInSilently();
    if (mounted && account != null) setState(() => _account = account);
  }

  @override
  void dispose() {
    _streamChannel.setMethodCallHandler(null);
    _clockTimer?.cancel();
    _batteryTimer?.cancel();
    _matchTimer?.cancel();
    _titleCtrl.dispose();
    super.dispose();
  }

  // ── Score sync ─────────────────────────────────────────────

  void _syncScore() {
    if (_isStreaming) {
      _streamChannel.invokeMethod('updateScore', {
        'homeName': _homeName,
        'homeScore': _homeScore,
        'awayName': _awayName,
        'awayScore': _awayScore,
        'clock': _clockText,
        'homeColor': _homeColor.value,
        'awayColor': _awayColor.value,
      });
    }
  }

  // ── Match clock ────────────────────────────────────────────

  void _startClock() {
    if (_isClockRunning) return;
    _clockRunStart = DateTime.now();
    _matchTimer?.cancel();
    _matchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {}); // refresh in-app clock display
      _syncScore();    // push new clock to the YouTube overlay
    });
    setState(() {});
    _syncScore();
  }

  void _pauseClock() {
    if (!_isClockRunning) return;
    _clockAccumMs +=
        DateTime.now().difference(_clockRunStart!).inMilliseconds;
    _clockRunStart = null;
    _matchTimer?.cancel();
    _matchTimer = null;
    setState(() {});
    _syncScore();
  }

  void _toggleClock() => _isClockRunning ? _pauseClock() : _startClock();

  void _resetClock() {
    _matchTimer?.cancel();
    _matchTimer = null;
    setState(() {
      _clockAccumMs = 0;
      _clockRunStart = null;
    });
    _syncScore();
  }

  // ── Sign in / out ──────────────────────────────────────────

  Future<void> _signIn() async {
    try {
      final account = await YouTubeService.signIn();
      if (mounted && account != null) setState(() => _account = account);
    } catch (e) {
      _showError('登入失敗: $e');
    }
  }

  Future<void> _signOut() async {
    await YouTubeService.signOut();
    if (mounted) setState(() => _account = null);
  }

  // ── Start / Stop stream ────────────────────────────────────

  Future<void> _startStream() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _showError('請輸入直播標題');
      return;
    }
    setState(() { _isLoading = true; _loadingStatus = '建立直播活動…'; });
    LiveSetupResult? live;
    try {
      live = await YouTubeService.setupLive(title: title);

      if (mounted) setState(() => _loadingStatus = '連接 RTMP…');
      await _streamChannel.invokeMethod('startStream', {
        'url': live.rtmpUrl,
        'key': live.streamKey,
      });

      if (mounted) setState(() => _loadingStatus = '等待 YouTube 確認串流…');
      await YouTubeService.waitUntilStreamActive(live.streamId);

      if (mounted) setState(() => _loadingStatus = '切換直播為上線狀態…');
      await YouTubeService.transitionToLive(live.broadcastId);

      setState(() {
        _isStreaming = true;
        _showCamera = true;
        _watchUrl = live!.watchUrl;
        _broadcastId = live.broadcastId;
        _loadingStatus = '';
        _streamStartTime = DateTime.now();
      });
      _syncScore();
    } on PlatformException catch (e) {
      if (live != null) await YouTubeService.deleteBroadcast(live.broadcastId);
      final message = e.message ?? '推流失敗';
      final detail =
          _nativeDebugStatus.isEmpty ? '' : '\n最後狀態: $_nativeDebugStatus';
      _showError('$message$detail');
    } catch (e) {
      if (live != null) await YouTubeService.deleteBroadcast(live.broadcastId);
      _showError('$e');
    } finally {
      // If start did not fully succeed, the native side may have already
      // begun publishing (isStreaming=true) before a later step (e.g.
      // waitUntilStreamActive) threw. Reset it so the next 開始直播 isn't
      // blocked by "already starting or streaming".
      if (!_isStreaming) {
        try {
          await _streamChannel.invokeMethod('stopStream');
        } catch (_) {}
      }
      if (mounted) setState(() { _isLoading = false; _loadingStatus = ''; });
    }
  }

  Future<void> _stopStream() async {
    setState(() => _isLoading = true);
    try {
      await _streamChannel.invokeMethod('stopStream');
      if (_broadcastId != null) {
        await YouTubeService.stopBroadcast(_broadcastId!);
      }
      setState(() {
        _isStreaming = false;
        _showCamera = false;
        _isReconnecting = false;
        _watchUrl = null;
        _broadcastId = null;
        _streamStartTime = null;
      });
    } catch (e) {
      _showError('停止失敗: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── 斷線重連狀態(來自 native) ──────────────────────────

  void _handleConnectionState(String state) {
    if (!mounted) return;
    switch (state) {
      case 'reconnecting':
        // native 重試期間可能重複送 reconnecting,只在第一次提示
        if (!_isReconnecting) {
          setState(() => _isReconnecting = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('直播連線中斷，自動重連中…'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      case 'reconnected':
        setState(() => _isReconnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已重新連上，直播恢復'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
        _syncScore(); // 立刻把最新比分/時鐘推回 overlay
      case 'lost':
        // 重連次數用盡:native 已收掉 RTMP,這裡同步 UI 並結束 YouTube broadcast
        final bId = _broadcastId;
        setState(() {
          _isReconnecting = false;
          _isStreaming = false;
          _showCamera = false;
          _watchUrl = null;
          _broadcastId = null;
          _streamStartTime = null;
        });
        if (bId != null) YouTubeService.stopBroadcast(bId);
        _showError('直播連線中斷，多次重連失敗，已停止直播');
    }
  }

  // ── UI helpers ─────────────────────────────────────────────

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  void _editName(bool isHome) {
    final ctrl =
        TextEditingController(text: isHome ? _homeName : _awayName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isHome ? '主隊名稱' : '客隊名稱'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (_) => _saveName(ctx, isHome, ctrl.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
            onPressed: () => _saveName(ctx, isHome, ctrl.text),
            child: const Text('確定'),
          ),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  void _saveName(BuildContext ctx, bool isHome, String value) {
    setState(() {
      if (isHome) {
        _homeName = value.trim().isEmpty ? '安和' : value.trim();
      } else {
        _awayName = value.trim().isEmpty ? '客隊' : value.trim();
      }
    });
    Navigator.pop(ctx);
    _syncScore();
  }

  // ── Team color ─────────────────────────────────────────────

  void _editColor(bool isHome) {
    final options = isHome ? _homeColors : _awayColors;
    final current = isHome ? _homeColor : _awayColor;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => _ColorPickerDialog(
        title: isHome ? '主隊顏色' : '客隊顏色',
        options: options,
        selected: current.value,
        onPick: (value) {
          Navigator.pop(ctx);
          setState(() {
            if (isHome) {
              _homeColor = Color(value);
            } else {
              _awayColor = Color(value);
            }
          });
          _syncScore();
        },
      ),
    );
  }

  /// 按下 GOAL 後先彈出球員選號 modal,選定後才真正觸發慶祝動畫。
  void _triggerGoal() {
    HapticFeedback.lightImpact();
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => _GoalPickerDialog(
        players: _players,
        onPick: (name) {
          Navigator.pop(ctx);
          _fireGoal(name);
        },
      ),
    );
  }

  Future<void> _fireGoal(String name) async {
    HapticFeedback.heavyImpact();
    await _streamChannel.invokeMethod('triggerGoal', {
      'playerName': name,
    });
  }

  void _reset() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置比分'),
        content: const Text('確定要將比分歸零？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
            onPressed: () {
              setState(() {
                _homeScore = 0;
                _awayScore = 0;
              });
              Navigator.pop(ctx);
              _syncScore();
            },
            child: const Text('重置',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ── Status bar ────────────────────────────────────────────

  Widget _buildStatusBar() {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final chips = <Widget>[];

    if (_isReconnecting) {
      chips.add(_statusChip(Icons.wifi_off, '重連中…', Colors.orangeAccent));
      chips.add(const SizedBox(width: 16));
    }

    if (_isStreaming && _streamStartTime != null) {
      final elapsed = now.difference(_streamStartTime!);
      final h = elapsed.inHours.toString().padLeft(2, '0');
      final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
      final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      chips.add(_statusChip(Icons.radio_button_checked, '$h:$m:$s', Colors.redAccent));
      chips.add(const SizedBox(width: 16));
    }

    chips.add(_statusChip(Icons.access_time, timeStr, Colors.white60));

    if (_batteryLevel >= 0) {
      chips.add(const SizedBox(width: 16));
      final IconData batteryIcon;
      if (_batteryLevel > 80) {
        batteryIcon = Icons.battery_full;
      } else if (_batteryLevel > 50) {
        batteryIcon = Icons.battery_5_bar;
      } else if (_batteryLevel > 20) {
        batteryIcon = Icons.battery_3_bar;
      } else {
        batteryIcon = Icons.battery_1_bar;
      }
      final batteryColor = _batteryLevel > 20 ? Colors.white60 : Colors.red;
      chips.add(_statusChip(batteryIcon, '$_batteryLevel%', batteryColor));
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3),
      color: Colors.black38,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: chips),
    );
  }

  Widget _statusChip(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }

  // ── Build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Stack(
        children: [
          if (_showCamera)
            const Positioned.fill(
              child: UiKitView(
                viewType: 'com.scoreboard/camera_preview',
                creationParamsCodec: StandardMessageCodec(),
              ),
            ),
          if (!_showCamera) Container(color: const Color(0xFF0A0E1A)),
          SafeArea(
            child: Column(
              children: [
                _buildStatusBar(),
                _TopBar(
                  account: _account,
                  isStreaming: _isStreaming,
                  isLoading: _isLoading,
                  loadingStatus: _loadingStatus,
                  titleCtrl: _titleCtrl,
                  watchUrl: _watchUrl,
                  onSignIn: _signIn,
                  onSignOut: _signOut,
                  onStart: _account != null && !_isStreaming
                      ? _startStream
                      : null,
                  onStop: _isStreaming ? _stopStream : null,
                ),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: _TeamPanel(
                          name: _homeName,
                          score: _homeScore,
                          accentColor: _homeColor,
                          onAdd: () {
                            setState(() => _homeScore++);
                            _syncScore();
                          },
                          onSubtract: () {
                            setState(() {
                              if (_homeScore > 0) _homeScore--;
                            });
                            _syncScore();
                          },
                          onEditName: () => _editName(true),
                          onEditColor: () => _editColor(true),
                          translucent: _showCamera,
                        ),
                      ),
                      _CenterPanel(
                          onReset: _reset,
                          onGoal: _isStreaming ? _triggerGoal : null,
                          isStreaming: _isStreaming,
                          clockText: _clockText,
                          isClockRunning: _isClockRunning,
                          onToggleClock: _toggleClock,
                          onResetClock: _resetClock),
                      Expanded(
                        child: _TeamPanel(
                          name: _awayName,
                          score: _awayScore,
                          accentColor: _awayColor,
                          onAdd: () {
                            setState(() => _awayScore++);
                            _syncScore();
                          },
                          onSubtract: () {
                            setState(() {
                              if (_awayScore > 0) _awayScore--;
                            });
                            _syncScore();
                          },
                          onEditName: () => _editName(false),
                          onEditColor: () => _editColor(false),
                          translucent: _showCamera,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Top Bar ─────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final GoogleSignInAccount? account;
  final bool isStreaming;
  final bool isLoading;
  final String loadingStatus;
  final TextEditingController titleCtrl;
  final String? watchUrl;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback? onStart;
  final VoidCallback? onStop;

  const _TopBar({
    required this.account,
    required this.isStreaming,
    required this.isLoading,
    required this.loadingStatus,
    required this.titleCtrl,
    required this.watchUrl,
    required this.onSignIn,
    required this.onSignOut,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.black54,
      child: Row(
        children: [
          // ── Left: sign-in state ──
          if (account == null)
            _btn(
              label: '登入 YouTube',
              icon: Icons.login,
              color: const Color(0xFFFF0000),
              onTap: isLoading ? null : onSignIn,
            )
          else if (!isStreaming)
            _accountChip(context, account!)
          else
            _liveBadge(),

          const SizedBox(width: 10),

          // ── Center: title / watch URL ──
          Expanded(
            child: isStreaming && watchUrl != null
                ? GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: watchUrl!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('連結已複製'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Text(
                      watchUrl!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                : TextField(
                    controller: titleCtrl,
                    enabled: !isStreaming && account != null,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: '直播標題',
                      hintStyle: TextStyle(
                          color: Colors.white30, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                      prefixIcon: Icon(Icons.title,
                          color: Colors.white30, size: 16),
                    ),
                  ),
          ),

          const SizedBox(width: 8),

          // ── Right: action buttons ──
          if (isLoading)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
                if (loadingStatus.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(loadingStatus,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11)),
                ],
              ],
            )
          else if (isStreaming) ...[
            if (watchUrl != null)
              IconButton(
                icon: const Icon(Icons.share,
                    color: Colors.white70, size: 20),
                onPressed: () => Share.share(watchUrl!),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            const SizedBox(width: 8),
            _btn(
              label: '停止直播',
              icon: Icons.stop_circle_outlined,
              color: Colors.red,
              onTap: onStop,
            ),
          ] else if (account != null)
            _btn(
              label: '開始直播',
              icon: Icons.live_tv,
              color: const Color(0xFF2196F3),
              onTap: onStart,
            ),
        ],
      ),
    );
  }

  Widget _liveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '● LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _accountChip(BuildContext context, GoogleSignInAccount account) {
    return GestureDetector(
      onTap: () => _showSignOutMenu(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundImage: account.photoUrl != null
                ? NetworkImage(account.photoUrl!)
                : null,
            child: account.photoUrl == null
                ? Text(
                    account.displayName?.substring(0, 1).toUpperCase() ?? 'Y',
                    style: const TextStyle(fontSize: 11),
                  )
                : null,
          ),
          const SizedBox(width: 6),
          Text(
            account.displayName ?? account.email,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  void _showSignOutMenu(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('帳號'),
        content:
            Text(account?.email ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onSignOut();
            },
            child: const Text('登出',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _btn({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      height: 32,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}

// ── Team Panel ───────────────────────────────────────────────

class _TeamPanel extends StatelessWidget {
  final String name;
  final int score;
  final Color accentColor;
  final VoidCallback onAdd;
  final VoidCallback onSubtract;
  final VoidCallback onEditName;
  final VoidCallback onEditColor;
  final bool translucent;

  const _TeamPanel({
    required this.name,
    required this.score,
    required this.accentColor,
    required this.onAdd,
    required this.onSubtract,
    required this.onEditName,
    required this.onEditColor,
    required this.translucent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: translucent
            ? Colors.black.withOpacity(0.55)
            : accentColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: accentColor.withOpacity(0.3), width: 1.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: onEditName,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.edit,
                        color: accentColor.withOpacity(0.5), size: 14),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onEditColor,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.palette,
                      color: accentColor.withOpacity(0.7), size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$score',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 68,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ScoreButton(
                  label: '−',
                  color: Colors.white24,
                  onPressed: onSubtract),
              const SizedBox(width: 20),
              _ScoreButton(
                  label: '+',
                  color: accentColor,
                  onPressed: onAdd),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Center Panel ─────────────────────────────────────────────

class _CenterPanel extends StatelessWidget {
  final VoidCallback onReset;
  final VoidCallback? onGoal;
  final bool isStreaming;
  final String clockText;
  final bool isClockRunning;
  final VoidCallback onToggleClock;
  final VoidCallback onResetClock;

  const _CenterPanel({
    required this.onReset,
    required this.onGoal,
    required this.isStreaming,
    required this.clockText,
    required this.isClockRunning,
    required this.onToggleClock,
    required this.onResetClock,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isStreaming)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          )
        else
          const Text(
            'VS',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        const SizedBox(height: 14),

        // ── Match clock display ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isClockRunning ? Colors.greenAccent : Colors.white24,
              width: 1.2,
            ),
          ),
          child: Text(
            clockText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
              letterSpacing: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 8),

        // ── Start / Pause + Reset clock ──
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ClockButton(
              icon: isClockRunning ? Icons.pause : Icons.play_arrow,
              color: isClockRunning
                  ? const Color(0xFFFFB300)
                  : const Color(0xFF43A047),
              onTap: onToggleClock,
            ),
            const SizedBox(width: 8),
            _ClockButton(
              icon: Icons.restart_alt,
              color: Colors.white24,
              onTap: onResetClock,
            ),
          ],
        ),

        const SizedBox(height: 16),
        if (onGoal != null)
          GestureDetector(
            onTap: onGoal,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFD700), Color(0xFFFF8C00)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFD700).withOpacity(0.5),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Text(
                'GOAL!',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: onReset,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.refresh,
                color: Colors.white38, size: 24),
          ),
        ),
      ],
    );
  }
}

// ── Score Button ─────────────────────────────────────────────

class _ScoreButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _ScoreButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.2),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: color == Colors.white24 ? Colors.white60 : color,
              fontSize: 30,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Goal Picker Dialog ───────────────────────────────────────

class _GoalPickerDialog extends StatelessWidget {
  final List<({String tile, String name})> players;
  final void Function(String name) onPick;

  const _GoalPickerDialog({required this.players, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF141821),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.sports_soccer, color: Color(0xFFFFD700), size: 22),
                SizedBox(width: 8),
                Text(
                  '誰進球的?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Flexible + scrollable so lower rows stay reachable in landscape,
            // where dialog height is tight (~342pt usable). Without this the
            // Column overflowed and the bottom row fell outside the tappable
            // area. childAspectRatio is tuned so the first ~3 rows fit without
            // scrolling; with 14 players (4 rows) the 4th row (the 2 loaned
            // players) is reached by scrolling — the safety net.
            Flexible(
              child: GridView.count(
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                crossAxisCount: 4,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.7,
                children: [
                  for (final p in players)
                    _PlayerTile(
                      label: p.tile,
                      onTap: () => onPick(p.name),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: Colors.white54),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PlayerTile({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1F2735),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12, width: 1),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            style: const TextStyle(
              color: Color(0xFFFFD700),
              fontSize: 32,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Color Picker Dialog ──────────────────────────────────────

class _ColorPickerDialog extends StatelessWidget {
  final String title;
  final List<({String name, int value})> options;
  final int selected;
  final void Function(int value) onPick;

  const _ColorPickerDialog({
    required this.title,
    required this.options,
    required this.selected,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF141821),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.palette, color: Color(0xFFFFD700), size: 22),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Flexible(
              child: GridView.count(
                shrinkWrap: true,
                physics: const ClampingScrollPhysics(),
                crossAxisCount: 5,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1,
                children: [
                  for (final c in options)
                    _ColorSwatch(
                      name: c.name,
                      value: c.value,
                      isSelected: c.value == selected,
                      onTap: () => onPick(c.value),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: Colors.white54),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final String name;
  final int value;
  final bool isSelected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.name,
    required this.value,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(value);
    // Pick a readable label color against the swatch by perceived luminance.
    final luminance = color.computeLuminance();
    final labelColor = luminance > 0.55 ? Colors.black87 : Colors.white;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: isSelected ? 3 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: labelColor,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── Clock Button ─────────────────────────────────────────────

class _ClockButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ClockButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.22),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            icon,
            color: color == Colors.white24 ? Colors.white70 : Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}
