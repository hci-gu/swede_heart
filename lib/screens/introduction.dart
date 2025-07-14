import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

class IntroductionScreen extends StatelessWidget {
  const IntroductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Introduction')),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 32),
            const Center(child: Text('Välkommen till Swede Heart studien')),
            const SizedBox(height: 16),
            Center(
              child: CupertinoButton.filled(
                onPressed: () {
                  context.goNamed('login');
                },
                child: const Text('Logga in'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
