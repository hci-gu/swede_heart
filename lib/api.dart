import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:swede_heart/state/health.dart';

class Api {
  Dio api = Dio(BaseOptions(
    headers: {'Content-Type': 'application/json'},
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 60),
  ));
  void init(String baseUrl) {
    api.options.baseUrl = baseUrl;
  }

  Future uploadDataInChunks(
    String personalId,
    List<HealthDataPoint> data,
  ) async {
    // split up data into 10 equal chunks
    List<Map<String, dynamic>> chunks = [];
    int chunkSize = (data.length / 10).ceil();
    int chunkIndex = 0;
    for (int i = 0; i < data.length; i += chunkSize) {
      int endIndex = i + chunkSize;
      if (endIndex > data.length) {
        endIndex = data.length;
      }

      Map<String, dynamic> body = {
        'personalId': personalId,
        'chunkIndex': chunkIndex,
        'data': data.sublist(i, endIndex).map((e) => e.toJson()).toList(),
      };
      chunks.add(body);
      chunkIndex++;
    }

    // Function to handle a single chunk upload
    Future<void> uploadChunk(Map<String, dynamic> chunk) async {
      await api.post(
        '/data',
        options: Options(
          headers: {
            'Content-Encoding': 'gzip',
            'Content-Type': 'application/json; charset=UTF-8',
          },
        ),
        data: gzip.encode(utf8.encode(jsonEncode(chunk))),
      );
    }

    // run all chunks in series
    while (chunks.isNotEmpty) {
      Map<String, dynamic> chunk = chunks.removeAt(0);
      await uploadChunk(chunk);
    }
  }

  Future uploadNoDataInfo(String personalId, Map<String, dynamic> data) async {
    await api.post(
      '/info',
      options: Options(
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
      ),
      data: jsonEncode({'personalId': personalId, 'data': data}),
    );
  }

  Future uploadData(String personalId, List<HealthDataPoint> data) =>
      uploadDataInChunks(personalId, data);

  // Use API as a singleton
  static final Api _instance = Api._internal();
  factory Api() {
    return _instance;
  }
  Api._internal();
}
