import 'dart:async';
import 'dart:collection';

import '../../../core/errors/app_exception.dart';
import '../domain/auth_requests.dart';
import '../domain/auth_session.dart';
import '../domain/email_verification.dart';
import '../domain/kid_profile.dart';
import '../domain/parent_account.dart';
import 'auth_api.dart';
import 'auth_session_store.dart';

/// Coordinates the remote parent account API with secure local session state.
class AuthRepository {
  AuthRepository({AuthApi? api, AuthSessionStore? sessionStore})
    : _api = api ?? HttpAuthApi(),
      _sessionStore = sessionStore ?? SecureAuthSessionStore();

  final AuthApi _api;
  final AuthSessionStore _sessionStore;

  /// Refresh tokens rotate on every successful refresh, so every repository
  /// instance in the isolate must share the same request for a given token.
  static final Map<String, Future<AuthSession>> _refreshesByToken = {};
  static final Queue<Future<void> Function()> _sessionMutationQueue = Queue();
  static bool _sessionMutationActive = false;

  Future<PendingEmailVerification> register(RegisterParentRequest request) {
    return _api.register(request);
  }

  Future<AuthSession> verifyEmail(VerifyEmailRequest request) async {
    final session = await _api.verifyEmail(request);
    await _writeSession(session);
    return session;
  }

  Future<PendingEmailVerification> resendEmailVerification(String challengeId) {
    return _api.resendEmailVerification(challengeId);
  }

  Future<AuthSession> login(LoginRequest request) async {
    final session = await _api.login(request);
    await _writeSession(session);
    return session;
  }

  Future<AuthSession?> restoreSession() => _sessionStore.readSession();

  Future<AuthSession> refreshSession() async {
    final session = await _requiredSession();
    return _refreshSessionFrom(session);
  }

  /// Runs one authenticated feature request with the current access token.
  ///
  /// Feature repositories use this narrow gateway instead of reading secure
  /// session storage themselves. A 401 [AppException] follows the same
  /// refresh-and-retry path as the account requests above.
  Future<T> withAccessToken<T>(
    Future<T> Function(String accessToken) operation,
  ) async {
    final originatingSession = await _requiredSession();
    return _withAuthenticatedSession(
      (session) => operation(session.accessToken),
      expectedParentId: originatingSession.parent.id,
    );
  }

  Future<ParentAccount?> currentParent() async {
    final session = await _sessionStore.readSession();
    if (session == null) {
      return null;
    }
    final originatingParentId = session.parent.id;

    final parent = await _withAuthenticatedSession(
      (activeSession) => _api.currentParent(activeSession.accessToken),
      expectedParentId: originatingParentId,
    );
    await _updateSession(
      (activeSession) => activeSession.copyWith(parent: parent),
      expectedParentId: originatingParentId,
    );
    return parent;
  }

  Future<List<KidProfile>> fetchKidProfiles() async {
    final originatingSession = await _requiredSession();
    final originatingParentId = originatingSession.parent.id;
    final rawProfiles = await _withAuthenticatedSession(
      (session) => _api.fetchKidProfiles(session.accessToken),
      expectedParentId: originatingParentId,
    );
    final updatedSession = await _updateSession((activeSession) {
      final profiles = rawProfiles
          .map((profile) => _ownedProfile(profile, activeSession.parent.id))
          .toList(growable: false);
      return activeSession.copyWith(profiles: profiles);
    }, expectedParentId: originatingParentId);
    return updatedSession.profiles;
  }

  /// Refreshes the backend-owned profile list, then resolves the currently
  /// selected child from that fresh list.
  ///
  /// We deliberately do not fall back to the first profile. If the selection
  /// is missing or was deleted elsewhere, callers receive `null`; a stale
  /// selected ID is also removed so it cannot silently resurrect later.
  Future<KidProfile?> refreshCurrentKid() async {
    final originatingSession = await _requiredSession();
    final originatingParentId = originatingSession.parent.id;
    final rawProfiles = await _withAuthenticatedSession(
      (session) => _api.fetchKidProfiles(session.accessToken),
      expectedParentId: originatingParentId,
    );

    return _withSessionMutationLock(() async {
      final activeSession = await _requiredSession();
      _requireExpectedParent(activeSession, originatingParentId);
      final profiles = rawProfiles
          .map((profile) => _ownedProfile(profile, activeSession.parent.id))
          .toList(growable: false);
      await _sessionStore.writeSession(
        activeSession.copyWith(profiles: profiles),
      );

      final selectedKidId = await _sessionStore.readSelectedKidId();
      if (selectedKidId == null || selectedKidId.isEmpty) {
        return null;
      }
      for (final profile in profiles) {
        if (profile.id == selectedKidId) {
          return profile;
        }
      }

      await _sessionStore.clearSelectedKidId();
      return null;
    });
  }

