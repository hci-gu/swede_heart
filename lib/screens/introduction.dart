import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
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
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Välkommen till Swede Heart studien',
                    style: AppTheme.headLine3,
                    textAlign: TextAlign.center,
                  ),
                  AppTheme.spacer,
                  Text(
                    'Löksås ipsum precis tid i dock att kunde, stig äng sin upprätthållande är sin strand, icke i räv har ska oss. Ingalunda verkligen som enligt häst om redan ska ingalunda för enligt, ser sällan trevnadens fram som hela verkligen lax blev.',
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
            );
          case 1:
            return AppScaffold(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Information om studien',
                    style: AppTheme.headLine3,
                    textAlign: TextAlign.center,
                  ),
                  AppTheme.spacer,
                  Text(
                    'Löksås ipsum precis tid i dock att kunde, stig äng sin upprätthållande är sin strand, icke i räv har ska oss. Ingalunda verkligen som enligt häst om redan ska ingalunda för enligt, ser sällan trevnadens fram som hela verkligen lax blev. Träutensilierna precis sista häst strand träutensilierna vi kan ännu åker upprätthållande, i kunde tidigare plats varit av kom precis dag flera, som åker hwila tiden som mjuka vemod tiden mjuka.\n\n Enligt nu hela söka groda omfångsrik som själv vad vi, sig sorgliga dimmhöljd omfångsrik både fram groda ordningens, gör nu vad nu genom strand bäckasiner och. Vad del dimmhöljd sin träutensilierna fram och rot trevnadens sitt, sorgliga icke rot mot söka oss verkligen del, vid tiden händer vid björnbär trevnadens icke tre. Samma redan vad sitt helt blivit det av, vad denna därmed har räv mot tre, händer icke när vidsträckt mot blivit.',
                    style: AppTheme.paragraph,
                  ),
                ],
              ),
            );
          default:
            return Container();
        }
      },
    );
  }
}
