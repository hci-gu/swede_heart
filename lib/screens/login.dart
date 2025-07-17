import 'package:flutter/cupertino.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:personnummer/personnummer.dart';
import 'package:swede_heart/state/auth.dart';
import 'package:swede_heart/theme.dart';
import 'package:swede_heart/widgets/consent_modal.dart';
import 'package:swede_heart/widgets/personal_number_input.dart';

class LoginScreen extends HookConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ValueNotifier<bool> canProceed = useState(false);
    final controller = useTextEditingController();

    useEffect(() {
      void listener() {
        canProceed.value = Personnummer.valid(controller.text);
      }

      controller.addListener(listener);
      return () => controller.removeListener(listener);
    }, [controller.text]);

    return AppScaffold(
      title: 'Logga in',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Logga in med ditt personnummer'),
          AppTheme.spacer2x,
          PersonalNumberInput(controller: controller),
          AppTheme.spacer2x,
          CupertinoButton.filled(
            onPressed: canProceed.value
                ? () async {
                    bool? consented = await showCupertinoModalPopup<bool>(
                      context: context,
                      builder: (BuildContext context) => const ConsentModal(),
                    );
                    if (consented == null || !consented) {
                      return;
                    }
                    if (context.mounted) {
                      await ref
                          .read(authProvider.notifier)
                          .signup(controller.text);
                    }
                  }
                : null,
            child: const Text('Logga in'),
          ),
        ],
      ),
    );
  }
}
