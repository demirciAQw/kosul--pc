import 'anlik.dart';

abstract interface class AnlikRepository {
  /// Her değişiklikte yeniden yayılır; ilişkiler (etiket, kişi, bağ) içindedir.
  Stream<List<AnlikNote>> watchNotes();
  Future<List<AnlikNote>> allNotes();
  Future<AnlikNote?> findNote(String id);

  /// Yeni etiket ve kişilerle birlikte notu tek işlemde yazar. Notun etiket,
  /// kişi ve bağları verilen kümelerle birebir değiştirilir. [source]: elle
  /// eklenen etiket ve kişilerin kaynağı (`ben` ya da `claude`).
  Future<void> commit({
    required AnlikNote note,
    List<Tag> newTags = const [],
    List<Person> newPeople = const [],
    String source = Source.ben,
  });
  Future<void> deleteNote(String id);

  /// Notu soru kartına bağlar / bağı kaldırır (notun kalanına dokunmaz).
  Future<void> linkNoteToCard(String noteId, String cardId, {String source = Source.ben});
  Future<void> unlinkNoteFromCard(String noteId, String cardId);

  Stream<List<Tag>> watchTags();
  Future<List<Tag>> allTags();
  Future<void> saveTag(Tag tag);

  /// [from] etiketini [into] içine katar: notlar ve kartlar [into]'ya geçer,
  /// alt etiketler [into]'nun altına taşınır, sonra [from] kalkar.
  Future<void> mergeTags(String from, String into);

  Stream<List<Person>> watchPeople();
  Future<List<Person>> allPeople();
  Future<void> savePerson(Person person);

  /// Kart → etiket kimlikleri.
  Stream<Map<String, Set<String>>> watchCardTags();
  Future<void> setCardTags(String cardId, Set<String> tagIds, {String source = Source.ben});
}
