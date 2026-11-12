# One-time private test-family transfer

This administrative mechanism transfers one explicitly approved, verified,
nonprivileged local test parent and exactly three child profiles. It is not a
public API, signup bypass, full database restore, or general migration job.
Without `KK_TEST_FAMILY_IMPORT_ZLIB_B64`, deployment does not invoke it.

The exporter reads SQLite in a read-only transaction. It selects only the
explicit email's family, stores the existing encoded password (never the
plaintext password), and excludes other users, privileges, groups, tokens,
challenges and billing records. Its destination must be below ignored `output/`;
the directory is mode `0700` and both files are created exclusively as `0600`.
Compressed base64 is still sensitive data: never put either file in Git, a
build context, tickets, command output, or chat.

Set `KK_TEST_FAMILY_EXPORT_EMAIL` privately to the approved address, then run:

```sh
python Backend/scripts/export_private_test_family.py Backend/Core/db.sqlite3 output/private-family-transfer/private
```

The script prints sanitized sizes/counts only. It creates `family.json` and
`render-private-env.json`; the latter contains the three private Render values:

- `KK_TEST_FAMILY_IMPORT_ZLIB_B64`
- `KK_TEST_FAMILY_IMPORT_SHA256`
- `KK_TEST_FAMILY_IMPORT_EMAIL`

The exact staging hostname is checked by the command. Payload v1 expires two
hours after export for a first application, is limited to 2 MiB expanded JSON
and 90,000 encoded characters, and requires its exact digest, target email,
version, schema and service binding. The private environment values are read
only server-side and removed from the startup process before Gunicorn executes.
The saved Render configuration must still be removed by the operator afterward.

Validate the payload against a fresh disposable migrated database first. From
`Backend/`, the command defaults to rollback-only validation:

```sh
python Core/manage.py install_private_test_family --dry-run
```

Its dry run performs transactional validation and rolls back family rows; a
PostgreSQL sequence may advance. It reports no credential values. Explicit
`--apply` is required for a committed transfer. Normal Render startup calls it
with `apply=True` only when the private payload variable exists, after migrations
and the approved matching/media installers, under the existing PostgreSQL
release lock. No database credentials need to be put into the repository.

The transfer creates a new parent primary key and preserves child UUIDs,
preferences, progress, attempt/activity operations, receipts and timestamps.
Story and game UUIDs are resolved by slug; levels by `(game.slug, level_number)`.
All referenced rule snapshots and story text hashes must match. A missing or
conflicting reference, existing target email, child/history UUID collision or
invalid row aborts the complete transaction. Historical hidden/retired content
can be referenced without republishing it. There is no overwrite or merge mode.

A durable receipt stores only the import UUID, payload digest, parent link and
completion timestamp. Replaying the identical completed import is a no-op,
including after expiry or parent deletion; it never restores old passwords or
resurrects deleted accounts. A changed payload with the same import UUID is
rejected. After the operator verifies the completed counts and the parent's
normal sign-in, remove all three private variables from Render and redeploy.
Keep/delete the local private files according to the owner's handoff decision.
