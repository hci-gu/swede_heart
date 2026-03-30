import 'package:flutter/cupertino.dart';
import 'package:open_settings_plus/core/open_settings_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:swede_heart/screens/about.dart';
import 'package:swede_heart/screens/result/average_steps.dart';
import 'package:swede_heart/screens/result/chart.dart';
import 'package:swede_heart/screens/result/state.dart';
import 'package:swede_heart/theme.dart';

class StepsDataScreen extends ConsumerWidget {
  const StepsDataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventDate = ref.watch(eventDateProvider);

    return AppScaffold(
      title: 'CLI - Hjärtinfarkt',
      withPadding: false,
      child: eventDate == null
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'För att kunna visa din stegdata före/efter, behöver vi veta när din hjärtinfarkt skedde.',
                      textAlign: TextAlign.center,
                    ),
                    _selectEventDate(context, ref),
                  ],
                ),
              ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 0,
                    horizontal: 16,
                  ),
                  child: Text(
                    'Din stegdata',
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .navTitleTextStyle
                        .copyWith(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 0,
                    horizontal: 16,
                  ),
                  child: Text(
                    'Nedan ser du dina steg före och efter hjärtinfarkten.',
                    style: CupertinoTheme.of(
                      context,
                    ).textTheme.pickerTextStyle.copyWith(fontSize: 16),
                  ),
                ),
                _divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 0,
                    horizontal: 16,
                  ),
                  child: CupertinoSegmentedControl<DisplayMode>(
                    children: {
                      DisplayMode.day: _segmentItem('Dag'),
                      DisplayMode.week: _segmentItem('Vecka'),
                      DisplayMode.month: _segmentItem('Månad'),
                    },
                    onValueChanged: (value) {
                      ref.read(displayModeProvider.notifier).state = value;
                    },
                    groupValue: ref.watch(displayModeProvider),
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 16),
                ref
                    .watch(chartDataProvider)
                    .when(
                      data: (data) => data.pointsAfter.length >= 2
                          ? StepDataChart(
                              data: data,
                              displayMode: ref.watch(displayModeProvider),
                            )
                          : _notEnoughData(context),
                      error: (err, stack) => _errorContainer(context, ref),
                      loading: () => _chartContainer(
                        const Center(child: CupertinoActivityIndicator()),
                      ),
                    ),
                AverageSteps(),
                AppTheme.spacer2x,
                _selectEventDate(context, ref),
                // StepChart(),
              ],
            ),
    );
  }

  Widget _selectEventDate(BuildContext context, WidgetRef ref) {
    final eventDate = ref.watch(eventDateProvider);
    final text = eventDate == null
        ? 'Välj datum för hjärtinfarkt'
        : 'Du har valt ${eventDate.day}/${eventDate.month}/${eventDate.year} som datum för din hjärtinfarkt. Tryck för att ändra datum.';

    return SafeArea(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CupertinoButton(
            onPressed: () async {
              final DateTime? picked = await showCupertinoModalPopup<DateTime>(
                context: context,
                builder: (BuildContext context) {
                  DateTime tempPickedDate = DateTime.now();
                  return Container(
                    height: 300,
                    color: CupertinoColors.systemBackground.resolveFrom(
                      context,
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 200,
                          child: CupertinoDatePicker(
                            mode: CupertinoDatePickerMode.date,
                            initialDateTime: eventDate ?? DateTime.now(),
                            maximumDate: DateTime.now(),
                            onDateTimeChanged: (DateTime newDate) {
                              tempPickedDate = newDate;
                            },
                          ),
                        ),
                        CupertinoButton(
                          child: const Text('Välj'),
                          onPressed: () {
                            Navigator.of(context).pop(tempPickedDate);
                          },
                        ),
                      ],
                    ),
                  );
                },
              );

              if (picked != null) {
                ref.read(eventDateProvider.notifier).state = picked;
              }
            },
            child: Text(text),
          ),
        ],
      ),
    );
  }

  Widget _errorContainer(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Något gick fel när vi hämtade din data. Testa att ge tillgång till stegdata igen. Om problemet kvarstår, gå till telefonens inställingar för Hälsa appen och aktivera Brytpunkten under "Datatillgång och enheter" oss. Efter du har gett tillgång behöver du starta om appen.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          CupertinoButton.filled(
            borderRadius: BorderRadius.circular(15.0),
            child: const Text(
              'Ge tillgång',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            onPressed: () {
              const settings = OpenSettingsPlusIOS();
              settings.healthKit();
            },
          ),
        ],
      ),
    );
  }

  Widget _notEnoughData(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Text(
        'Det finns inte tillräckligt med data för att generera en graf.',
        style: CupertinoTheme.of(
          context,
        ).textTheme.pickerTextStyle.copyWith(fontSize: 16),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Container(
        height: 1,
        color: CupertinoColors.black.withOpacity(0.1),
      ),
    );
  }

  Widget _chartContainer(Widget child) {
    return SizedBox(height: 250, child: child);
  }

  Widget _segmentItem(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      child: Text(title),
    );
  }
}

class ResultScreen extends ConsumerWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.person),
            label: 'Din stegdata',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.info),
            label: 'Information',
          ),
        ],
      ),
      tabBuilder: (context, index) {
        switch (index) {
          case 0:
            return const StepsDataScreen();
          case 1:
            return const AboutScreen();
          default:
            return Container();
        }
      },
    );
  }
}
