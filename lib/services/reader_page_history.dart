import 'dart:collection';

/// A committed page boundary in one layout revision.
///
/// Keys are owned by the reader (for example, item/source offsets). A different
/// layout must use a cleared history rather than reinterpret existing keys.
class ReaderPageSlice {
  final String firstKey;
  final String lastKey;

  const ReaderPageSlice(this.firstKey, this.lastKey);
}

/// Remembers visited cuts so a backward turn can reuse the forward page.
///
/// A cut is immutable once remembered. Conflicting cuts or links throw instead
/// of silently changing an already visited page. Capacity eviction drops only
/// the evicted page and its incident links; it never joins its neighbours.
class ReaderPageHistory {
  final int maxEntries;
  final _pages = LinkedHashMap<String, ReaderPageSlice>();
  final _previous = <String, String>{};
  final _next = <String, String>{};

  ReaderPageHistory({this.maxEntries = 256}) {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'Must be positive');
    }
  }

  ReaderPageSlice? pageAt(String firstKey) => _pages[firstKey];

  ReaderPageSlice? previousOf(String firstKey) {
    final previous = _previous[firstKey];
    return previous == null ? null : _pages[previous];
  }

  ReaderPageSlice? nextOf(String firstKey) {
    final next = _next[firstKey];
    return next == null ? null : _pages[next];
  }

  ReaderPageSlice remember(String firstKey, String lastKey) {
    final previous = _pages[firstKey];
    if (previous != null) {
      if (previous.lastKey != lastKey) {
        throw StateError('A remembered page cut cannot change within one layout');
      }
      return previous;
    }
    final page = ReaderPageSlice(firstKey, lastKey);
    _pages[firstKey] = page;
    if (_pages.length > maxEntries) _forget(_pages.keys.first);
    return page;
  }

  /// Connects two remembered pages in the direction of an actual user turn.
  void link(String fromFirst, String toFirst, int direction) {
    if (direction != -1 && direction != 1) {
      throw ArgumentError.value(direction, 'direction', 'Expected -1 or 1');
    }
    if (fromFirst == toFirst) {
      throw ArgumentError('A page cannot link to itself');
    }
    if (!_pages.containsKey(fromFirst) || !_pages.containsKey(toFirst)) {
      throw StateError('Both pages must be remembered before linking');
    }
    final before = direction > 0 ? fromFirst : toFirst;
    final after = direction > 0 ? toFirst : fromFirst;
    final oldNext = _next[before], oldPrevious = _previous[after];
    if (oldNext != null && oldNext != after || oldPrevious != null && oldPrevious != before) {
      throw StateError('A remembered page already has a different neighbour');
    }
    // The keys themselves carry no ordering contract. Reject a contradictory
    // cycle before changing either direction of the adjacency map.
    String? cursor = after;
    while (cursor != null) {
      if (cursor == before) throw StateError('Page links must not form a cycle');
      cursor = _next[cursor];
    }
    _next[before] = after;
    _previous[after] = before;
  }

  void clear() {
    _pages.clear();
    _previous.clear();
    _next.clear();
  }

  void _forget(String firstKey) {
    _pages.remove(firstKey);
    final previous = _previous.remove(firstKey), next = _next.remove(firstKey);
    if (previous != null) _next.remove(previous);
    if (next != null) _previous.remove(next);
  }
}
