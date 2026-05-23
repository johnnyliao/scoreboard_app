import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  String _homeName = '主隊';
  String _awayName = '客隊';

  void _editName(bool isHome) {
    final controller = TextEditingController(
      text: isHome ? _homeName : _awayName,
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isHome ? '主隊名稱' : '客隊名稱'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '輸入隊名'),
          onSubmitted: (_) => _saveName(ctx, isHome, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => _saveName(ctx, isHome, controller.text),
            child: const Text('確定'),
          ),
        ],
      ),
    );
  }

  void _saveName(BuildContext ctx, bool isHome, String value) {
    setState(() {
      if (isHome) {
        _homeName = value.trim().isEmpty ? '主隊' : value.trim();
      } else {
        _awayName = value.trim().isEmpty ? '客隊' : value.trim();
      }
    });
    Navigator.pop(ctx);
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
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _homeScore = 0;
                _awayScore = 0;
              });
              Navigator.pop(ctx);
            },
            child: const Text('重置', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: _TeamPanel(
                name: _homeName,
                score: _homeScore,
                accentColor: const Color(0xFF2196F3),
                onAdd: () => setState(() => _homeScore++),
                onSubtract: () => setState(() {
                  if (_homeScore > 0) _homeScore--;
                }),
                onEditName: () => _editName(true),
              ),
            ),
            _CenterPanel(onReset: _reset),
            Expanded(
              child: _TeamPanel(
                name: _awayName,
                score: _awayScore,
                accentColor: const Color(0xFFE53935),
                onAdd: () => setState(() => _awayScore++),
                onSubtract: () => setState(() {
                  if (_awayScore > 0) _awayScore--;
                }),
                onEditName: () => _editName(false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamPanel extends StatelessWidget {
  final String name;
  final int score;
  final Color accentColor;
  final VoidCallback onAdd;
  final VoidCallback onSubtract;
  final VoidCallback onEditName;

  const _TeamPanel({
    required this.name,
    required this.score,
    required this.accentColor,
    required this.onAdd,
    required this.onSubtract,
    required this.onEditName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentColor.withOpacity(0.25), width: 1.5),
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
                const SizedBox(width: 6),
                Icon(Icons.edit, color: accentColor.withOpacity(0.5), size: 15),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$score',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 100,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ScoreButton(
                label: '−',
                color: Colors.white24,
                onPressed: onSubtract,
              ),
              const SizedBox(width: 24),
              _ScoreButton(
                label: '+',
                color: accentColor,
                onPressed: onAdd,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CenterPanel extends StatelessWidget {
  final VoidCallback onReset;

  const _CenterPanel({required this.onReset});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'VS',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: onReset,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.refresh, color: Colors.white38, size: 26),
          ),
        ),
      ],
    );
  }
}

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
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: color == Colors.white24 ? Colors.white60 : color,
              fontSize: 32,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
