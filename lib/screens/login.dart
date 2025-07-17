import 'package:flutter/cupertino.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:swede_heart/widgets/personal_number_input.dart';

class LoginScreen extends HookConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text('Login')),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 64.0),
        child: Column(
          children: [
            Text('Logga in med ditt personnummer'),
            const SizedBox(height: 16),
            PersonalNumberInput(controller: controller),
          ],
        ),
      ),
    );
  }
}
