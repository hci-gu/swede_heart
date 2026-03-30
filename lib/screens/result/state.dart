// import 'package:fracture_movement/state/state.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:swede_heart/state/health.dart';
import 'package:swede_heart/storage.dart';

bool isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

enum DisplayMode { day, week, month }

extension DisplayModeToDays on DisplayMode {
  int get days {
    switch (this) {
      case DisplayMode.day:
        return 1;
      case DisplayMode.week:
        return 7;
      case DisplayMode.month:
        return 30;
    }
  }
}

final eventDateProvider = StateProvider<DateTime?>((ref) {
  ref.listenSelf((previous, next) {
    if (next != null) {
      Storage().storeEventDate(next);
    }
  });

  return Storage().getEventDate();
});

final displayModeProvider = StateProvider<DisplayMode>(
  (ref) => DisplayMode.month,
);

final stepDataProvider = FutureProvider<List<HealthDataPoint>>((ref) async {
  DateTime? eventDate = ref.watch(eventDateProvider);

  if (eventDate == null) {
    return [];
  }

  DateTime oneYearBefore = eventDate.subtract(const Duration(days: 365));
  DateTime oneYearAfter = eventDate.add(const Duration(days: 365));

  List<HealthDataPoint> stepData = await HealthManager().health.getHealthDataFromTypes(
    oneYearBefore,
    oneYearAfter,
    [HealthDataType.STEPS],
  );

  return stepData;
});

DateTime dateForPointAndMode(DateTime date, DisplayMode mode) {
  switch (mode) {
    case DisplayMode.day:
      return DateTime(date.year, date.month, date.day);
    case DisplayMode.week:
      return DateTime(date.year, date.month, date.day - date.weekday + 1);
    case DisplayMode.month:
      return DateTime(date.year, date.month, 1);
  }
}

List<DataPoint> groupDataPointsByDate(
  List<DataPoint> dayPoints,
  DisplayMode mode,
) {
  if (mode == DisplayMode.day) {
    return dayPoints;
  }

  Map<DateTime, List<DataPoint>> dateMap = {};
  for (DataPoint point in dayPoints) {
    DateTime date = dateForPointAndMode(point.date, mode);
    if (dateMap[date] == null) {
      dateMap[date] = [];
    }
    dateMap[date]!.add(point);
  }

  List<DataPoint> points = dateMap.entries.map((e) {
    double sum =
        e.value.map((e) => e.value).reduce((value, element) {
          return value + element;
        }) /
        e.value.length;

    // if (isSameDay(e.key, eventDate)) {
    //   eventPoint = DataPoint(e.key, sum);
    // }
    return DataPoint(e.key, sum);
  }).toList();

  return points;
}

final chartDataProvider = FutureProvider<ChartData>((ref) async {
  DateTime? eventDate = ref.watch(eventDateProvider);
  if (eventDate == null) {
    return ChartData([], DateTime.now());
  }

  final displayMode = ref.watch(displayModeProvider);

  List<HealthDataPoint> stepData = await ref.watch(stepDataProvider.future);
  final dataUntil = DateTime.now();

  stepData = stepData.where((e) => e.dateFrom.isBefore(dataUntil)).toList();

  if (stepData.isEmpty) {
    return ChartData([], dateForPointAndMode(eventDate, displayMode));
  }

  // Group by device
  final Map<String, List<HealthDataPoint>> deviceMap = {};
  for (final point in stepData) {
    deviceMap.putIfAbsent(point.deviceId, () => []).add(point);
  }

  // Take device with most data
  final List<DataPoint> data = deviceMap.values
      .reduce((a, b) => a.length > b.length ? a : b)
      .map((e) => DataPoint.fromHealthDataPoint(e))
      .toList();

  // Aggregate by calendar day
  final Map<DateTime, List<DataPoint>> dayMap = {};
  for (final point in data) {
    final date = DateTime(
      point.date.year,
      point.date.month,
      point.date.day,
      12,
    );
    dayMap.putIfAbsent(date, () => []).add(point);
  }

  final List<DataPoint> dayPoints = dayMap.entries.map((e) {
    final sum = e.value.map((e) => e.value).reduce((v, el) => v + el);
    return DataPoint(e.key, sum);
  }).toList();

  // Group to display mode buckets
  final points = groupDataPointsByDate(dayPoints, displayMode)
    ..sort((a, b) => a.date.compareTo(b.date));

  // 🔑 Normalize event date to the current bucket so it's included in both sides
  final normalizedEventDate = dateForPointAndMode(eventDate, displayMode);

  return ChartData(points, normalizedEventDate);
});

final averageStepsBeforeProvider = FutureProvider<double>((ref) async {
  ChartData data = await ref.watch(chartDataProvider.future);

  if (data.pointsBefore.isEmpty) return 0;

  return data.pointsBefore.map((e) => e.value).reduce((value, element) {
        return value + element;
      }) /
      data.pointsBefore.length;
});

final averageStepsAfterProvider = FutureProvider<double>((ref) async {
  ChartData data = await ref.watch(chartDataProvider.future);

  if (data.pointsAfter.isEmpty) return 0;

  return data.pointsAfter.map((e) => e.value).reduce((value, element) {
        return value + element;
      }) /
      data.pointsAfter.length;
});

class ChartData {
  final List<DataPoint> points;
  final DateTime eventDate;

  ChartData(this.points, this.eventDate);

  DataPoint get eventPoint => points.firstWhere(
    (element) => isSameDay(element.date, eventDate),
    orElse: () => DataPoint(eventDate, 0),
  );

  List<DataPoint> get pointsBefore => points
      .where(
        (element) =>
            eventDate.isAfter(element.date) ||
            isSameDay(eventDate, element.date),
      )
      .toList();

  List<DataPoint> get pointsAfter => points
      .where(
        (element) =>
            eventDate.isBefore(element.date) ||
            isSameDay(eventDate, element.date),
      )
      .toList();
}

class DataPoint {
  final DateTime date;
  final double value;

  DataPoint(this.date, this.value);

  // from HealthDataPoint
  factory DataPoint.fromHealthDataPoint(HealthDataPoint hp) {
    Map<String, dynamic> json = hp.value.toJson();
    String value = json['numericValue'];
    return DataPoint(hp.dateFrom, double.parse(value));
  }
}
