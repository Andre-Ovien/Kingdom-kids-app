# Source publication boundaries

This repository contains application source and approved app assets, not a
machine backup. The root `.gitignore` keeps generated dependencies, build output,
recordings/uploads, private environment files, databases/journals/backups,
signing material and local review evidence out of future commits. It does not
delete those local files and does not remove anything already tracked.

Retain backend Python/migrations/tests and default-OFF financial/media settings;
exact release metadata and Cloudinary map; mobile Dart/native projects, bundled
assets, fonts, engine assets and lockfiles; website source/public assets and
lockfiles; authored Motion scripts, `.blend` sources, source assets, provenance
and licence files; and `docs/design-archive` source snapshots/restore notes.
Blender `.blend1`/numbered backups, rendered frames/reviews and installed
`node_modules` are excluded. Do not ignore all images, audio, video, GLBs or
`.blend` files: legitimate source assets use those extensions.

The local Ark Elephant preview's `assets/` directory consists of generated
symlink mounts, including absolute and outside-project targets. It is excluded;
its Dart/tool source remains. On another machine, recreate preview mounts only
from vetted canonical app model assets or an explicitly supplied local
background. Do not turn absolute local symlinks into copied private files during
publication. The shipping `Frontend/mobile/assets/` tree is retained.

The frozen narration and Cloudinary JSON files are metadata, not credentials.
Private original narration remains in `Backend/media`/external storage and is
not published here. Canonical authenticated object identifiers are not expiring
bearer delivery URLs. Never copy signed URLs, API secrets, device captures,
provider receipts, saved sessions or `.env` contents from `output` into docs.
Useful output-only tools can be promoted separately after source/secret review;
forcing the whole evidence directory into Git is not a source backup strategy.

## Publication review

The publication owner must verify the authenticated identity, exact destination
repository/visibility and Render's connected repository ID. The selected Render
provider label alone does not establish that an existing organization remote
and a similarly named personal repository are the same resource.

A metadata-only preparation scan found no tracked credential/database paths
(other than the intentionally tracked `.env.example`). That is a filename
check, **not** a claim that source history or file contents contain no secrets.
Before publishing, the owner must inspect the actual staged name/size list and
perform a redacted secret scan. Do not print found values or rewrite history as
an automatic cleanup action. Ignore rules do not affect existing tracked data.

The retained candidate tree is approximately 1 GB uncompressed, mainly authored
Motion files and bundled app artwork. No retained file exceeds 100 MiB. The
largest authored Blender source exceeds 50 MiB, so an ordinary Git push can warn
about that file; LFS was not configured or installed by this preparation.
[GitHub documents its file limits and repository-size recommendations](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github).
Do not silently drop authored source to shrink the repository. A future explicit
asset/LFS migration should preserve restoration and provenance.

Preserve third-party licence/provenance files alongside vendored source/assets;
the root project licence does not replace them. Publishing paid-content source
or bundled media into a public repository exposes those bytes independently of
Cloudinary authentication. Confirm intended repository visibility and existing
rights decisions before treating private delivery as a content boundary.

## Suggested commit groups

1. Repository ignore rules, deployment/publication documentation and reviewed
   source metadata.
2. Backend source, migrations, disabled-by-default billing/media/website paths,
   tests, pinned requirements and restrictive container packaging.
3. Approved mobile UI/game/native source, bundled assets, fonts and lockfiles.
4. Website source/public assets and package lockfile.
5. Motion authoring/source assets with licences and design restoration notes.

These are organizational recommendations, not staging instructions. The
publication owner decides whether to use separate commits or one coherent
reviewed snapshot. This preparation performs no staging, branch, commit, push,
credential/account, deployment or live-database action.
