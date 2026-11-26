import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/palette.dart';
import 'welcome_providers.dart';

class _Page {
  const _Page(this.icon, this.color, this.title, this.text);
  final IconData icon;
  final Color color;
  final String title;
  final String text;
}

const _pages = [
  _Page(
    Icons.add_a_photo_outlined,
    KocumColors.blue,
    'Soruyu çek, hatayı yakala',
    'Yanlış yaptığın soruyu fotoğrafla. Koçum metni okur, konuyu bulur ve '
        'seni doğru zamanda tekrara çağırır.',
  ),
  _Page(
    Icons.bolt_rounded,
    KocumColors.amber,
    'Aklına gelen her şey: Anlık',
    'Kısa not yaz, ((etiket)) ve @kişi ile bağla. Uyku saatini de buradan '
        'kaydedersin. Her şey tek yerde aranır.',
  ),
  _Page(
    Icons.insights_outlined,
    KocumColors.green,
    'Deneme ve analiz',
    'Denemelerini ve karneni ekle; zayıf konularını, hata türlerini ve '
        'ilerlemeni gör.',
  ),
  _Page(
    Icons.lock_outline_rounded,
    KocumColors.grey700,
    'Verin senin telefonunda',
    'Hesap yok, bulut yok. İstersen aynı Wi-Fi\'daki bilgisayarına eşitlersin: '
        'Ayarlar → Araçlar → Bilgisayarla eşitle.',
  ),
];

/// İlk açılışta gösterilen hoş geldin ekranı (kaydırılır; "Geç" her yerde var).
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key, this.onDone});

  /// Boşsa görüldü olarak kaydedilir.
  final VoidCallback? onDone;

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() {
    final onDone = widget.onDone;
    if (onDone != null) {
      onDone();
    } else {
      ref.read(welcomeSeenProvider.notifier).markSeen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _index == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('welcome-skip'),
                onPressed: last ? null : _done,
                child: Text(last ? '' : 'Geç'),
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset('assets/icon/logo.png', width: 88, height: 88),
            ),
            const SizedBox(height: 16),
            Text('Koçum\'a hoş geldin', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final p = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: p.color.withValues(alpha: 0.14),
                          child: Icon(p.icon, size: 36, color: p.color),
                        ),
                        const SizedBox(height: 20),
                        Text(p.title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 10),
                        Text(p.text, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _index ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: i == _index ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('welcome-next'),
                  onPressed: last
                      ? _done
                      : () => _controller.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                  child: Text(last ? 'Başla' : 'İleri'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hoş geldin ekranı görülmediyse uygulamanın önüne koyar. Yüklenirken boş
/// zemin gösterir (ana ekran bir an görünüp kaybolmasın).
class WelcomeGate extends ConsumerWidget {
  const WelcomeGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seen = ref.watch(welcomeSeenProvider);
    return seen.when(
      loading: () => const Scaffold(body: SizedBox.shrink()),
      error: (_, _) => child,
      data: (done) => done ? child : const WelcomeScreen(),
    );
  }
}
