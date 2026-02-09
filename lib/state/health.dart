import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:swede_heart/api.dart';

export 'package:health/health.dart';

final DateTime dateFrom = DateTime(2021, 1, 1);

List<HealthDataType> types = [
  HealthDataType.STEPS,
  HealthDataType.WALKING_SPEED,
  HealthDataType.WALKING_ASYMMETRY_PERCENTAGE,
  HealthDataType.WALKING_STEADINESS,
  HealthDataType.WALKING_DOUBLE_SUPPORT_PERCENTAGE,
  HealthDataType.WALKING_STEP_LENGTH,
];
List<HealthDataAccess> permissions = [
  HealthDataAccess.READ,
  HealthDataAccess.READ,
  HealthDataAccess.READ,
  HealthDataAccess.READ,
  HealthDataAccess.READ,
  HealthDataAccess.READ,
];

class HealthManager {
  Map<HealthDataType, List<HealthDataPoint>> data = {};
  HealthFactory health = HealthFactory();
  bool isAuthorized = false;
  bool triedToAuthorize = false;
  bool authorizationFailed = false;
  Future? ongoingUpload;

  void reset() {
    data = {};
    isAuthorized = false;
    triedToAuthorize = false;
    authorizationFailed = false;
  }

  Future init() async {
    if (data.isNotEmpty) {
      return;
    }

    await authorize();
    if (!isAuthorized) {
      if (kDebugMode) {
        print('HealthManager: Authorization failed or not requested yet.');
      }
      return;
    }
    data = {};
    List<HealthDataPoint> healthData = await health.getHealthDataFromTypes(
      dateFrom,
      DateTime.now(),
      types,
    );

    for (var type in types) {
      data[type] = healthData.where((element) => element.type == type).toList();
    }
    data.removeWhere((key, value) => value.isEmpty);
  }

  Future<bool> uploadLatestData(String personalId) async {
    try {
      ongoingUpload = Api().uploadData(
        personalId,
        data.values.expand((element) => element).toList(),
      );
      await ongoingUpload;
      ongoingUpload = null;
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error uploading latest data: $e');
      }
      ongoingUpload = null;
      return false;
    }
  }

  Future<bool> authorize() async {
    await Permission.activityRecognition.request();
    await Permission.location.request();

    isAuthorized = await health.requestAuthorization(
      types,
      permissions: permissions,
    );

    triedToAuthorize = true;
    return isAuthorized;
  }

  // Use API as a singleton
  static final HealthManager _instance = HealthManager._internal();
  factory HealthManager() {
    return _instance;
  }
  HealthManager._internal();
}
