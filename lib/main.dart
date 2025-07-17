import 'package:flutter/cupertino.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:swede_heart/api.dart';
import 'package:swede_heart/router.dart';
import 'package:swede_heart/state/auth.dart';
import 'package:swede_heart/storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Storage().reloadPrefs();
  String? personalNumber = Storage().getPersonalNumber();
  // Api().init('http://192.168.10.107:8090');
  Api().init('https://swedeheart-api.prod.appadem.in');

  runApp(
    ProviderScope(
      overrides: personalNumber != null
          ? [authProvider.overrideWith((ref) => Auth(personalNumber))]
          : [],
      child: App(loggedIn: personalNumber != null),
    ),
  );
}

class App extends ConsumerWidget {
  final bool loggedIn;

  const App({super.key, this.loggedIn = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider(loggedIn));

    return GestureDetector(
      onTap: () {
        FocusScopeNode currentFocus = FocusScope.of(context);

        if (!currentFocus.hasPrimaryFocus) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      },
      child: CupertinoApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
      ),
    );
  }
}
