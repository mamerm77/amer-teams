# File previews with comments

Files are end-to-end encrypted, so no server can render them. Tapping a file in a chat decrypts it **on this device** and opens a preview.

| Type | Preview |
|---|---|
| PDF | Full rendering with pdfium (`pdfrx`): pages, zoom, text selection |
| Word (.docx) | Paragraphs and headings in order (Arabic and right-to-left text intact) |
| Excel (.xlsx) | Every sheet as a tab; shared strings, numbers, empty columns kept in place; first 500 rows a sheet |
| PowerPoint (.pptx) | Each slide's title and text, in slide order |
| Text, CSV, Markdown, JSON, YAML, logs | As text (first 400 KB) |
| Images | Already previewed in the chat |

**Comments** sit beside the preview (below it on a phone). They are replies in the file's own Matrix thread, so they are end-to-end encrypted and also show in the chat's thread view.

Tested: `app/test/office_text_test.dart` reads real files written by python-docx, openpyxl and python-pptx.

## Open gaps
- Office previews show the content, not the layout: no fonts, images, charts or formulas (values only where Excel saved them).
- Legacy .doc, .xls and .ppt aren't previewed.
- Comments are on the file as a whole, not anchored to a page or cell.