  Future<KidProfile> createKidProfile(CreateKidProfileRequest request) async {
    final originatingSession = await _requiredSession();
    final originatingParentId = originatingSession.parent.id;
    final createdProfile = await _withAuthenticatedSession(
      (session) => _api.createKidProfile(request, session.accessToken),
      expectedParentId: originatingParentId,
    );
    late KidProfile profile;
    await _updateSession((activeSession) {
      profile = _ownedProfile(createdProfile, activeSession.parent.id);
      return activeSession.copyWith(
        profiles: [...activeSession.profiles, profile],
      );
    }, expectedParentId: originatingParentId);
    await _writeSelectedKidForParent(profile.id, originatingParentId);
    return profile;
  }

  /// Updates an owned child profile and commits the returned backend identity
  /// to the cached session as one mutation. The selected child ID is left
  /// untouched, so editing the active profile cannot accidentally switch kids.
  Future<KidProfile> updateKidProfile({
    required String profileId,
    required String displayName,
    required String avatarKey,
  }) async {
    final normalizedProfileId = profileId.trim();
    final normalizedDisplayName = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .join(' ');
    final normalizedAvatarKey = avatarKey.trim();
    if (normalizedProfileId.isEmpty) {
      throw const AppException('Choose a child profile to update.');
    }
    if (normalizedDisplayName.isEmpty) {
      throw const AppException('Enter a name for this child profile.');
    }
    if (normalizedAvatarKey.isEmpty) {
      throw const AppException('Choose a character for this child profile.');
    }

    final originatingSession = await _requiredSession();
    final originatingParentId = originatingSession.parent.id;
    final backendProfile = await _withAuthenticatedSession(
      (session) => _api.updateKidProfile(
        profileId: normalizedProfileId,
        displayName: normalizedDisplayName,
        avatarKey: normalizedAvatarKey,
        accessToken: session.accessToken,
      ),
      expectedParentId: originatingParentId,
    );
    if (backendProfile.id != normalizedProfileId) {
      throw const AppException(
        'The service returned the wrong child profile. Please try again.',
      );
    }
    final profile = _ownedProfile(backendProfile, originatingParentId);

    await _updateSession((activeSession) {
      var replaced = false;
      final profiles = activeSession.profiles
          .map((cachedProfile) {
            if (cachedProfile.id != profile.id) {
              return cachedProfile;
            }
            replaced = true;
            return profile;
          })
          .toList(growable: true);
      if (!replaced) {
        // A successful parent-scoped PATCH is authoritative even when this
        // device's cached list was older than the backend.
        profiles.add(profile);
      }
      return activeSession.copyWith(
        profiles: List<KidProfile>.unmodifiable(profiles),
      );
    }, expectedParentId: originatingParentId);
    return profile;
  }

  Future<KidProfile?> currentKid() async {
    final session = await _sessionStore.readSession();
    final selectedKidId = await _sessionStore.readSelectedKidId();
    if (session == null || selectedKidId == null) {
      return null;
    }

    for (final profile in session.profiles) {
      if (profile.id == selectedKidId) {
        return profile;
      }
    }
    return null;
  }

  Future<void> selectKid(KidProfile profile) {
    return _sessionStore.writeSelectedKidId(profile.id);
  }

  Future<void> logout() async {
    final session = await _sessionStore.readSession();
    try {
      if (session != null &&
          session.accessToken.isNotEmpty &&
          session.refreshToken != null &&
          session.refreshToken!.isNotEmpty) {
        await _withAuthenticatedSession(
          (activeSession) => _api.logout(
            accessToken: activeSession.accessToken,
            refreshToken: activeSession.refreshToken!,
          ),
        );
      }
    } finally {
      await _clearSession();
    }
  }

  Future<AuthSession> _requiredSession() async {
    final session = await _sessionStore.readSession();
    if (session == null || session.accessToken.isEmpty) {
      throw const AppException('Please sign in as a parent to continue.');
    }
    return session;
  }

  Future<T> _withAuthenticatedSession<T>(
    Future<T> Function(AuthSession session) operation, {
    String? expectedParentId,
  }) async {
    final session = await _requiredSession();
    _requireExpectedParent(session, expectedParentId);
    try {
      return await operation(session);
    } on AppException catch (error) {
      if (error.statusCode != 401) {
        rethrow;
      }
    }

    await _refreshSessionFrom(session);

    // A different repository can complete another token rotation between the
    // refresh above and this retry. Always use the latest persisted session.
    var retrySession = await _requiredSession();
    _requireExpectedParent(retrySession, expectedParentId);
    while (true) {
      try {
        return await operation(retrySession);
      } on AppException catch (error) {
        if (error.statusCode != 401) {
          rethrow;
        }

        final replacement = await _newerSessionOrExpire(retrySession);
        if (replacement == null) {
          throw _sessionExpiredException;
        }
        _requireExpectedParent(replacement, expectedParentId);
        retrySession = replacement;
      }
    }
  }

  Future<AuthSession?> _newerSessionOrExpire(AuthSession rejectedSession) {
    return _withSessionMutationLock(() async {
      final current = await _sessionStore.readSession();
      if (current != null && !_hasSameCredentials(current, rejectedSession)) {
        return current;
      }
      await _sessionStore.clear();
      return null;
    });
  }

