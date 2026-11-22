import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/anlik/presentation/anlik_screens.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/ink/presentation/ink_lab_page.dart';
import '../features/pdf/domain/pdf_engine.dart' show PdfBox;
import '../features/pdf/presentation/pdf_library_page.dart';
import '../features/pdf/presentation/pdf_reader_page.dart';
import '../features/pdf/presentation/pdf_solve_page.dart';
import '../features/ledger/presentation/ledger_screens.dart';
import '../features/home/home_screen.dart';
import '../features/library/presentation/book_detail_screen.dart';
import '../features/library/presentation/books_screen.dart';
import '../features/library/presentation/test_detail_screen.dart';
import '../features/mock_exam/domain/karne_import.dart';
import '../features/mock_exam/presentation/edit_mock_exam_screen.dart';
import '../features/mock_exam/presentation/karne_import_screen.dart';
import '../features/mock_exam/presentation/mock_exam_detail_screen.dart';
import '../features/mock_exam/presentation/mock_exams_screen.dart';
import '../features/notes/presentation/note_editor_screen.dart';
import '../features/planning/presentation/create_plan_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/planning/presentation/plan_screen.dart';
import '../features/question_bank/presentation/question_prefill.dart';
import '../features/question_bank/presentation/screens/add_question_screen.dart';
import '../features/question_bank/presentation/screens/incomplete_screen.dart';
import '../features/question_bank/presentation/screens/notebook_screen.dart';
import '../features/question_bank/presentation/screens/question_detail_screen.dart';
import '../features/question_bank/presentation/screens/review_screen.dart';
import '../features/study_session/presentation/screens/active_session_screen.dart';
import '../features/study_session/presentation/screens/session_history_screen.dart';
import '../features/study_session/presentation/screens/session_results_screen.dart';
import '../features/study_session/presentation/screens/session_setup_screen.dart';
import '../features/sync/presentation/send_to_computer_screen.dart';
import 'app_shell.dart';
import 'routes.dart';
import 'tablet.dart';
import '../features/notes/presentation/ink_notebook_screen.dart';
import '../features/notes/presentation/notebooks_screen.dart';
import '../features/tools/presentation/tools_screen.dart';
import '../features/tools/presentation/practice_test_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    observers: [tabletRouteObserver],
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.home,
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.anlikTab,
                builder: (context, state) => const AnlikScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.books,
                builder: (context, state) => const BooksScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.notebook,
                builder: (context, state) => const NotebookScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.mockExams,
                builder: (context, state) => const MockExamsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.insights,
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
        ],
      ),
      // Tam ekran sayfalar: alt çubuğun üstünde açılır. Sabit yollar (new,
      // incomplete) parametreli yollardan ÖNCE gelmeli.
      GoRoute(
        path: AppRoutes.newSession,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: SessionSetupScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.activeSession,
        builder: (context, state) => const ActiveSessionScreen(),
      ),
      GoRoute(
        path: '/session/:id/results',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: SessionResultsScreen(sessionId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.newQuestion,
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: AddQuestionScreen(prefill: state.extra as QuestionPrefill?),
        ),
      ),
      GoRoute(
        path: AppRoutes.incompleteQuestions,
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: const IncompleteQuestionsScreen(),
        ),
      ),
      GoRoute(
        path: '/questions/:id/edit',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: AddQuestionScreen(editCardId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/questions/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: QuestionDetailScreen(cardId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.newAnlik,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.notlar,
          child: AnlikEditorScreen(),
        ),
      ),
      GoRoute(
        path: '/anlik/not/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.notlar,
          child: AnlikEditorScreen(noteId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.people,
        builder: (context, state) =>
            const TabletFrame(selected: RailItem.notlar, child: PeopleScreen()),
      ),
      GoRoute(
        path: '/kisiler/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.notlar,
          child: PersonNotesScreen(personId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.tags,
        builder: (context, state) =>
            const TabletFrame(selected: RailItem.notlar, child: TagsScreen()),
      ),
      GoRoute(
        path: AppRoutes.plan,
        builder: (context, state) =>
            const TabletFrame(selected: RailItem.daha, child: PlanScreen()),
      ),
      GoRoute(
        path: AppRoutes.newPlan,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: CreatePlanScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.sessions,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: SessionHistoryScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.ayarlar,
          child: SettingsScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.tools,
        builder: (context, state) =>
            const TabletFrame(selected: RailItem.daha, child: ToolsScreen()),
      ),
      GoRoute(
        path: AppRoutes.practiceTest,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: PracticeTestScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.claudeChanges,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: ClaudeChangesScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.conflicts,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: ConflictsScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.inkLab,
        builder: (context, state) => const InkLabPage(),
      ),
      GoRoute(
        path: AppRoutes.pdfLibrary,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.kitaplik,
          child: PdfLibraryPage(),
        ),
      ),
      GoRoute(
        path: AppRoutes.notebooks,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.defterler,
          child: NotebooksScreen(),
        ),
      ),
      GoRoute(
        path: '/defter/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.defterler,
          child: InkNotebookScreen(notebookId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/pdf/:id',
        builder: (context, state) {
          final page = int.tryParse(state.uri.queryParameters['page'] ?? '');
          final parts = (state.uri.queryParameters['box'] ?? '')
              .split(',')
              .map(double.tryParse)
              .toList();
          final ok =
              page != null &&
              page >= 0 &&
              parts.length == 4 &&
              parts.every((v) => v != null && v.isFinite) &&
              parts[2]! > parts[0]! &&
              parts[3]! > parts[1]!;
          return TabletFrame(
            selected: RailItem.kitaplik,
            child: PdfReaderPage(
              documentId: state.pathParameters['id']!,
              initialPage: ok ? page : null,
              highlight: ok
                  ? PdfBox(parts[0]!, parts[1]!, parts[2]!, parts[3]!)
                  : null,
              questionId: ok ? state.uri.queryParameters['q'] : null,
            ),
          );
        },
        routes: [
          GoRoute(
            path: 'soru/:questionId',
            builder: (context, state) => PdfSolvePage(
              documentId: state.pathParameters['id']!,
              questionId: state.pathParameters['questionId']!,
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/soru/:questionId/coz',
        builder: (context, state) =>
            QuestionSolvePage(questionId: state.pathParameters['questionId']!),
      ),
      GoRoute(
        path: AppRoutes.sendToComputer,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: SendToComputerScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.newNote,
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: NoteEditorScreen(initialSubject: state.extra as String?),
        ),
      ),
      GoRoute(
        path: '/notes/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: NoteEditorScreen(noteId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/books/:id/tests/:nodeId',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: TestDetailScreen(
            bookId: state.pathParameters['id']!,
            nodeId: state.pathParameters['nodeId']!,
          ),
        ),
      ),
      GoRoute(
        path: '/books/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: BookDetailScreen(bookId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: AppRoutes.review,
        builder: (context, state) => const ReviewScreen(),
      ),
      GoRoute(
        path: AppRoutes.newMockExam,
        builder: (context, state) => const TabletFrame(
          selected: RailItem.daha,
          child: EditMockExamScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.karneImport,
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: KarneImportScreen(plan: state.extra! as KarneImportPlan),
        ),
      ),
      GoRoute(
        path: '/mock/:id/edit',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: EditMockExamScreen(examId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/mock/:id',
        builder: (context, state) => TabletFrame(
          selected: RailItem.daha,
          child: MockExamDetailScreen(examId: state.pathParameters['id']!),
        ),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
