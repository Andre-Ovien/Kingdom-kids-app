import 'dart:async';
import 'dart:collection';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/feature_read_cache.dart';
import '../../../core/network/feature_view_state_cache.dart';
import '../domain/auth_requests.dart';
import '../domain/auth_session.dart';
import '../domain/email_verification.dart';
import '../domain/kid_profile.dart';
import '../domain/parent_account.dart';
import '../domain/password_reset.dart';
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
  // Repositories share the device's session storage. An explicit sign-in is a
  // new session even for the same parent; routine token rotation is not.
  static int _signInGeneration = 0;

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

  Future<PendingPasswordReset> requestPasswordReset(
    PasswordResetRequest request,
  ) {
    return _api.requestPasswordReset(request);
  }

  /// Proves the recovery code without changing credentials or local sign-in.
  Future<void> verifyPasswordResetCode(PasswordResetVerifyRequest request) =>
      _api.verifyPasswordResetCode(request);

  Future<void> confirmPasswordReset(PasswordResetConfirmRequest request) async {
    final origin = await _withSessionMutationLock(() async {
      final session = await _sessionStore.readSession();
      return (session: session, signInGeneration: _signInGeneration);
    });
    await _api.confirmPasswordReset(request);
    await _withSessionMutationLock(() async {
      // Recovery may finish after the adult left this flow and signed in
      // again. Clear only its original session, never that newer sign-in.
      if (_signInGeneration != origin.signInGeneration) return;
      final current = await _sessionStore.readSession();
      if (current != null && current.parent.id != origin.session?.parent.id) {
        return;
      }
      await _sessionStore.clear();
      _invalidateFeatureIdentity();
    });
  }

  Future<AuthSession> login(LoginRequest request) async {
    final session = await _api.login(request);
    await _writeSession(session);
    return session;
  }

  /// Rechecks the parent password without exposing the cached email address to
  /// presentation code.
  ///
  /// Login can issue a complete replacement token pair, but it must never be
  /// allowed to switch accounts behind an already-open parent gate. The
  /// backend identity and the still-active local identity are both verified
  /// before fresh credentials are persisted.
  Future<void> reauthenticate(String password) async {
    if (password.isEmpty) {
      throw const AppException(
        'Enter the parent password to continue.',
        code: 'parent_password_required',
      );
    }

    final observedSession = await _requiredSession();
    final expectedParentId = observedSession.parent.id;
    final cachedEmail = observedSession.parent.email.trim();
    if (expectedParentId.isEmpty || cachedEmail.isEmpty) {
      throw const AppException(
        'Please sign in as a parent to continue.',
        code: 'authentication_required',
        statusCode: 401,
      );
    }

    late final AuthSession reauthenticatedSession;
    try {
      reauthenticatedSession = await _api.login(
        LoginRequest(email: cachedEmail, password: password),
      );
    } on AppException catch (error) {
      if (error.code != 'invalid_credentials') {
        rethrow;
      }
      throw const AppException(
        'That password did not match. Please try again.',
        code: 'invalid_parent_password',
      );
    }

    if (reauthenticatedSession.parent.id != expectedParentId) {
      throw _accountChangedException;
    }

    await _withSessionMutationLock(() async {
      final current = await _requiredSession();
      _requireExpectedParent(current, expectedParentId);
      if (reauthenticatedSession.parent.id != current.parent.id) {
        throw _accountChangedException;
      }

      // Preserve metadata that may have been refreshed by another request
      // while the password check was in flight, and replace credentials only.
      await _sessionStore.writeSession(
        AuthSession(
          parent: current.parent,
          accessToken: reauthenticatedSession.accessToken,
          refreshToken: reauthenticatedSession.refreshToken,
          profiles: current.profiles,
        ),
      );
    });
  }

  Future<AuthSession?> restoreSession() => _sessionStore.readSession();

  /// Stable across token rotation, separate for every explicit sign-in, backend,
  /// family, child and avatar. UI state stores only non-sensitive preferences.
  Future<Object?> featureCacheScope() => _withSessionMutationLock(() async {
    final session = await _sessionStore.readSession();
    if (session == null || session.accessToken.isEmpty) return null;
    final childId = await _sessionStore.readSelectedKidId();
    final child = session.profiles
        .where((profile) => profile.id == childId)
        .firstOrNull;
    return (
      _api is HttpAuthApi ? _api.baseUrl : _api,
      session.parent.id,
      childId,
      child?.avatarKey,
      _signInGeneration,
    );
  });

  /// Caches only successful, parsed read models, and rechecks ownership after
  /// both cache hits and network responses. Never use for account or paid status.
  Future<T> withCachedFeatureRead<T>(
    Object key,
    Future<T> Function(String token) operation, {
    Duration maxAge = const Duration(minutes: 1),
    DateTime? Function(T value)? expiresAt,
    bool progressIndependent = false,
  }) async {
    Object? scope;
    try {
      scope = await featureCacheScope();
    } catch (_) {
      return withAccessToken(operation);
    }
    if (scope == null) return withAccessToken(operation);
    final generation = progressIndependent
        ? featureReadCache.mediaGeneration
        : featureReadCache.generation;
    final value = await featureReadCache.read<T>(
      (scope, key),
      () async {
        final result = await withAccessToken(operation);
        if (scope != await featureCacheScope()) throw _accountChangedException;
        return result;
      },
      maxAge: maxAge,
      expiresAt: expiresAt,
      progressIndependent: progressIndependent,
    );
    if (scope != await featureCacheScope()) throw _accountChangedException;
    if (generation !=
        (progressIndependent
            ? featureReadCache.mediaGeneration
            : featureReadCache.generation)) {
      return withCachedFeatureRead(
        key,
        operation,
        maxAge: maxAge,
        expiresAt: expiresAt,
        progressIndependent: progressIndependent,
      );
    }
    return value;
  }

  void invalidateFeatureReads({bool includeMedia = true}) =>
      featureReadCache.invalidate(includeMedia: includeMedia);

  /// Refreshes one denied/expired media record without invalidating unrelated
  /// content or an active narration download for this same family.
  Future<T> withFreshFeatureRead<T>(
    Future<T> Function(String token) operation,
  ) async {
    final scope = await featureCacheScope();
    final result = await withAccessToken(operation);
    if (scope != await featureCacheScope()) throw _accountChangedException;
    return result;
  }

  void _invalidateFeatureIdentity() {
    invalidateFeatureReads();
    featureViewStateCache.clearIdentity();
  }

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
    if (parent.id != originatingParentId) {
      throw _accountChangedException;
    }
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
      (session) => _api.fetchKidProfiles(
        session.accessToken,
        expectedParentId: originatingParentId,
      ),
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
      (session) => _api.fetchKidProfiles(
        session.accessToken,
        expectedParentId: originatingParentId,
      ),
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
      _invalidateFeatureIdentity();
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
      final existingIndex = activeSession.profiles.indexWhere(
        (cached) => cached.id == profile.id,
      );
      final profiles = activeSession.profiles
          .where((cached) => cached.id != profile.id)
          .toList(growable: true);
      // An operation_id replay returns the same backend identity. Upsert it
      // at its original position, also removing any older duplicate copies.
      profiles.insert(
        existingIndex < 0 ? profiles.length : existingIndex,
        profile,
      );
      return activeSession.copyWith(
        profiles: List<KidProfile>.unmodifiable(profiles),
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
    _invalidateFeatureIdentity();
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

  /// Permanently deletes the signed-in parent account after backend password
  /// reauthentication. Local credentials are cleared only after the server
  /// confirms deletion, so validation or connectivity failures remain
  /// recoverable on this device.
  Future<void> deleteAccount({required String password}) async {
    if (password.isEmpty) {
      throw const AppException(
        'Enter your current password to delete this account.',
        code: 'current_password_required',
      );
    }

    final originatingSession = await _requiredSession();
    final originatingParentId = originatingSession.parent.id;
    await _withAuthenticatedSession(
      (session) => _api.deleteAccount(
        password: password,
        accessToken: session.accessToken,
      ),
      expectedParentId: originatingParentId,
    );
    await _clearDeletedAccountSession(originatingParentId);
  }

  Future<void> selectKid(KidProfile profile) {
    final profileId = profile.id.trim();
    if (profileId.isEmpty) {
      throw const AppException(
        'Choose a child profile from this family.',
        code: 'profile_not_in_session',
      );
    }

    return _withSessionMutationLock(() async {
      final current = await _requiredSession();
      final isCurrentMember = current.profiles.any(
        (cachedProfile) => cachedProfile.id == profileId,
      );
      if (!isCurrentMember) {
        throw const AppException(
          'That child profile is not available for this family.',
          code: 'profile_not_in_session',
        );
      }
      if (await _sessionStore.readSelectedKidId() != profileId) {
        _invalidateFeatureIdentity();
      }
      await _sessionStore.writeSelectedKidId(profileId);
    });
  }

  Future<void> logout() async {
    final origin = await _withSessionMutationLock(() async {
      final session = await _sessionStore.readSession();
      return (session: session, signInGeneration: _signInGeneration);
    });
    final session = origin.session;
    try {
      if (session != null &&
          session.accessToken.isNotEmpty &&
          session.refreshToken != null &&
          session.refreshToken!.isNotEmpty) {
        await _withAuthenticatedSession((activeSession) {
          if (_signInGeneration != origin.signInGeneration) {
            throw _accountChangedException;
          }
          return _api.logout(
            accessToken: activeSession.accessToken,
            refreshToken: activeSession.refreshToken!,
          );
        }, expectedParentId: session.parent.id);
      }
    } finally {
      await _withSessionMutationLock(() async {
        if (_signInGeneration != origin.signInGeneration) return;
        final current = await _sessionStore.readSession();
        if (current == null ||
            (session != null && current.parent.id == session.parent.id)) {
          await _sessionStore.clear();
          _invalidateFeatureIdentity();
        }
      });
    }
  }

  Future<AuthSession> _requiredSession() async {
    final session = await _sessionStore.readSession();
    if (session == null || session.accessToken.isEmpty) {
      throw const AppException(
        'Please sign in as a parent to continue.',
        code: 'authentication_required',
        statusCode: 401,
      );
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
      _invalidateFeatureIdentity();
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
        _invalidateFeatureIdentity();
        return null;
      });
      if (replacement != null) {
        return replacement;
      }
      throw _sessionExpiredException;
    }

    // The shared result can have originated from another repository instance.
    // Keep this store's current account/profile metadata and apply only tokens.
    return _withSessionMutationLock(() async {
      final current = await _sessionStore.readSession();
      if (current == null) {
        throw const AppException(
          'Please sign in as a parent to continue.',
          code: 'authentication_required',
          statusCode: 401,
        );
      }
      if (!_hasSameCredentials(current, session)) {
        return current;
      }
      final refreshedSession = current.copyWith(
        accessToken: sharedRefreshResult.accessToken,
        refreshToken: sharedRefreshResult.refreshToken,
      );
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
    return _withSessionMutationLock(() async {
      await _sessionStore.writeSession(session);
      _signInGeneration += 1;
      _invalidateFeatureIdentity();
    });
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
      _invalidateFeatureIdentity();
      await _sessionStore.writeSelectedKidId(kidId);
    });
  }

  Future<void> _clearDeletedAccountSession(String expectedParentId) {
    return _withSessionMutationLock(() async {
      final current = await _sessionStore.readSession();
      if (current != null) {
        _requireExpectedParent(current, expectedParentId);
      }
      await _sessionStore.clear();
      _invalidateFeatureIdentity();
    });
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
