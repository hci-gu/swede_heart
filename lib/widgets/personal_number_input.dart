import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:personnummer/personnummer.dart';

import 'package:flutter/cupertino.dart';

class InputPrefix extends StatelessWidget {
  final String text;
  final String? error;

  const InputPrefix({super.key, required this.text, this.error});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 90,
      child: Padding(
        padding: const EdgeInsets.only(left: 8.0),
        child: error != null
            ? Column(
                children: [
                  Text(
                    text,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.destructiveRed,
                    ),
                  ),
                  Text(
                    error ?? '',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.destructiveRed,
                    ),
                  ),
                ],
              )
            : Text(
                text,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.activeBlue,
                ),
              ),
      ),
    );
  }
}

class PersonalNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String newText = newValue.text.replaceAll('-', '');

    // remove all non-digits
    newText = newText.replaceAll(RegExp(r'\D'), '');

    if (newText.length > 8) {
      newText = '${newText.substring(0, 8)}-${newText.substring(8)}';
    }
    if (newText.length > 13) {
      newText = newText.substring(0, 13);
    }

    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}

class PersonalNumberInput extends HookConsumerWidget {
  final TextEditingController controller;

  const PersonalNumberInput({super.key, required this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focusNode = useFocusNode();
    ValueNotifier<String?> errorMessage = useState(null);

    useEffect(() {
      void listener() {
        if (Personnummer.valid(controller.text)) {
          errorMessage.value = null;
        }
      }

      controller.addListener(listener);
      return () => controller.removeListener(listener);
    }, [controller]);

    focusNode.addListener(() {
      if (!focusNode.hasFocus) {
        if (controller.text.length < 13) {
          errorMessage.value = 'För kort';
        } else if (!Personnummer.valid(controller.text)) {
          errorMessage.value = 'Ogiltigt';
        } else {
          errorMessage.value = null;
        }
      }
    });

    return CupertinoTextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: const TextInputType.numberWithOptions(
        signed: true,
        decimal: false,
      ),
      inputFormatters: [PersonalNumberFormatter()],
      prefix: InputPrefix(text: 'Personnr', error: errorMessage.value),
      placeholder: 'YYYYMMDD-XXXX',
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
    );
  }
}