  Future<AuthSession> _refreshSessionFrom(AuthSession observedSession) async {
    final session = await _requiredSession();
    if (!_hasSameCredentials(session, observedSession)) {
      return session;
    }

    late final AuthSession sharedRefreshResult;
    try {
      sharedRefreshResult = await _coordinatedRefresh(session);
    } on AppException catch (error) {
      if (!_isAuthoritativeRefreshRejection(error)) {
        rethrow;
      }

      final replacement = await _withSessionMutationLock(() async {
        final current = await _sessionStore.readSession();
        if (current != null && !_hasSameCredentials(current, session)) {
          return current;
        }
        await _sessionStore.clear();
        return null;
      });
      if (replacement != null) {
        return replacement;
      }
      throw _sessionExpiredException;
    }

    // The shared result can have originated from another repository instance.
    // Keep this store's current account/profile metadata and apply only tokens.
    final refreshedSession = session.copyWith(
      accessToken: sharedRefreshResult.accessToken,
      refreshToken: sharedRefreshResult.refreshToken,
    );

    return _withSessionMutationLock(() async {
      final current = await _sessionStore.readSession();
      if (current == null) {
        throw const AppException('Please sign in as a parent to continue.');
      }
      if (!_hasSameCredentials(current, session)) {
        return current;
      }
      await _sessionStore.writeSession(refreshedSession);
      return refreshedSession;
    });
  }

  Future<AuthSession> _coordinatedRefresh(AuthSession session) {
    final refreshToken = session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      return _api.refresh(session);
    }

    final key = '${session.parent.id}:$refreshToken';
    final activeRefresh = _refreshesByToken[key];
    if (activeRefresh != null) {
      return activeRefresh;
    }

    late final Future<AuthSession> refresh;
    refresh = _api.refresh(session).whenComplete(() {
      if (identical(_refreshesByToken[key], refresh)) {
        _refreshesByToken.remove(key);
      }
    });
    _refreshesByToken[key] = refresh;
    return refresh;
  }

  Future<void> _writeSession(AuthSession session) {
    return _withSessionMutationLock(() => _sessionStore.writeSession(session));
  }

  Future<AuthSession> _updateSession(
    AuthSession Function(AuthSession current) update, {
    String? expectedParentId,
  }) {
    return _withSessionMutationLock(() async {
      final current = await _requiredSession();
      _requireExpectedParent(current, expectedParentId);
      final updated = update(current);
      await _sessionStore.writeSession(updated);
      return updated;
    });
  }

  Future<void> _writeSelectedKidForParent(
    String kidId,
    String expectedParentId,
  ) {
    return _withSessionMutationLock(() async {
      final current = await _requiredSession();
      _requireExpectedParent(current, expectedParentId);
      await _sessionStore.writeSelectedKidId(kidId);
    });
  }

  Future<void> _clearSession() {
    return _withSessionMutationLock(_sessionStore.clear);
  }

  static Future<T> _withSessionMutationLock<T>(Future<T> Function() mutation) {
    final result = Completer<T>();
    Future<void> run() async {
      try {
        final value = await mutation();
        final next = _releaseSessionMutation();
        result.complete(value);
        if (next != null) {
          unawaited(next());
        }
      } catch (error, stackTrace) {
        final next = _releaseSessionMutation();
        result.completeError(error, stackTrace);
        if (next != null) {
          unawaited(next());
        }
      }
    }

    if (_sessionMutationActive) {
      _sessionMutationQueue.add(run);
    } else {
      _sessionMutationActive = true;
      unawaited(run());
    }
    return result.future;
  }

  static Future<void> Function()? _releaseSessionMutation() {
    if (_sessionMutationQueue.isEmpty) {
      _sessionMutationActive = false;
      return null;
    }
    return _sessionMutationQueue.removeFirst();
  }

  static bool _hasSameCredentials(AuthSession left, AuthSession right) {
    return left.parent.id == right.parent.id &&
        left.accessToken == right.accessToken &&
        left.refreshToken == right.refreshToken;
  }

  static bool _isAuthoritativeRefreshRejection(AppException error) {
    return error.statusCode == 400 || error.statusCode == 401;
  }

  static void _requireExpectedParent(
    AuthSession session,
    String? expectedParentId,
  ) {
    if (expectedParentId != null && session.parent.id != expectedParentId) {
      throw _accountChangedException;
    }
  }

  static KidProfile _ownedProfile(KidProfile profile, String parentId) {
    if (profile.parentId.isNotEmpty && profile.parentId != parentId) {
      throw const AppException(
        'That child profile does not belong to the signed-in parent.',
        code: 'profile_owner_mismatch',
      );
    }
    return profile.parentId == parentId
        ? profile
        : profile.copyWith(parentId: parentId);
  }

  static const _sessionExpiredException = AppException(
    'Your parent session has expired. Please sign in again.',
    code: 'session_expired',
    statusCode: 401,
  );

  static const _accountChangedException = AppException(
    'The signed-in parent changed while this request was finishing. Please try again.',
    code: 'session_account_changed',
  );
}
