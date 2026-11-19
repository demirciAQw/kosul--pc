import '../../features/question_bank/domain/question_card.dart';

/// Klavyeyle hızlı optik girişinin mantığı (saf Dart).
///
/// İki kip:
///  - **şık**: A–E işaretlenen şıktır. Cevap anahtarı varsa durum kendiliğinden
///    çıkar (anahtarla aynı → doğru, değilse yanlış). Boşluk ya da `-` boş,
///    Enter anahtarla aynı (doğru) sayar.
///  - **durum**: D doğru, Y yanlış, B boş (anahtar gerekmez).
/// Her tuştan sonra imleç sonraki soruya geçer. Geri tuşu bir soru geri gider
/// ve onun işaretini siler. İşaretsiz soru doğru sayılır.
enum EntryMode { choice, status }

/// "ABCDE abcd" gibi bir metinden cevap anahtarı: yalnızca A–E harfleri, sırayla.
List<String> parseAnswerKey(String text) => [
      for (final ch in text.toUpperCase().split(''))
        if ('ABCDE'.contains(ch) && ch.trim().isNotEmpty) ch,
    ];

class OpticEntry {
  OpticEntry({
    required this.total,
    Map<int, QuestionStatus> initial = const {},
    List<String> answerKey = const [],
    EntryMode? mode,
  })  : assert(total >= 1),
        answerKey = List.unmodifiable(answerKey),
        mode = mode ?? (answerKey.isEmpty ? EntryMode.status : EntryMode.choice),
        _status = {
          for (final e in initial.entries)
            if (e.key >= 1 && e.key <= total && e.value != QuestionStatus.correct) e.key: e.value,
        };

  final int total;
  List<String> answerKey;
  EntryMode mode;

  /// 1 tabanlı soru numarası; son sorudan sonra son soruda kalır.
  int cursor = 1;

  final Map<int, QuestionStatus> _status;
  final Map<int, String> _given = {};

  /// Yalnızca yanlış ve boşlar (optik sonucu).
  Map<int, QuestionStatus> get marks => Map.unmodifiable(_status);

  /// Şıkla girilen cevaplar (yanlışlarda işaretlenen şık).
  Map<int, String> get given => Map.unmodifiable(_given);

  String? keyOf(int no) => no >= 1 && no <= answerKey.length ? answerKey[no - 1] : null;

  int get wrong => _status.values.where((s) => s == QuestionStatus.wrong).length;
  int get blank => _status.values.where((s) => s == QuestionStatus.blank).length;
  int get correct => total - wrong - blank;
  double get net => correct - wrong / 4;

  void setKey(List<String> key) {
    answerKey = List.unmodifiable(key);
    if (key.isNotEmpty && mode == EntryMode.status) mode = EntryMode.choice;
    if (key.isEmpty) mode = EntryMode.status;
  }

  void toggleMode() {
    if (mode == EntryMode.status) {
      if (answerKey.isNotEmpty) mode = EntryMode.choice;
    } else {
      mode = EntryMode.status;
    }
  }

  void select(int no) => cursor = no.clamp(1, total);

  void move(int delta) => cursor = (cursor + delta).clamp(1, total);

  void _set(int no, QuestionStatus? s, {String? letter}) {
    if (s == null || s == QuestionStatus.correct) {
      _status.remove(no);
    } else {
      _status[no] = s;
    }
    if (letter == null) {
      _given.remove(no);
    } else {
      _given[no] = letter;
    }
  }

  void _advance() {
    if (cursor < total) cursor++;
  }

  /// Bir tuşa basıldı. Tanınmayan tuş false döner (olay yutulmaz).
  /// [key]: "A".."E", "D", "Y", "B", " ", "-", "Enter", "Backspace".
  bool press(String key) {
    final k = key.length == 1 ? key.toUpperCase() : key;
    if (k == 'Backspace') {
      if (cursor > 1) cursor--;
      _set(cursor, null);
      return true;
    }
    if (k == ' ' || k == '-') {
      _set(cursor, QuestionStatus.blank);
      _advance();
      return true;
    }
    if (k == 'Enter') {
      _set(cursor, null);
      _advance();
      return true;
    }
    if (mode == EntryMode.choice && 'ABCDE'.contains(k) && k.length == 1) {
      final right = keyOf(cursor);
      if (right == null) return false; // anahtar yok: şık anlamsız
      _set(cursor, k == right ? null : QuestionStatus.wrong, letter: k == right ? null : k);
      _advance();
      return true;
    }
    if (mode == EntryMode.status && 'DYB'.contains(k) && k.length == 1) {
      _set(cursor, switch (k) { 'Y' => QuestionStatus.wrong, 'B' => QuestionStatus.blank, _ => null });
      _advance();
      return true;
    }
    return false;
  }
}
