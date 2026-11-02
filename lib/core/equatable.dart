/// Compares by [props], looking inside lists, maps and sets.
abstract class Equatable {
  const Equatable();

  List<Object?> get props;

  @override
  bool operator ==(Object other) => identical(this, other) || (other.runtimeType == runtimeType && other is Equatable && _same(props, other.props));

  @override
  int get hashCode => _hash(props);

  static bool _same(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_same(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_same(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is Set && b is Set) return a.length == b.length && a.containsAll(b);
    return a == b;
  }

  static int _hash(Object? value) => switch (value) {
    final List<Object?> list => Object.hashAll(list.map(_hash)),
    final Map<Object?, Object?> map => Object.hashAllUnordered(map.entries.map((e) => Object.hash(_hash(e.key), _hash(e.value)))),
    final Set<Object?> set => Object.hashAllUnordered(set.map(_hash)),
    _ => value.hashCode,
  };
}
