import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One consistent secure-storage configuration for every Kingdom Kids key.
///
/// Version 10 can still read and migrate the legacy ciphers used by version 9.
/// Crash-resistant migration backups are temporary and remain inside the
/// app-private storage that Android backup/device transfer excludes.
const kingdomKidsSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(migrateWithBackup: true),
);
