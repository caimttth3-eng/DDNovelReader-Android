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

  test('chapter number uses the narrow side while the name stays in the wide side', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(140, 8, 170, 32)]);
    final title = layout.chapterTitle('第42章 江湖再见');
    expect(title.chapterNumber, '第42章');
    expect(title.chapterName, '江湖再见');
    expect(title.numberRect!.right, 136);
    expect(title.nameRect.left, 174);
    expect(title.numberRect!.width, lessThan(title.nameRect.width));
    expect(layout.topArea, 40);
    expect(title.numberRect!.top, title.nameRect.top);
  });

  test('equal sides keep the name left and put the number right', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(188, 8, 212, 32)]);
    final title = layout.chapterTitle('Chapter IV: Return');
    expect(title.chapterNumber, 'Chapter IV');
    expect(title.chapterName, 'Return');
    expect(title.nameRect.left, 8);
    expect(title.numberRect!.left, 216);
  });

  test('corner cameras and absent cutouts keep the complete title on one side', () {
    final corner = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(0, 8, 40, 32)]).chapterTitle('第一章 开始');
    expect(corner.chapterNumber, isNull);
    expect(corner.numberRect, isNull);
    expect(corner.chapterName, '第一章 开始');
    expect(corner.nameRect.left, 44);
    final plain = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: EdgeInsets.zero)
      .chapterTitle('第一章 开始');
    expect(plain.chapterNumber, isNull);
    expect(plain.chapterName, '第一章 开始');
  });

  test('insufficient number space and unnumbered headings never create empty controls', () {
    final layout = ReaderHeaderLayout.compute(viewport: portrait, safeInsets: topSafe,
      cutouts: [const Rect.fromLTRB(48, 8, 80, 32)]);
    expect(layout.chapterTitle('第一章 开始').chapterNumber, isNull);
    for (final text in ['楔子', '第一章', 'Chapter IV', '']) {
      final title = layout.chapterTitle(text);
      expect(title.chapterNumber, isNull);
      expect(title.numberRect, isNull);
      expect(title.chapterName, text);
    }
  });

  test('chapter title parsing handles traditional digits and separators', () {
    final parts = ChapterTitleParts.split('第 壹佰 節：後續')!;
    expect(parts.number, '第 壹佰 節');
    expect(parts.name, '後續');
    expect(ChapterTitleParts.split('第一章——开端')!.name, '开端');
    expect(ChapterTitleParts.split('无编号的名字'), isNull);
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
