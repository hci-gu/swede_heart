import 'package:flutter/cupertino.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:swede_heart/screens/home.dart';
import 'package:swede_heart/screens/introduction.dart';
import 'package:swede_heart/screens/login.dart';
import 'package:swede_heart/screens/steps.dart';
import 'package:swede_heart/state/auth.dart';

class RouterNotifier extends ChangeNotifier {
  final Ref _ref;

  RouterNotifier(this._ref) {
    _ref.listen<String?>(
      authProvider.select((value) => value?.token),
      (_, _) => notifyListeners(),
    );
  }

  String? _redirectLogic(BuildContext context, GoRouterState state) {
    bool loggedIn = _ref.read(authProvider) != null;
    bool hasUploadedData = _ref.read(dataUploadedProvider);

    if (loggedIn && _isLoginRoute(state.matchedLocation)) {
      if (hasUploadedData) {
        return '/';
      } else {
        return '/steps';
      }
    }
    if (!loggedIn && !_isLoginRoute(state.matchedLocation)) {
      return '/introduction';
    }
    return null;
  }

  bool _isLoginRoute(String route) {
    return route == '/introduction' ||
        route == '/introduction/login' ||
        route == '/introduction/steps';
  }
}

final routerProvider = Provider.family<GoRouter, bool>((ref, loggedIn) {
  final routerNotifier = RouterNotifier(ref);

  return GoRouter(
    initialLocation: '/loading',
    routes: [
      GoRoute(
        path: '/loading',
        name: 'loading',
        builder: (context, state) => const LoadingScreen(),
      ),
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const HomeScreen(),
        routes: [
          GoRoute(
            path: 'steps',
            name: 'steps',
            builder: (context, state) => const StepDataScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/introduction',
        name: 'introduction',
        builder: (context, state) => const IntroductionScreen(),
        routes: [
          GoRoute(
            path: 'login',
            name: 'login',
            builder: (context, state) => const LoginScreen(),
          ),
        ],
      ),
    ],
    refreshListenable: routerNotifier,
    redirect: routerNotifier._redirectLogic,
  );
});

class LoadingScreen extends HookConsumerWidget {
  const LoadingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ValueNotifier<bool> waitedLongEnough = useState(false);

    useEffect(() {
      Future.delayed(const Duration(seconds: 5), () {
        if (context.mounted) {
          waitedLongEnough.value = true;
        }
      });
      return () => {};
    }, []);

    return CupertinoPageScaffold(
      child: waitedLongEnough.value
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: CupertinoActivityIndicator()),
                const SizedBox(height: 16),
                Center(
                  child: CupertinoButton.filled(
                    onPressed: () {
                      context.goNamed('introduction');
                    },
                    child: const Text('Abort'),
                  ),
                ),
              ],
            )
          : const Center(child: CupertinoActivityIndicator()),
    );
  }
}
