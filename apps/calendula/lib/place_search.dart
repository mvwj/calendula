const _accentGroups = {
  'a': 'áàâäãåāăą',
  'c': 'čćç',
  'd': 'ďđ',
  'e': 'éěèêëēę',
  'i': 'íìîïī',
  'l': 'ĺľł',
  'n': 'ňńñ',
  'o': 'óòôöõøō',
  'r': 'řŕ',
  's': 'šśş',
  't': 'ťţ',
  'u': 'úůùûüū',
  'y': 'ýÿ',
  'z': 'žźż',
};
final _accents = {
  for (final g in _accentGroups.entries)
    for (final code in g.value.runes) code: g.key,
};

/// Local Czech/Latin search; combining and precomposed accents behave alike.
String foldPlace(String text) {
  final value = StringBuffer();
  var space = true;
  for (final code in text.toLowerCase().runes) {
    if (code >= 0x0300 && code <= 0x036f) continue;
    final plain = (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
    final accent = _accents[code];
    if (plain || accent != null) {
      value.write(accent ?? String.fromCharCode(code));
      space = false;
    } else if (!space) {
      value.write(' ');
      space = true;
    }
  }
  return value.toString().trim();
}

class StopSearch {
  final List<String> names;
  late final Map<String, String> folded = {
    for (final n in names) n: foldPlace(n),
  };
  static const aliases = <String, List<String>>{
    'Hlavní nádraží': [
      'main station',
      'central station',
      'prague main station',
      'hlavni nadrazi',
    ],
    'Terminál 1': [
      'airport',
      'prague airport',
      'terminal 1',
      'vaclav havel airport',
    ],
    'Terminál 2': [
      'airport',
      'prague airport',
      'terminal 2',
      'vaclav havel airport',
    ],
    'Staroměstská': ['old town', 'old town square'],
    'Malostranská': ['lesser town', 'little quarter'],
    'Zoo Praha - Troja': ['prague zoo', 'zoo'],
    'Nemocnice Motol': ['motol hospital'],
    'Můstek': ['wenceslas square'],
  };
  StopSearch(Iterable<String> values) : names = values.toSet().toList()..sort();
  List<String> search(String query, {int limit = 12}) {
    final q = foldPlace(query);
    if (q.isEmpty) return [];
    final words = q.split(' '), hits = <(String, int)>[];
    for (final name in names) {
      final keys = [folded[name]!, ...?aliases[name]];
      var score = 100;
      for (final key in keys) {
        final rank = key == q
            ? 0
            : key.startsWith(q)
            ? 1
            : key.split(' ').any((w) => w.startsWith(q))
            ? 2
            : words.every((w) => key.contains(w))
            ? 3
            : 100;
        if (rank < score) score = rank;
      }
      if (score < 100) hits.add((name, score));
    }
    hits.sort((a, b) {
      final rank = a.$2.compareTo(b.$2);
      return rank == 0 ? a.$1.compareTo(b.$1) : rank;
    });
    return hits.take(limit).map((h) => h.$1).toList();
  }

  String? resolve(String value) {
    if (names.contains(value.trim())) return value.trim();
    final q = foldPlace(value);
    if (q.isEmpty) return null;
    final exact = names
        .where(
          (name) => folded[name] == q || (aliases[name]?.contains(q) ?? false),
        )
        .toList();
    return exact.length == 1 ? exact.single : null;
  }
}
