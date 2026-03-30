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
              'Mats Börjesson, Professor, Överläkare\nCentrum för Livsstilsintervention, Göteborgs Universitet\nSahlgrenska universitetssjukhuset, Centrum för livsstilsintervention, 416 85 Göteborg\n031 343 53 98, mats.borjesson@gu.se',
            ),
            _section(
              'Information till forskningspersoner',
              'Vi vill fråga dig om du vill delta i ett forskningsprojekt. I det här dokumentet får du information om projektet och om vad det innebär att delta.',
            ),
            _subSection(
              'Vad är det för ett projekt och varför vill vi att du ska delta?',
              [
                'Fysisk aktivitet är en viktig faktor för återhämtning och hälsa efter hjärtinfarkt, men vi vet väldigt lite om människors aktivitetsmönster före och efter en hjärtinfarkt och hur detta eventuellt förändras. Med dagens smartphone-teknik har vi nu möjlighet att studera detta på ett sätt som tidigare inte varit möjligt.\n',
                'Detta forskningsprojekt syftar till att undersöka fysisk aktivitetsnivå före, direkt efter och längre tid efter en hjärtinfarkt genom att använda data från din iPhone. Vi vill också studera hur fysisk aktivitet påverkar återhämtning och långsiktig hälsa efter hjärtinfarkt, samt hur i eventuellt deltagande i hjärtrehabilitering har samband med hur man rör sig.\n',
                'Du tillfrågas om deltagande eftersom du haft en hjärtinfarkt för 1-5 år sedan och är registrerad i SWEDEHEART-registret. Dina kontaktuppgifter har inhämtats från Statens personadressregister (SPAR).\n',
                'Forskningshuvudman för projektet är Göteborgs Universitet. Med forskningshuvudman menas den organisation som är ansvarig för projektet. Forskningen är godkänd av Etikprövningsmyndigheten, diarienummer för prövningen hos Etikprövningsmyndigheten är 2025-03614-01.',
              ],
            ),
            _subSection('Hur går projektet till?', [
              'Om du väljer att delta kommer du att få ladda ner en speciell app till din iPhone genom att skanna QR-koden i brevet. I appen får du mer information om studien och kan lämna ditt samtycke. Du lämnar ditt samtycke genom att ange ditt namn och personnummer. Ditt personnummer används för att koppla dina aktivitetsdata till dina medicinska uppgifter i SWEDEHEART-registret.',
              'När du gett ditt samtycke kommer appen att hämta data om fysisk aktivitet från din iPhones Hälsa-app. Detta inkluderar information om steg, gånghastighet, steglängd och andra rörelsemått som din telefon automatiskt har registrerat, både före och efter din hjärtinfarkt.\n',
              'Deltagandet kräver endast några minuter av din tid för att ladda ner appen och ge ditt samtycke. Appen ger dig också möjlighet att se din egen aktivitetsdata på ett mer överskådligt sätt än vad som normalt är möjligt i Hälsa-appen.\n',
              'Longitudinella fysiska aktivitetsmönster före och efter hjärtinfarkt med hjälp av retrospektiv iOS-data',
            ]),
            _subSection('Möjliga följder och risker med att delta i projektet', [
              'Deltagandet innebär inga fysiska risker eller obehag. För att minimera risken med datasäkerhet och integritet, så lagras all data i en särskilt säker forskningsdatabas vid Göteborgs Universitet. Appen genomgår omfattande säkerhetstester innan den används.',
              'Du kan när som helst välja att avbryta ditt deltagande utan att detta påverkar din framtida vård.',
            ]),
            _subSection('Vad händer med dina uppgifter?', [
              'Projektet kommer att samla in och registrera information om dig. Följande information samlas in:\n',
              '\t• Aktivitetsdata från din iPhones Hälsa-app (steg, gånghastighet, steglängd etc.)\n',
              '\t• Medicinska uppgifter från SWEDEHEART-registret (information om din hjärtinfarkt, behandling, rehabilitering och hälsotillstånd)\n',
              'All data lagras och analyseras i en säker forskningsmiljö (TRE) vid Göteborgs Universitet. Dina uppgifter kommer att förvaras i sin helhet men endast vara tillgängliga för behörig forskningspersonal.\n',
              'Behandlingen av personuppgifter baseras på allmänt intresse och samtycke enligt EU:s dataskyddsförordning. Inga uppgifter kommer att överföras utanför EU/EES.\n',
              'Dina svar och resultat kommer att behandlas så att inte obehöriga kan ta del av dem. Data kommer att sparas i 10 år efter studiens avslutande i enlighet med forskningsdatalagen.\n',
              'Ansvarig för dina personuppgifter är Göteborgs Universitet. Enligt EU:s dataskyddsförordning har du rätt att kostnadsfritt få ta del av de uppgifter om dig som hanteras i projektet, och vid behov få eventuella fel rättade. Du kan också begära att uppgifter om dig raderas samt att behandlingen av dina personuppgifter begränsas. Rätten till radering och till begränsning av behandling av personuppgifter gäller dock inte när uppgifterna är nödvändiga för den aktuella forskningen. Om du vill ta del av uppgifterna ska du kontakta Mats Börjesson, Sahlgrenska universitetssjukhuset, Centrum för livsstilsintervention, 416 85 Göteborg, 031 343 53 98. Dataskyddsombud nås på dataskyddsombud@gu.se. Om du är missnöjd med hur dina personuppgifter behandlas har du rätt att ge in klagomål till Integritetsskyddsmyndigheten, som är tillsynsmyndighet. 2 Longitudinella fysiska aktivitetsmönster före och efter hjärtinfarkt med hjälp av retrospektiv iOS-data',
            ]),
            _subSection('Hur får du information om resultatet av projektet?', [
              'Du kan få information om studiens slutresultat genom att kontakta huvudansvarig forskare när studien är avslutad. Resultaten kommer också att publiceras i vetenskapliga tidskrifter och presenteras på konferenser. Genom den nedladdade appen får du tillgång till dina egna aktivitetsdata i ett lättillgängligt format.',
            ]),
            _subSection('Försäkring och ersättning', [
              'Denna studie involverar endast insamling och analys av redan existerande data från din iPhone och SWEDEHEART-registret. Studien omfattar inga fysiska undersökningar eller medicinska behandlingar. Enligt Etikprövningsmyndighetens riktlinjer behövs därför inget särskilt försäkringsskydd för denna typ av forskning.\n',
              'Ingen ekonomisk ersättning utgår för deltagande i studien.',
            ]),
            _subSection('Deltagandet är frivilligt', [
              'Ditt deltagande är frivilligt och du kan när som helst välja att avbryta deltagandet. Om du väljer att inte delta eller vill avbryta ditt deltagande behöver du inte uppge varför, och det kommer inte heller att påverka din framtida vård eller behandling.\n',
              'Om du vill avbryta ditt deltagande ska du kontakta den ansvariga för projektet (se nedan).',
            ]),
            _subSection('Ansvariga för projektet', [
              'Ansvarig för projektet är:\n',
              'Mats Börjesson, Professor, Överläkare\n',
              'Centrum för Livsstilsintervention, Göteborgs Universitet\n',
              'Sahlgrenska universitetssjukhuset, Centrum för livsstilsintervention, 416 85 Göteborg\n',
              '031 343 53 98, mats.borjesson@gu.se',
            ]),
            _subSection('', []),
          ],
        ),
      ),
    );
  }

  Widget _subSection(String title, List<String> content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTheme.paragraph.copyWith(fontWeight: FontWeight.bold),
        ),
        AppTheme.spacer,
        ...content.map((c) => Text(c, style: AppTheme.paragraph)),
        AppTheme.spacer2x,
      ],
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
