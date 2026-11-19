/// Data-loss prevention on this device (docs/PARTNERS.md): text going to a channel shared with another organisation is
/// checked here, before it is encrypted and leaves. The server cannot check it (it only sees ciphertext).
library;

class DlpHit { const DlpHit(this.kind, this.match); final String kind, match; }

bool _luhn(String d) {
  var sum = 0, alt = false;
  for (var i = d.length - 1; i >= 0; i--) {
    var n = d.codeUnitAt(i) - 48;
    if (alt) { n *= 2; if (n > 9) n -= 9; }
    sum += n; alt = !alt;
  }
  return sum % 10 == 0;
}

bool _iban(String s) {
  final t = s.replaceAll(' ', '').toUpperCase();
  if (t.length < 15 || t.length > 34) return false;
  final r = '${t.substring(4)}${t.substring(0, 4)}'.split('').map((c) { final u = c.codeUnitAt(0); return u >= 65 ? '${u - 55}' : c; }).join();
  var m = 0;
  for (final ch in r.split('')) { m = (m * 10 + int.parse(ch)) % 97; }
  return m == 1;
}

/// Card numbers (13–19 digits passing the Luhn check), IBANs (mod-97 check) and UAE Emirates ID numbers.
List<DlpHit> dlpScan(String text) {
  final out = <DlpHit>[];
  for (final m in RegExp(r'(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)').allMatches(text)) {
    final d = m.group(0)!.replaceAll(RegExp(r'[ -]'), '');
    if (d.length == 15 && d.startsWith('784')) continue;                      // an Emirates ID, reported below
    if (d.length >= 13 && d.length <= 19 && _luhn(d)) out.add(DlpHit('card number', m.group(0)!));
  }
  for (final m in RegExp(r'\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b').allMatches(text.toUpperCase())) {
    if (_iban(m.group(0)!)) out.add(DlpHit('bank account (IBAN)', m.group(0)!));
  }
  for (final m in RegExp(r'\b784-?\d{4}-?\d{7}-?\d\b').allMatches(text)) { out.add(DlpHit('Emirates ID number', m.group(0)!)); }
  return out;
}
