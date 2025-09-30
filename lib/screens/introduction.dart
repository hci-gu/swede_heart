import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:swede_heart/screens/about.dart';
import 'package:swede_heart/theme.dart';

class IntroductionScreen extends StatelessWidget {
  const IntroductionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.home),
            label: 'Hem',
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
            return AppScaffold(
              child: SafeArea(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Image.asset('assets/logo.png', width: 100, height: 100),
                    Text(
                      'SWEDEHEART',
                      style: AppTheme.headLine3,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 64),
                    Text(
                      'Välkommen till studien',
                      style: AppTheme.headLine3,
                      textAlign: TextAlign.center,
                    ),
                    AppTheme.spacer,
                    Text(
                      'Detta forskningsprojekt syftar till att undersöka fysisk aktivitetsnivå före, direkt efter och längre tid efter en hjärtinfarkt genom att använda data från din iPhone. Vi vill också studera hur fysisk aktivitet påverkar återhämtning och långsiktig hälsa efter hjärtinfarkt, samt hur i eventuellt deltagande i hjärtrehabilitering har samband med hur man rör sig.',
                      style: AppTheme.paragraph,
                      textAlign: TextAlign.justify,
                    ),
                    AppTheme.spacer2x,
                    Center(
                      child: CupertinoButton.filled(
                        onPressed: () {
                          context.goNamed('login');
                        },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: AppTheme.basePadding * 2,
                          ),
                          child: const Text('Börja'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          case 1:
            return const AboutScreen();
          default:
            return Container();
        }
      },
    );
  }
}
