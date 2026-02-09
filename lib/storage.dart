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

  String? getPassword() {
    return prefs.getString('password');
  }

  Future storePassword(String password) async {
    await reloadPrefs();
    await prefs.setString('password', password);
  }

  Future clearCredentials() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('personalNumber');
    await prefs.remove('password');
  }

  bool getHasUploadedData() {
    return prefs.getBool('hasUploadedData') ?? false;
  }

  Future setHasUploadedData(bool value) async {
    await reloadPrefs();
    await prefs.setBool('hasUploadedData', value);
  }

  Future storeEventDate(DateTime date) async {
    await reloadPrefs();
    await prefs.setString('eventDate', date.toIso8601String());
  }

  DateTime? getEventDate() {
    final String? dateString = prefs.getString('eventDate');
    if (dateString == null) {
      return null;
    }
    return DateTime.tryParse(dateString);
  }

  static final Storage _instance = Storage._internal();
  factory Storage() {
    return _instance;
  }
  Storage._internal();
}
