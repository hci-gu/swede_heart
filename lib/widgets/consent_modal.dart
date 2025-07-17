import 'package:flutter/cupertino.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:swede_heart/theme.dart';

class ConsentModal extends HookWidget {
  const ConsentModal({super.key});

  @override
  Widget build(BuildContext context) {
    ValueNotifier<bool> consent = useState(false);

    return CupertinoAlertDialog(
      title: const Text('Ge ditt samtycke'),
      content: Column(
        children: [
          Text(
            'Genom att fortsätta går du med på att din stegdata används i forskningssyfte.',
          ),
          AppTheme.spacer2x,
          CupertinoListTile(
            leading: CupertinoSwitch(
              value: consent.value,
              onChanged: (value) {
                consent.value = value;
              },
            ),
            title: const Text(
              'Jag godkänner att delta i studien',
              maxLines: 2,
              style: TextStyle(fontSize: 15, color: CupertinoColors.label),
            ),
          ),
        ],
      ),
      actions: <CupertinoDialogAction>[
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () {
            Navigator.of(context).pop(false);
          },
          child: const Text('Avbryt'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: consent.value
              ? () {
                  Navigator.of(context).pop(true);
                }
              : null,
          child: const Text('Fortsätt'),
        ),
      ],
    );
  }
}
