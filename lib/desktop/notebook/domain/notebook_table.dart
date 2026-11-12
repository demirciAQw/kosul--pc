import '../../../core/text/turkish_text.dart';
import '../../../features/question_bank/domain/question_card.dart';

/// Defter tablosunun sütunları (sıralama ölçütü olarak da).
enum NotebookColumn {
  date('Tarih'),
  subject('Ders'),
  topic('Konu'),
  source('Kitap / kaynak'),
  status('Durum'),
  reason('Neden');

  const NotebookColumn(this.label);
  final String label;
}

/// Tablodaki bir satır: kart ve ekranda gösterilen türetilmiş alanlar.
class NotebookRow {
  NotebookRow({
    required this.card,
    this.topic = '',
    required this.source,
    this.searchable = '',
    this.deletedOnPhone = false,
  }) : haystack = normalizeTr([
          card.subject,
          topic,
          source,
          card.locationText,
          card.reasonText ?? '',
          card.note ?? '',
          card.solutionText ?? '',
          searchable,
        ].join(' '));

  final QuestionCard card;
  final String topic; // MEB konusu, elle yazılan ya da otomatik; yoksa boş
  final String source; // kitap adı ya da kaynak adı
  final String searchable; // fotoğraftan okunan metin
  final bool deletedOnPhone;

  /// Aramada taranan, katlanmış metin.
  final String haystack;

  String get reason => card.reasonText ?? '';
}

class NotebookQuery {
  const NotebookQuery({
    this.text = '',
    this.subject,
    this.statuses = const {},
    this.source,
    this.reason,
    this.sort = NotebookColumn.date,
    this.ascending = false,
  });

  final String text;
  final String? subject;
  final Set<QuestionStatus> statuses; // boş: hepsi
  final String? source;
  final MistakeReason? reason;
  final NotebookColumn sort;
  final bool ascending;

  bool get isFiltered =>
      text.trim().isNotEmpty || subject != null || statuses.isNotEmpty || source != null || reason != null;

  NotebookQuery copyWith({
    String? text,
    String? Function()? subject,
    Set<QuestionStatus>? statuses,
    String? Function()? source,
    MistakeReason? Function()? reason,
    NotebookColumn? sort,
    bool? ascending,
  }) =>
      NotebookQuery(
        text: text ?? this.text,
        subject: subject == null ? this.subject : subject(),
        statuses: statuses ?? this.statuses,
        source: source == null ? this.source : source(),
        reason: reason == null ? this.reason : reason(),
        sort: sort ?? this.sort,
        ascending: ascending ?? this.ascending,
      );

  /// Aynı sütuna yeniden basınca yön değişir; yeni sütun tarihte yeniden
  /// eskiye, metinde A'dan Z'ye başlar.
  NotebookQuery sortBy(NotebookColumn column) => column == sort
      ? copyWith(ascending: !ascending)
      : copyWith(sort: column, ascending: column != NotebookColumn.date);

  /// Filtreler temizlenir, sıralama kalır.
  NotebookQuery cleared() => NotebookQuery(sort: sort, ascending: ascending);
}

/// Filtreler ve sıralama. Eşitlikte yeni kayıt önce gelir.
List<NotebookRow> applyNotebookQuery(List<NotebookRow> rows, NotebookQuery q) {
  final words = normalizeTr(q.text).split(' ').where((w) => w.isNotEmpty).toList();
  final out = [
    for (final r in rows)
      if ((q.subject == null || r.card.subject == q.subject) &&
          (q.statuses.isEmpty || q.statuses.contains(r.card.status)) &&
          (q.source == null || r.source == q.source) &&
          (q.reason == null || r.card.reason == q.reason) &&
          words.every(r.haystack.contains))
        r,
  ];
  int text(String a, String b) => normalizeTr(a).compareTo(normalizeTr(b));
  int compare(NotebookRow a, NotebookRow b) => switch (q.sort) {
        NotebookColumn.date => a.card.createdAt.compareTo(b.card.createdAt),
        NotebookColumn.subject => text(a.card.subject, b.card.subject),
        NotebookColumn.topic => text(a.topic, b.topic),
        NotebookColumn.source => text(a.source, b.source),
        NotebookColumn.status => a.card.status.index.compareTo(b.card.status.index),
        NotebookColumn.reason => text(a.reason, b.reason),
      };
  // Konu ya da neden sıralamasında boş olanlar yönden bağımsız olarak sonda.
  String? emptiable(NotebookRow r) => switch (q.sort) {
        NotebookColumn.topic => r.topic,
        NotebookColumn.reason => r.reason,
        _ => null,
      };
  out.sort((a, b) {
    final ea = emptiable(a), eb = emptiable(b);
    if (ea != null && eb != null && ea.isEmpty != eb.isEmpty) return ea.isEmpty ? 1 : -1;
    final c = compare(a, b);
    if (c != 0) return q.ascending ? c : -c;
    return b.card.createdAt.compareTo(a.card.createdAt);
  });
  return out;
}
