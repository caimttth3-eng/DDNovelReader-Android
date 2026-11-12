import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_header_layout.dart';

void main() {
  const portrait = Size(400, 800);
  const topSafe = EdgeInsets.only(top: 40);
  test('a centred hole shares the top band and equal slots consistently use the left', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(188, 8, 212, 32)]);
    expect(layout.sharesCutoutBand, isTrue);
    expect(layout.topArea, 40);
    expect(layout.titleRect, const Rect.fromLTWH(8, 8, 176, 24));
    expect(layout.titleRect.overlaps(const Rect.fromLTRB(188, 8, 212, 32)), isFalse);
  });

  test('an offset camera chooses the wider unobstructed side', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(32, 8, 60, 36)]);
    expect(layout.titleRect.left, 64);
    expect(layout.titleRect.right, 392);
    expect(layout.topArea, 40);
  });

  test('multiple and overlapping cutouts are treated as a union', () {
    final holes = [const Rect.fromLTRB(80, 0, 130, 36), const Rect.fromLTRB(100, 4, 160, 40),
      const Rect.fromLTRB(290, 4, 320, 36)];
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe, cutouts: holes);
    expect(layout.titleRect.left, 164);
    expect(layout.titleRect.right, 286);
    for (final hole in holes) { expect(layout.titleRect.overlaps(hole), isFalse); }
  });

  test('round corners and side insets constrain the chosen slot', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(188, 8, 212, 32)], topLeftRadius: 24, topRightRadius: 30);
    expect(layout.titleRect.left, 24);
    expect(layout.titleRect.right, 184);
    expect(layout.titleRect.height, 24);
  });

  test('landscape side cutouts never turn into a large top spacer', () {
    final layout = ReaderHeaderLayout.compute(viewport: const Size(800, 400),
      safeInsets: const EdgeInsets.only(left: 34),
      cutouts: [const Rect.fromLTRB(0, 180, 34, 220)]);
    expect(layout.topArea, 24);
    expect(layout.titleRect.left, 34);
    expect(layout.titleRect.top, 0);
    expect(layout.sharesCutoutBand, isFalse);
  });

  test('visible system status icons force a safe row below the status band', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(188, 8, 212, 32)], statusBarVisible: true, statusBarTop: 56);
    expect(layout.titleRect.top, 56);
    expect(layout.topArea, 80);
    expect(layout.sharesCutoutBand, isFalse);
  });

  test('missing bounds use a compact safe row and do not guess a hole', () {
    final unknown = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: const EdgeInsets.only(top: 38));
    expect(unknown.titleRect, const Rect.fromLTWH(8, 38, 384, 24));
    expect(unknown.topArea, 62);
    expect(unknown.sharesCutoutBand, isFalse);
    expect(ReaderHeaderLayout.compute(viewport: portrait, safeInsets: EdgeInsets.zero).topArea, 24);
  });

  test('a full-width notch uses the safe fallback and rotated snapshots are rejected', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(0, 0, 400, 40)]);
    expect(layout.titleRect.top, 40);
    expect(layout.topArea, 64);
    expect(layout.sharesCutoutBand, isFalse);
    const snapshot = DisplayCutoutGeometry(viewport: portrait);
    expect(snapshot.matches(portrait), isTrue);
    expect(snapshot.matches(const Size(800, 400)), isFalse);
  });
}
