import 'package:flutter/material.dart';

import '../../../app/router.dart';
import '../../../core/errors/app_exception.dart';

/// Returns a parent to sign-in after the server authoritatively rejects the
/// refresh token. Retryable connectivity failures deliberately stay in place.
bool returnToSignInIfSessionExpired(BuildContext context, AppException error) {
  if (error.code != 'session_expired' &&
      error.code != 'authentication_required') {
    return false;
  }

  Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
  return true;
}
