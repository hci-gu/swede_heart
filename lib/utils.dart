import 'package:flutter/material.dart';

bool isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

bool isSameWeek(DateTime a, DateTime b) {
  DateTime startOfWeek(DateTime date) {
    // Assuming the week starts on Monday
    int dayOfWeek =
        date.weekday; // DateTime.weekday returns 1 for Monday, 7 for Sunday
    DateTime startOfWeek = date.subtract(Duration(days: dayOfWeek - 1));
    return DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
  }

  DateTime startOfWeek1 = startOfWeek(a);
  DateTime startOfWeek2 = startOfWeek(b);

  return startOfWeek1 == startOfWeek2;
}

bool isDarkMode(BuildContext context) {
  return MediaQuery.of(context).platformBrightness == Brightness.dark;
}
