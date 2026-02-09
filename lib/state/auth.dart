import 'dart:math';

import 'package:swede_heart/pocketbase.dart';
import 'package:swede_heart/storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

String _generatePassword() {
  final random = Random.secure();
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
}

class Auth extends StateNotifier<RecordAuth?> {
  Auth([String? personalId]) : super(null) {
    init(personalId);
  }

  Future<void> init(String? personalNumber) async {
    if (personalNumber == null) {
      return;
    }

    try {
      await login(personalNumber);
    } catch (e) {
      Storage().clearCredentials();
      rethrow;
    }
  }

  Future login(String personalNumber, [WidgetRef? ref]) async {
    final password = Storage().getPassword();
    if (password == null) {
      throw Exception('No stored password');
    }

    var loginState = await pb
        .collection('users')
        .authWithPassword(personalNumber, password);
    Storage().storePersonalNumber(personalNumber);

    state = loginState;
  }

  Future signup(String personalNumber, {required bool consent}) async {
    final password = _generatePassword();

    await pb
        .collection('users')
        .create(
          body: {
            'username': personalNumber,
            'password': password,
            'passwordConfirm': password,
            'consent': consent,
          },
        );

    state = await pb
        .collection('users')
        .authWithPassword(personalNumber, password);
    await Storage().storePassword(password);
    await Storage().storePersonalNumber(personalNumber);
  }

  Future logout() async {
    state = null;
    Storage().clearCredentials();
  }

  Future deleteAccount() async {
    try {
      pb.collection('users').delete(state!.record.id);
      state = null;
      Storage().clearCredentials();
    } catch (e) {
      rethrow;
    }
  }
}

final authProvider = StateNotifierProvider<Auth, RecordAuth?>((ref) => Auth());

final dataUploadedProvider = StateProvider<bool>((ref) {
  ref.listenSelf((previous, next) {
    Storage().setHasUploadedData(next);
  });

  return Storage().getHasUploadedData();
});
