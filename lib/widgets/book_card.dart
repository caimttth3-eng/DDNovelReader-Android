import 'package:flutter/material.dart';

import '../models/book.dart';

/// 9:16 木纹书籍卡片：木纹纹理背景 + 居中书名 + 底部腰封进度条。
class BookCard extends StatelessWidget {
  final String title;
  final BookFormat format;
  final double progress; // 0~1
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const BookCard({
    super.key,
    required this.title,
    required this.format,
    required this.progress,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final aspect = 9 / 16;
    return AspectRatio(
      aspectRatio: aspect,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
              border: Border.all(
                color: const Color(0xFF8A5A2B),
                width: 1.5,
              ),
              // 木纹纹理：用多条纵向渐变 + 木节效果
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFB07A3E),
                  Color(0xFF9A6733),
                  Color(0xFF8A5A2B),
                  Color(0xFF7A4E24),
                ],
                stops: [0.0, 0.35, 0.7, 1.0],
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Stack(
                children: [
                  // 木纹纹理线
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WoodGrainPainter(),
                    ),
                  ),
                  // 书名（竖排显示，模拟书脊文字更贴近 9:16）
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFFF3E0),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                          shadows: [
                            Shadow(
                              color: Color(0x66000000),
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 底部腰封：进度
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Color(0xFF4A2E14),
                        border: Border(
                          top: BorderSide(color: Color(0xFF2D1A0A), width: 1.5),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          // 底槽
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            height: 6,
                            decoration: BoxDecoration(
                              color: const Color(0x33FFFFFF),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          // 进度填充
                          FractionallySizedBox(
                            widthFactor: progress.clamp(0.0, 1.0),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 6),
                              height: 6,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFFFFD54F), Color(0xFFFFAB00)],
                                ),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          // 百分比文字
                          Center(
                            child: Text(
                              '${(progress * 100).round()}%',
                              style: const TextStyle(
                                color: Color(0xFFFFE0B2),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                shadows: [
                                  Shadow(color: Color(0xAA000000), blurRadius: 1),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 木纹纹理画笔：绘制细密木纹线
class _WoodGrainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 1;
    final rnd = _SeededRandom(42);
    // 纵向木纹
    for (var x = 0.0; x < size.width; x += 3 + rnd.nextDouble() * 4) {
      final wobble = rnd.nextDouble() * 2 - 1;
      final path = Path()..moveTo(x, 0);
      for (var y = 0.0; y < size.height; y += 8) {
        path.lineTo(x + wobble * 0.6, y + 4);
      }
      canvas.drawPath(path, paint);
    }
    // 木节
    final knotPaint = Paint()
      ..color = const Color(0x33805020)
      ..style = PaintingStyle.fill;
    for (var i = 0; i < 3; i++) {
      final cx = rnd.nextDouble() * size.width;
      final cy = rnd.nextDouble() * size.height;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: 4 + rnd.nextDouble() * 6, height: 5 + rnd.nextDouble() * 8),
        knotPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 简单确定性随机
class _SeededRandom {
  int _seed;
  _SeededRandom(this._seed);
  double nextDouble() {
    _seed = (_seed * 9301 + 49297) % 233280;
    return _seed / 233280;
  }
}

/// 书架首位的"添加书籍"空白书占位卡：浅色木纹 + 加号 + 文字，点击触发添加。
class AddBookCard extends StatelessWidget {
  final VoidCallback? onTap;

  const AddBookCard({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: const Color(0xFFB5A58A),
                width: 1.5,
              ),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFD9C7A8),
                  Color(0xFFCBB58F),
                  Color(0xFFBFA982),
                  Color(0xFFB3A07B),
                ],
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _WoodGrainPainter()),
                  ),
                  // 虚线分隔（模拟空白书封面）
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DashedBorderPainter(),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add,
                            size: 34, color: Color(0xFF8A5A2B)),
                        const SizedBox(height: 8),
                        Text(
                          '添加书籍',
                          style: TextStyle(
                            color: const Color(0xFF6B4A20),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(
                                color: Colors.white.withValues(alpha: 0.5),
                                blurRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 虚线边框画笔
class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x668A5A2B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dash = 6.0;
    const gap = 4.0;
    // 顶部
    var x = 4.0;
    while (x < size.width - 4) {
      canvas.drawLine(Offset(x, 4), Offset(x + dash, 4), paint);
      x += dash + gap;
    }
    // 底部
    x = 4.0;
    while (x < size.width - 4) {
      canvas.drawLine(
          Offset(x, size.height - 4), Offset(x + dash, size.height - 4), paint);
      x += dash + gap;
    }
    // 左
    var y = 4.0;
    while (y < size.height - 4) {
      canvas.drawLine(Offset(4, y), Offset(4, y + dash), paint);
      y += dash + gap;
    }
    // 右
    y = 4.0;
    while (y < size.height - 4) {
      canvas.drawLine(
          Offset(size.width - 4, y), Offset(size.width - 4, y + dash), paint);
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
