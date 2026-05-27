import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:share_plus/share_plus.dart';
import 'youtube_service.dart';

const _streamChannel = MethodChannel('com.scoreboard/streaming');

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

  bool _isStreaming = false;
  bool _isLoading = false;
  bool _showCamera = false;
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

  late final TextEditingController _titleCtrl;

  @override
  void initState() {
    super.initState();
    _streamChannel.setMethodCallHandler((call) async {
      if (call.method != 'debugStatus') return;
      final message = '${call.arguments ?? ''}';
      if (!mounted) return;
      setState(() {
        _nativeDebugStatus = message;
        _loadingStatus = message;
      });
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
      });
    }
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

  Future<void> _triggerGoal() async {
    HapticFeedback.heavyImpact();
    await _streamChannel.invokeMethod('triggerGoal');
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
                          accentColor: const Color(0xFF2196F3),
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
                          translucent: _showCamera,
                        ),
                      ),
                      _CenterPanel(
                          onReset: _reset,
                          onGoal: _isStreaming ? _triggerGoal : null,
                          isStreaming: _isStreaming),
                      Expanded(
                        child: _TeamPanel(
                          name: _awayName,
                          score: _awayScore,
                          accentColor: const Color(0xFFE53935),
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
  final bool translucent;

  const _TeamPanel({
    required this.name,
    required this.score,
    required this.accentColor,
    required this.onAdd,
    required this.onSubtract,
    required this.onEditName,
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
          GestureDetector(
            onTap: onEditName,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
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

  const _CenterPanel(
      {required this.onReset, required this.onGoal, required this.isStreaming});

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
