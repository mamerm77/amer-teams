import 'dart:convert';

/// Pre-mortem agent (docs/PREMORTEM.md): parse the agent's JSON, tolerating a Markdown fence around it.
class PreMortem {
  PreMortem(this.summary, this.risks);
  final String summary; final List<Map<String, String>> risks;
  static const _rank = {'high': 3, 'medium': 2, 'low': 1};
  int score(Map<String, String> r) => (_rank[r['likelihood']] ?? 1) * (_rank[r['impact']] ?? 1);

  static PreMortem parse(String answer) {
    final a = answer.indexOf('{'), b = answer.lastIndexOf('}');
    if (a < 0 || b <= a) throw const FormatException('The pre-mortem agent did not return a list of risks');
    final j = jsonDecode(answer.substring(a, b + 1)) as Map<String, dynamic>;
    final risks = [for (final r in (j['risks'] as List? ?? const []))
      if (r is Map && (r['risk'] ?? '').toString().trim().isNotEmpty) {for (final k in ['risk', 'why_it_fails', 'likelihood', 'impact', 'early_warning', 'mitigation']) k: '${r[k] ?? ''}'.trim()}];
    if (risks.isEmpty) throw const FormatException('The pre-mortem found no risks');
    final p = PreMortem('${j['summary'] ?? ''}', risks);
    p.risks.sort((x, y) => p.score(y).compareTo(p.score(x)));
    return p;
  }

  String toMessage() => '🔮 Pre-mortem: ${summary.isEmpty ? 'how this plan could fail' : summary}\n'
      '${[for (var i = 0; i < risks.length; i++) '${i + 1}. ${risks[i]['risk']} (likelihood ${risks[i]['likelihood']}, impact ${risks[i]['impact']})\n   Watch for: ${risks[i]['early_warning']}\n   Mitigation: ${risks[i]['mitigation']}'].join('\n')}';
}
