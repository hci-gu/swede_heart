import 'dart:math';

import 'package:swede_heart/api.dart';
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
  final String? _personalNumber;

  Auth([this._personalNumber]) : super(null);

  Future<void> tryAutoLogin() async {
    if (_personalNumber == null) return;

    try {
      await login(_personalNumber);
    } catch (e) {
      await Storage().clearCredentials();
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

    // Register via custom endpoint — handles both new and returning users
    await Api().registerUser(personalNumber, password, consent);

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
