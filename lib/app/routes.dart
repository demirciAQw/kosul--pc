abstract final class AppRoutes {
  // Ana ekran ve alt gezinme sekmeleri (ana ekran çubukta yok: logoyla açılır)
  static const home = '/';
  static const books = '/books';
  static const notebook = '/notebook';
  static const mockExams = '/mock';
  static const insights = '/insights';
  static const anlikTab = '/anlik';
  static const tools = '/tools';
  static const practiceTest = '/tools/test';
  static const sendToComputer = '/tools/computer';
  static const claudeChanges = '/tools/degisiklikler';
  static const conflicts = '/tools/cakismalar';
  static const inkLab = '/tools/kalem';
  static const pdfLibrary = '/pdf';
  static String pdfReader(String id) => '/pdf/$id';

  // Tam ekran sayfalar
  static const newSession = '/session/new';
  static const activeSession = '/session/active';
  static String sessionResults(String id) => '/session/$id/results';
  static const newQuestion = '/questions/new';
  static const incompleteQuestions = '/questions/incomplete';
  static String question(String id) => '/questions/$id';
  static String editQuestion(String id) => '/questions/$id/edit';
  static const plan = '/plan';
  static const newPlan = '/plan/new';
  static const sessions = '/sessions';
  static const newNote = '/notes/new';
  static const newAnlik = '/anlik/yeni';
  static String anlik(String id) => '/anlik/not/$id';
  static const people = '/kisiler';
  static String person(String id) => '/kisiler/$id';
  static const tags = '/etiketler';
  static const settings = '/settings';
  static String note(String id) => '/notes/$id';
  static String book(String id) => '/books/$id';
  static String bookTest(String bookId, String nodeId) => '/books/$bookId/tests/$nodeId';
  static const review = '/review';
  static const newMockExam = '/mock/new';
  static const karneImport = '/mock/karne';
  static String mockExam(String id) => '/mock/$id';
  static String editMockExam(String id) => '/mock/$id/edit';
}
