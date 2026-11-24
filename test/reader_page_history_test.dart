import 'package:flutter_test/flutter_test.dart';
import 'package:duoduo_langdu/services/reader_page_history.dart';

void main() {
  test('visited forward and backward cycles retain the original page cuts', () {
    final history = ReaderPageHistory();
    final a = history.remember('0/0', '0/40');
    final b = history.remember('0/41', '0/80');
    final c = history.remember('0/81', '1/20');
    history.link(a.firstKey, b.firstKey, 1);
    history.link(b.firstKey, c.firstKey, 1);

    for (var cycle = 0; cycle < 20; cycle++) {
      expect(history.nextOf(a.firstKey), same(b));
      expect(history.previousOf(c.firstKey), same(b));
      history.link(c.firstKey, b.firstKey, -1);
      history.link(b.firstKey, a.firstKey, -1);
      expect(history.remember(b.firstKey, b.lastKey), same(b));
      expect(history.pageAt(b.firstKey)!.lastKey, '0/80');
    }
    expect(history.previousOf(a.firstKey), isNull);
    expect(history.nextOf(c.firstKey), isNull);
  });

  test('an existing page cut cannot be silently replaced', () {
    final history = ReaderPageHistory();
    final a = history.remember('a', 'a-last');
    final b = history.remember('b', 'b-last');
    history.link('a', 'b', 1);
    expect(() => history.remember('a', 'different-last'), throwsStateError);
    expect(history.pageAt('a'), same(a));
    expect(history.nextOf('a'), same(b));
    expect(history.previousOf('b'), same(a));
  });

  test('conflicting neighbours and cycles leave both maps unchanged', () {
    final history = ReaderPageHistory();
    for (final key in ['a', 'b', 'c', 'd']) { history.remember(key, '$key-last'); }
    history.link('a', 'b', 1);
    history.link('b', 'c', 1);
    expect(() => history.link('a', 'd', 1), throwsStateError);
    expect(() => history.link('d', 'b', 1), throwsStateError);
    expect(() => history.link('c', 'a', 1), throwsStateError);
    expect(history.nextOf('a')!.firstKey, 'b');
    expect(history.previousOf('b')!.firstKey, 'a');
    expect(history.nextOf('b')!.firstKey, 'c');
    expect(history.previousOf('c')!.firstKey, 'b');
    expect(history.previousOf('a'), isNull);
    expect(history.nextOf('c'), isNull);
    expect(history.previousOf('d'), isNull);
    expect(history.nextOf('d'), isNull);
  });

  test('evicting a middle page disconnects its neighbours without joining them', () {
    final history = ReaderPageHistory(maxEntries: 3);
    history.remember('b', 'b-last');
    final a = history.remember('a', 'a-last');
    final c = history.remember('c', 'c-last');
    history.link('a', 'b', 1);
    history.link('b', 'c', 1);
    history.remember('d', 'd-last');
    expect(history.pageAt('b'), isNull);
    expect(history.pageAt('a'), same(a));
    expect(history.pageAt('c'), same(c));
    expect(history.nextOf('a'), isNull);
    expect(history.previousOf('c'), isNull);
    expect(history.previousOf('b'), isNull);
    expect(history.nextOf('b'), isNull);
    history.link('c', 'd', 1);
    expect(history.nextOf('c')!.firstKey, 'd');
    expect(history.previousOf('d'), same(c));
  });

  test('clear removes cuts and links before a different layout is remembered', () {
    final history = ReaderPageHistory();
    history.remember('a', 'old-last');
    history.remember('b', 'old-b-last');
    history.link('a', 'b', 1);
    history.clear();
    expect(history.pageAt('a'), isNull);
    expect(history.previousOf('b'), isNull);
    expect(history.nextOf('a'), isNull);
    expect(history.remember('a', 'new-last').lastKey, 'new-last');
    expect(history.nextOf('a'), isNull);
  });

  test('invalid capacity, directions and unknown page links are explicit errors', () {
    expect(() => ReaderPageHistory(maxEntries: 0), throwsArgumentError);
    final history = ReaderPageHistory();
    history.remember('a', 'a-last');
    expect(() => history.link('a', 'b', 0), throwsArgumentError);
    expect(() => history.link('a', 'a', 1), throwsArgumentError);
    expect(() => history.link('a', 'b', 1), throwsStateError);
    expect(history.nextOf('a'), isNull);
  });

  test('paragraph spacing makes backward greedy packing differ from forward cuts', () {
    // Nine 20px rows, then a real 12px paragraph gap before the tenth row.
    // A full page is 100px. Forward cuts are 0..4, 5..8, then 9.
    final rows = <({double top, double bottom})>[
      for (var i = 0; i < 9; i++) (top: i * 20.0, bottom: (i + 1) * 20.0),
      (top: 192, bottom: 212),
    ];
    const height = 100.0;
    final cuts = <({int first, int last})>[];
    for (var first = 0; first < rows.length;) {
      var last = first;
      while (last + 1 < rows.length && rows[last + 1].bottom - rows[first].top <= height) { last++; }
      cuts.add((first: first, last: last));
      first = last + 1;
    }
    expect(cuts, [(first: 0, last: 4), (first: 5, last: 8), (first: 9, last: 9)]);
    var greedyPrevious = cuts.last.first - 1;
    final previousEnd = greedyPrevious;
    while (greedyPrevious > 0 && rows[previousEnd].bottom - rows[greedyPrevious - 1].top <= height) {
      greedyPrevious--;
    }
    expect(greedyPrevious, 4, reason: 'Backward refilling repeats row 4 from the first page');
    expect(greedyPrevious, isNot(cuts[1].first));

    final history = ReaderPageHistory();
    for (final cut in cuts) { history.remember('${cut.first}', '${cut.last}'); }
    history.link('0', '5', 1);
    history.link('5', '9', 1);
    expect(history.previousOf('9')!.firstKey, '5');
    expect(history.previousOf('9')!.lastKey, '8');
  });
}
