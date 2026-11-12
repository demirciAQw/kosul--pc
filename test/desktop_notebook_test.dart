import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/desktop/notebook/domain/notebook_table.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';

NotebookRow _row(
  String id, {
  String subject = 'TYT Matematik',
  QuestionStatus status = QuestionStatus.wrong,
  MistakeReason? reason,
  String topic = '',
  String source = 'Kitap',
  String searchable = '',
  int day = 1,
}) =>
    NotebookRow(
      card: QuestionCard(
        id: id,
        status: status,
        origin: QuestionOrigin.book,
        sourceName: source,
        subject: subject,
        difficulty: 5,
        reason: reason,
        createdAt: DateTime(2026, 11, day),
      ),
      topic: topic,
      source: source,
      searchable: searchable,
    );

List<String> _ids(List<NotebookRow> rows) => [for (final r in rows) r.card.id];

void main() {
  final rows = [
    _row('a', topic: 'Üslü İfadeler', day: 3),
    _row('b', subject: 'TYT Kimya', status: QuestionStatus.blank, topic: 'Entalpi', day: 5),
    _row('c', status: QuestionStatus.correct, source: 'Deneme 1', searchable: 'Buna göre ŞIKLARDAN hangisi', day: 4),
    _row('d', reason: MistakeReason.values.first, day: 2),
  ];

  test('varsayılan: yeniden eskiye', () {
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery())), ['b', 'c', 'a', 'd']);
  });

  test('filtreler birlikte çalışır', () {
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(subject: 'TYT Kimya'))), ['b']);
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(statuses: {QuestionStatus.wrong}))), ['a', 'd']);
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(source: 'Deneme 1'))), ['c']);
    expect(_ids(applyNotebookQuery(rows, NotebookQuery(reason: MistakeReason.values.first))), ['d']);
    expect(
      _ids(applyNotebookQuery(rows, const NotebookQuery(subject: 'TYT Matematik', statuses: {QuestionStatus.correct}))),
      ['c'],
    );
  });

  test('arama Türkçe harflere duyarsız; okunan metinde ve konuda da arar; tüm kelimeler gerekir', () {
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(text: 'şıklardan'))), ['c']);
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(text: 'USLU'))), ['a']);
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(text: 'kimya entalpi'))), ['b']);
    expect(_ids(applyNotebookQuery(rows, const NotebookQuery(text: 'kimya üslü'))), isEmpty);
  });

  test('konuya göre sıralamada konusu olmayanlar her iki yönde de sonda', () {
    const byTopic = NotebookQuery(sort: NotebookColumn.topic, ascending: true);
    expect(_ids(applyNotebookQuery(rows, byTopic)), ['b', 'a', 'c', 'd']);
    expect(_ids(applyNotebookQuery(rows, byTopic.copyWith(ascending: false))), ['a', 'b', 'c', 'd']);
  });

  test('sütun başlığı: aynı sütun yön değiştirir, yeni sütun varsayılan yönle başlar', () {
    const q = NotebookQuery();
    expect(q.sortBy(NotebookColumn.date).ascending, isTrue);
    final bySubject = q.sortBy(NotebookColumn.subject);
    expect([bySubject.sort, bySubject.ascending], [NotebookColumn.subject, true]);
    expect(bySubject.sortBy(NotebookColumn.subject).ascending, isFalse);
  });

  test('temizle: filtreler gider, sıralama kalır', () {
    const q = NotebookQuery(text: 'x', subject: 'TYT Kimya', sort: NotebookColumn.source, ascending: true);
    final c = q.cleared();
    expect([c.isFiltered, c.sort, c.ascending], [false, NotebookColumn.source, true]);
    expect(q.copyWith(subject: () => null).subject, isNull);
  });
}
