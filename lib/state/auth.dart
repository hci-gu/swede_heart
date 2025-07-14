import 'package:swede_heart/pocketbase.dart';
import 'package:swede_heart/storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

const String staticPassword = 'does-not-matter';

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
    try {
      var loginState = await pb
          .collection('users')
          .authWithPassword(personalNumber, staticPassword);
      Storage().storePersonalNumber(personalNumber);

      state = loginState;
    } catch (e) {
      rethrow;
    }
  }

  Future signup(String personalNumber) async {
    try {
      await pb
          .collection('users')
          .create(
            body: {'username': personalNumber, 'password': staticPassword},
          );

      state = await pb
          .collection('users')
          .authWithPassword(personalNumber, staticPassword);
      Storage().storePersonalNumber(personalNumber);
    } catch (e) {
      rethrow;
    }
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
