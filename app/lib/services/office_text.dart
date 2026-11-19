import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// On-device previews of Office files (docs/FILE_PREVIEWS.md). Files are end-to-end encrypted, so the server cannot
/// render them; this reads the Office Open XML inside the decrypted file and gives a faithful text view:
/// Word paragraphs and headings, every Excel sheet as a table, each PowerPoint slide's text in order.
sealed class OfficePreview {}
class DocPreview extends OfficePreview { final List<(String style, String text)> paras; DocPreview(this.paras); }
class SheetPreview extends OfficePreview { final List<(String name, List<List<String>> rows)> sheets; SheetPreview(this.sheets); }
class SlidesPreview extends OfficePreview { final List<List<String>> slides; SlidesPreview(this.slides); }
class TextPreview extends OfficePreview { final String text; TextPreview(this.text); }

class OfficeText {
  static const kinds = {'docx', 'xlsx', 'pptx', 'txt', 'csv', 'md', 'json', 'log', 'xml', 'yaml', 'yml'};
  static String ext(String name) => name.contains('.') ? name.split('.').last.toLowerCase() : '';
  static bool canPreview(String name) => kinds.contains(ext(name)) || ext(name) == 'pdf';

  static OfficePreview read(String name, Uint8List bytes, {int maxRows = 500}) {
    final e = ext(name);
    if (!{'docx', 'xlsx', 'pptx'}.contains(e)) return TextPreview(utf8.decode(bytes.length > 400000 ? bytes.sublist(0, 400000) : bytes, allowMalformed: true));
    final z = ZipDecoder().decodeBytes(bytes);
    XmlDocument? x(String path) { final f = z.findFile(path); return f == null ? null : XmlDocument.parse(utf8.decode(f.readBytes()!)); }
    switch (e) {
      case 'docx':
        final d = x('word/document.xml'); if (d == null) throw const FormatException('Not a Word document');
        return DocPreview([for (final p in d.findAllElements('w:p'))
          (p.findAllElements('w:pStyle').firstOrNull?.getAttribute('w:val') ?? '', p.findAllElements('w:t').map((t) => t.innerText).join())]
          .where((p) => p.$2.trim().isNotEmpty).toList());
      case 'xlsx':
        final shared = [for (final si in x('xl/sharedStrings.xml')?.findAllElements('si') ?? const <XmlElement>[]) si.findAllElements('t').map((t) => t.innerText).join()];
        final wb = x('xl/workbook.xml'); final rels = x('xl/_rels/workbook.xml.rels');
        final target = {for (final r in rels?.findAllElements('Relationship') ?? const <XmlElement>[]) r.getAttribute('Id'): r.getAttribute('Target')};
        final out = <(String, List<List<String>>)>[];
        for (final s in wb?.findAllElements('sheet') ?? const <XmlElement>[]) {
          var t = target[s.getAttribute('r:id')] ?? ''; t = t.startsWith('/') ? t.substring(1) : 'xl/$t';
          final sh = x(t); if (sh == null) continue;
          final rows = <List<String>>[];
          for (final r in sh.findAllElements('row').take(maxRows)) {
            final row = <String>[];
            for (final c in r.findElements('c')) {
              final col = _col(c.getAttribute('r') ?? ''); while (row.length < col) { row.add(''); }
              final v = c.findElements('v').firstOrNull?.innerText ?? c.findAllElements('t').map((t) => t.innerText).join();
              row.add(c.getAttribute('t') == 's' ? (int.tryParse(v) != null && int.parse(v) < shared.length ? shared[int.parse(v)] : v) : v);
            }
            rows.add(row);
          }
          out.add((s.getAttribute('name') ?? 'Sheet', rows));
        }
        return SheetPreview(out);
      default:
        final names = z.files.map((f) => f.name).where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n)).toList()
          ..sort((a, b) => int.parse(RegExp(r'\d+').allMatches(a).last.group(0)!).compareTo(int.parse(RegExp(r'\d+').allMatches(b).last.group(0)!)));
        return SlidesPreview([for (final n in names) [for (final p in x(n)!.findAllElements('a:p')) p.findAllElements('a:t').map((t) => t.innerText).join()].where((t) => t.trim().isNotEmpty).toList()]);
    }
  }

  /// "C7" -> 2 (zero-based column index).
  static int _col(String ref) { var n = 0; for (final ch in ref.codeUnits) { if (ch < 65 || ch > 90) break; n = n * 26 + (ch - 64); } return n == 0 ? 0 : n - 1; }
}
