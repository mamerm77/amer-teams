import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/office_text.dart';

// Fixtures written by python-docx, openpyxl and python-pptx (real Office Open XML files).
void main() {
  test('Word: headings and paragraphs in order, Arabic intact', () {
    final p = OfficeText.read('a.docx', File('test/fixtures/sample.docx').readAsBytesSync()) as DocPreview;
    expect(p.paras.map((e) => e.$2), ['Fibre rollout plan', 'Phase one covers Abu Dhabi.', 'سيبدأ التنفيذ في يناير']);
    expect(p.paras.first.$1, 'Heading1');
  });
  test('Excel: every sheet, shared strings, numbers and gaps in columns', () {
    final p = OfficeText.read('a.xlsx', File('test/fixtures/sample.xlsx').readAsBytesSync()) as SheetPreview;
    expect(p.sheets.map((s) => s.$1), ['Budget', 'Second']);
    expect(p.sheets.first.$2[0], ['Item', 'Cost']);
    expect(p.sheets.first.$2[1], ['ROADM', '125000']);
    expect(p.sheets.first.$2[2], ['', '', '', 'note']);
  });
  test('PowerPoint: slides in order with their text', () {
    final p = OfficeText.read('a.pptx', File('test/fixtures/sample.pptx').readAsBytesSync()) as SlidesPreview;
    expect(p.slides, [['Strategy 2027', 'Point about Strategy 2027'], ['Next steps', 'Point about Next steps']]);
  });
  test('Plain text and support check', () {
    expect((OfficeText.read('n.csv', Uint8List.fromList('a,b\n1,2'.codeUnits)) as TextPreview).text, 'a,b\n1,2');
    expect(OfficeText.canPreview('Plan.PDF'), isTrue); expect(OfficeText.canPreview('x.exe'), isFalse);
  });
}
