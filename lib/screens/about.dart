import 'package:flutter/widgets.dart';
import 'package:swede_heart/theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      withPadding: false,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            Text(
              'Om studien',
              style: AppTheme.headLine2,
              textAlign: TextAlign.center,
            ),
            AppTheme.spacer,
            _section(
              null,
              'Fysisk aktivitet är en viktig faktor för återhämtning och hälsa efter hjärtinfarkt, men vi vet väldigt lite om människors aktivitetsmönster före och efter en hjärtinfarkt och hur detta eventuellt förändras. Med dagens smartphone-teknik har vi nu möjlighet att studera detta på ett sätt som tidigare inte varit möjligt.',
            ),
            _section(
              null,
              'Detta forskningsprojekt syftar till att undersöka fysisk aktivitetsnivå före, direkt efter och längre tid efter en hjärtinfarkt genom att använda data från din iPhone. Vi vill också studera hur fysisk aktivitet påverkar återhämtning och långsiktig hälsa efter hjärtinfarkt, samt hur i eventuellt deltagande i hjärtrehabilitering har samband med hur man rör sig.',
            ),
            _section(
              null,
              'Du tillfrågas om deltagande eftersom du haft en hjärtinfarkt för 1-5 år sedan och är registrerad i SWEDEHEART-registret. Dina kontaktuppgifter har inhämtats från Statens personadressregister (SPAR).',
            ),
            _section(
              null,
              'Forskningshuvudman för projektet är Göteborgs Universitet. Med forskningshuvudman menas den organisation som är ansvarig för projektet. Forskningen är godkänd av Etikprövningsmyndigheten.',
            ),
            _section(
              'Ansvariga för projektet',
              'Mats Börjesson, Professor, Överläkare\nCentrum för Livsstilsintervention, Göteborgs Universitet\nSahlgrenska universitetssjukhuset, Centrum för livsstilsintervention, 416 85 Göteborg\n070 529 83 60, mats.borjesson@gu.se',
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String? title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) Text(title, style: AppTheme.headLine3),
        if (title != null) AppTheme.spacer,
        Text(content, style: AppTheme.paragraph),
        AppTheme.spacer2x,
      ],
    );
  }
}
