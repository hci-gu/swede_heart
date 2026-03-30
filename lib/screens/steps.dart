import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:health/health.dart';
import 'dart:ui';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:open_settings_plus/core/open_settings_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:swede_heart/state/auth.dart';
import 'package:swede_heart/state/health.dart';
import 'package:swede_heart/theme.dart';

class RedoPermissions extends HookConsumerWidget {
  const RedoPermissions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useOnAppLifecycleStateChange((previous, current) {
      if (current == AppLifecycleState.resumed) {
        // ref.read(healthDataProvider.notifier).authorize();
      }
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        children: [
          const Row(
            children: [
              Icon(
                CupertinoIcons.exclamationmark_octagon_fill,
                color: CupertinoColors.destructiveRed,
              ),
              SizedBox(width: 8.0),
              Expanded(
                child: Text(
                  'Du har nekat tillgång via Apple Health.',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  textAlign: TextAlign.start,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8.0),
          const Text(
            'Gå till inställingar, välj Hälsa -> Data -> CLI - Hjärtinfarkt -> Slå på alla',
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.start,
          ),
          const SizedBox(height: 8.0),
          CupertinoButton.filled(
            borderRadius: BorderRadius.circular(15.0),
            child: const Row(
              children: [
                Spacer(),
                Flexible(
                  child: Text(
                    'Öppna inställningar',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                Spacer(),
              ],
            ),
            onPressed: () {
              openAppSettings();
            },
          ),
        ],
      ),
    );
  }
}

class HealthListTile extends StatelessWidget {
  final List<HealthDataPoint> items;
  final HealthDataType type;

  const HealthListTile({super.key, required this.items, required this.type});

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: icon,
      title: Text(displayType),
      subtitle: Text(displayPeriod),
    );
  }

  DateTime get firstDate => items.last.dateFrom;
  DateTime get lastDate => items.first.dateFrom;

  String get displayPeriod =>
      '${firstDate.toIso8601String().substring(0, 10)} - ${lastDate.toIso8601String().substring(0, 10)}';

  String get displayType {
    switch (type) {
      case HealthDataType.STEPS:
        return 'Steg';
      case HealthDataType.WALKING_SPEED:
        return 'Gånghastighet';
      case HealthDataType.WALKING_STEP_LENGTH:
        return 'Steglängd';
      case HealthDataType.WALKING_STEADINESS:
        return 'Stabilitet vid gång';
      case HealthDataType.WALKING_ASYMMETRY_PERCENTAGE:
        return 'Asymmetrisk gång';
      case HealthDataType.WALKING_DOUBLE_SUPPORT_PERCENTAGE:
        return 'Tid med båda fötterna på marken';
      default:
        return '';
    }
  }

  Widget get icon {
    if (type == HealthDataType.STEPS) {
      return const Icon(
        CupertinoIcons.flame_fill,
        color: CupertinoColors.destructiveRed,
      );
    }
    return const Icon(
      CupertinoIcons.arrow_left_right,
      color: CupertinoColors.activeOrange,
    );
  }
}

class LifeCycleManager extends StatefulWidget {
  final Widget child;
  final WidgetRef ref;
  const LifeCycleManager({super.key, required this.child, required this.ref});
  _LifeCycleManagerState createState() => _LifeCycleManagerState();
}

class _LifeCycleManagerState extends State<LifeCycleManager>
    with WidgetsBindingObserver {
  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      HealthManager().reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(child: widget.child);
  }
}

class UploadStepsScreen extends HookConsumerWidget {
  final bool includeDate;

