import 'package:flutter/cupertino.dart';
import 'package:swede_heart/theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'SwedeHeart',
      child: Center(child: Text('Tack för din medverkan!')),
    );
  }
}
