import 'package:flutter/cupertino.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:swede_heart/theme.dart';

class ConsentModal extends HookWidget {
  const ConsentModal({super.key});

  @override
  Widget build(BuildContext context) {
    ValueNotifier<bool> consent = useState(false);

    return CupertinoAlertDialog(
      title: const Text('Samtycke till att delta i projektet'),
      content: Column(
        children: [
          Text(
            'Jag har fått skriftlig information om studien och har haft möjlighet att ställa frågor. Jag får behålla den skriftliga informationen.',
            style: const TextStyle(fontSize: 14, color: CupertinoColors.label),
            textAlign: TextAlign.justify,
          ),
          AppTheme.spacer,
          Text(
            'Jag samtycker till att delta i projektet Longitudinella fysiska aktivitetsmönster före och efter hjärtinfarkt med hjälp av retrospektiv iOS-data',
            style: const TextStyle(fontSize: 14, color: CupertinoColors.label),
            textAlign: TextAlign.justify,
          ),
          AppTheme.spacer2x,
          Center(
            child: CupertinoSwitch(
              value: consent.value,
              onChanged: (value) {
                consent.value = value;
              },
            ),
          ),
          // CupertinoListTile(
          //   leading: CupertinoSwitch(
          //     value: consent.value,
          //     onChanged: (value) {
          //       consent.value = value;
          //     },
          //   ),
          //   title: const Text(
          //     'Jag har läst ovan och samtycker',
          //     maxLines: 4,
          //     style: TextStyle(fontSize: 15, color: CupertinoColors.label),
          //   ),
          // ),
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
