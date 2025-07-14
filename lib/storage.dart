import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  late SharedPreferences prefs;

  Future reloadPrefs() async {
    prefs = await SharedPreferences.getInstance();
  }

  String? getPersonalNumber() {
    final String? personalNumber = prefs.getString('personalNumber');

    return personalNumber;
  }

  Future storePersonalNumber(String personalNumber) async {
    await reloadPrefs();
    await prefs.setString('personalNumber', personalNumber);
  }

  Future clearCredentials() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    prefs.remove('personalNumber');
  }

  static final Storage _instance = Storage._internal();
  factory Storage() {
    return _instance;
  }
  Storage._internal();
}