  const UploadStepsScreen({super.key, this.includeDate = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ValueNotifier<bool> loading = useState(false);

    return AppScaffold(
      withPadding: false,
      noBackButton: true,
      title: 'Ladda upp stegdata',
      child: SafeArea(
        child: LifeCycleManager(
          ref: ref,
          child: AlreadyDoneWrapper(
            alreadyDone: false,
            child: loading.value
                ? _loading(
                    'Laddar upp din data\n ( du behöver inte göra något )',
                  )
                : FutureBuilder(
                    future:
                        HealthManager().ongoingUpload ?? HealthManager().init(),
                    builder: (_, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return _loading('Laddar in din stegdata');
                      }

                      return WithStepData(
                        data: HealthManager().data,
                        userHasData: HealthManager().data.isNotEmpty,
                        isAuthorized: HealthManager().isAuthorized,
                        onPressed: () async {
                          loading.value = true;
                          String? personalNumber = ref
                              .read(authProvider)
                              ?.record
                              .getStringValue('username');
                          if (personalNumber != null) {
                            bool success = await HealthManager()
                                .uploadLatestData(personalNumber);
                            if (success) {
                              ref.read(dataUploadedProvider.notifier).state =
                                  true;
                              if (context.mounted) {
                                context.goNamed('result');
                              }
                            } else if (!success && context.mounted) {
                              await showAlertDialog(context);
                            }
                          }

                          if (context.mounted) {
                            loading.value = false;
                          }
                        },
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _loading(String message) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CupertinoActivityIndicator(),
        AppTheme.spacer2x,
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              message,
              style: AppTheme.paragraphMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}

class WithStepData extends HookConsumerWidget {
  final Map<HealthDataType, List<HealthDataPoint>> data;
  final bool userHasData;
  final bool isAuthorized;
  final void Function() onPressed;

  const WithStepData({
    super.key,
    required this.data,
    required this.onPressed,
    this.userHasData = false,
    this.isAuthorized = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useEffect(() {
      if (!userHasData) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showNoStepsAlert(context);
        });
      }
      return () {};
    }, []);

    if (userHasData) {
      return Scrollbar(
        child: ListView(
          shrinkWrap: true,
          children: [
            CupertinoListSection(
              header: const Text('Data från "Hälsa" appen'),
              children: [
                for (final type in data.keys.toList())
                  HealthListTile(items: data[type] ?? [], type: type),
              ],
            ),
            AppTheme.spacer2x,
            Center(
              child: CupertinoButton.filled(
                onPressed: onPressed,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppTheme.basePadding * 4,
                  ),
                  child: Text('Ladda upp'),
                ),
              ),
            ),
            AppTheme.spacer,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                'Beroende på internetuppkoppling kan det ta en liten stund.',
                style: AppTheme.paragraphMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    if (!isAuthorized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: CupertinoButton.filled(
            borderRadius: BorderRadius.circular(15.0),
            onPressed: onPressed,
            child: const Row(
              children: [
                Spacer(),
                Text(
                  'Ge tillgång',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                Spacer(),
              ],
            ),
          ),
        ),
      );
    }
    if (isAuthorized && !userHasData) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Text(
            'Du har gett tillgång till "Hälsa" appen, men det verkar inte finnas någon stegdata att ladda upp på den här enheten. Har du fler eller kanske en äldre telefon kanske du behöver använda appen på den enheten istället.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return const RedoPermissions();
  }
}

Future showNoStepsAlert(BuildContext context) async {
  await showCupertinoDialog(
    context: context,
    builder: (context) {
      return CupertinoAlertDialog(
        title: const Text('Det gick inte att hämta stegdata'),
        content: const Text(
          'Det verkar som du inte har någon stegdata från "Hälsa" appen trots att du gett åtkomst.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  );
}

Future showAlertDialog(BuildContext context) {
  return showCupertinoDialog(
    context: context,
    builder: (context) {
      return CupertinoAlertDialog(
        title: const Text('Det gick inte att hämta stegdata'),
        content: const Text(
          'Du kan ha nekat tillgång till appen, du behöver öppna inställningar för "Hälsa" och ge tillgång till "CLI - Hjärtinfarkt".\n\nEfter du trycker OK kommer inställningar öppnas, gå till Appar -> Hälsa -> Datatillgång och enheter  -> CLI - Hjärtinfarkt -> Slå på alla.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () {
              const settings = OpenSettingsPlusIOS();
              settings.healthKit();
              Navigator.of(context).pop();
            },
          ),
        ],
      );
    },
  );
}

class AlreadyDoneWrapper extends StatelessWidget {
  final Widget child;
  final bool alreadyDone;

  const AlreadyDoneWrapper({
    super.key,
    required this.child,
    required this.alreadyDone,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        alreadyDone
            ? ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: child,
              )
            : child,
        if (alreadyDone)
          SizedBox(
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            child: const Center(
              child: Text(
                'Du har redan gjort det här steget',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
    );
  }
}
