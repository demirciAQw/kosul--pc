import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/library/presentation/books_screen.dart' show pdfsByBook;
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';

PdfDocumentRecord _d(String id, String title, String? bookId) => PdfDocumentRecord(
      id: id,
      sha256: id,
      title: title,
      pageCount: 10,
      fileName: '$id.pdf',
      bookId: bookId,
    );

void main() {
  test('iki PDF aynı kitaba bağlıysa liste sırasındaki ilki; bağsızlar yok', () {
    final m = pdfsByBook([_d('a', 'A', 'k1'), _d('b', 'B', 'k1'), _d('c', 'C', null), _d('d', 'D', 'k2')]);
    expect(m.keys.toSet(), {'k1', 'k2'});
    expect(m['k1']!.id, 'a');
    expect(m['k2']!.id, 'd');
  });
}
