/// An in-memory routing ticket for a startup access check that needed plans.
/// It contains no credentials and is never accepted from links or persisted.
class HostedStartupAccessRecovery {
  const HostedStartupAccessRecovery({
    required this.parentId,
    required this.ownerScope,
  });

  final String parentId;
  final Object ownerScope;
}
