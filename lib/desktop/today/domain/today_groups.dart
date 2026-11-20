import '../../../features/question_bank/domain/question_bank.dart';

/// Bir konudaki bugün tekrar edilecek sorular.
class TopicGroup {
  const TopicGroup(this.title, this.reviews);
  final String title;
  final List<DueReview> reviews;
  int get count => reviews.length;
}

/// Bir dersin (ör. "TYT Matematik") bugünkü tekrarları, konulara bölünmüş.
class SubjectGroup {
  const SubjectGroup(this.subject, this.topics);
  final String subject;
  final List<TopicGroup> topics;
  int get count => topics.fold(0, (n, t) => n + t.count);
}

const noTopicTitle = 'Konusu yok';

/// Tekrarı gelen soruları ders → konu olarak gruplar. Çok sorusu olan ders ve
/// konu önde; konu içinde en eski vadesi gelen soru önde. [topicTitle] kartın
/// konu adını verir (boşsa "Konusu yok").
List<SubjectGroup> groupDueReviews(
  List<DueReview> due,
  String? Function(DueReview) topicTitle,
) {
  final bySubject = <String, Map<String, List<DueReview>>>{};
  for (final r in due) {
    final title = (topicTitle(r) ?? '').trim();
    bySubject.putIfAbsent(r.card.subject, () => {}).putIfAbsent(title.isEmpty ? noTopicTitle : title, () => []).add(r);
  }
  final subjects = [
    for (final s in bySubject.entries)
      SubjectGroup(s.key, [
        for (final t in s.value.entries)
          TopicGroup(t.key, [...t.value]..sort((a, b) => a.state.dueAt.compareTo(b.state.dueAt))),
      ]..sort(_byCountThenName)),
  ];
  subjects.sort((a, b) {
    final c = b.count.compareTo(a.count);
    return c != 0 ? c : a.subject.compareTo(b.subject);
  });
  return subjects;
}

int _byCountThenName(TopicGroup a, TopicGroup b) {
  final c = b.count.compareTo(a.count);
  return c != 0 ? c : a.title.compareTo(b.title);
}

/// Vadesi [now]'dan kaç gün önceydi (bugün vadeli = 0). Gün başına göre.
int overdueDays(DateTime dueAt, DateTime now) {
  final d = DateTime(dueAt.year, dueAt.month, dueAt.day);
  final n = DateTime(now.year, now.month, now.day);
  final days = n.difference(d).inDays;
  return days < 0 ? 0 : days;
}
