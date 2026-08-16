# fortune-mod source provenance

This directory preserves Cowsaver's imported `fortune-mod` 9708 source data. It is tracked in this repository for provenance and checksum verification; it is not copied into the `.saver` or `.app` bundle and is never loaded at runtime.

| Item | Value |
|---|---|
| Source | `fortune-mod` 9708 |
| Reference tarball | `https://www.ibiblio.org/pub/linux/games/amusements/fortune/fortune-mod-9708.tar.gz` |
| Reference SHA-256 | `1a98a6fd42ef23c8aec9e4a368afb40b6b0ddfb67b5b383ad82a7b78d8e0602a` |
| Imported data files | 35 |
| Separator-delimited entries | 13,387 |
| Non-empty records | 13,353 |
| Runtime records | none; see `../fortune-curated/` |

The separator count includes 34 empty entries. `manifest.tsv` records the byte count and SHA-256 digest of each imported data file; all 35 entries should match their committed files.

## Licence and scope

`LICENSE` and `debian-copyright.txt` are preserved with the import. Debian's copyright record declares BSD-4-clause terms with the advertising clause deleted for `Files: *`; Cowsaver relies on that package-level licensing record and does not relicense the data.

That record does not verify the copyright, attribution, wording, or public-domain status of each individual quotation. `notes-upstream.txt` contains fortune-mod's own warning about those limits. Cowsaver does not claim to have independently cleared or verified individual quotes.

## Curation and removals

The display corpus is separately maintained in `../fortune-curated/`. Quote-removal requests change that curated corpus and its curation record; this preserved import stays byte-for-byte unchanged. See `../fortune-curated/provenance.md`.

## Re-importing

`scripts/import-upstream-fortunes.sh` imports a local fortune-data directory and writes `manifest.tsv`. It records the data actually imported, but does not itself verify that its input came from the reference tarball above. Use it only with a separately verified `fortune-mod` 9708 source directory, then compare the resulting checksums with the committed manifest.
