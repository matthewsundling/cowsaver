# curated fortune provenance

This directory is Cowsaver's runtime quote corpus: 3,470 selected records derived from the preserved `fortune-mod` 9708 import in `../fortune-upstream/`.

| Count | Meaning |
|---|---|
| 13,387 | Separator-delimited entries in the 35-file upstream import, including 34 empty entries. |
| 13,353 | Non-empty upstream records represented by `curation.tsv`. |
| 3,470 | Final curated records in `fortunes`; all load and display at the default settings. |

`curation.tsv` has one row for each non-empty source record. It records whether each source record was retained or excluded, with a reason; its retain-row count matches the records in `fortunes`. `final-corpus-trim` identifies records omitted when the initial editorial selection was reduced to the final runtime corpus. The `body-size-weight-or-diet-humor` reason identifies 23 records removed in the 2026-08-16 content pass; it covers jokes and wordplay about body size, weight, dieting, calories, fattening, and appetite.

## Licence and attribution

The records remain under the BSD terms in `license.txt`; Cowsaver does not relicense them. The source package's full provenance and checksums are in `../fortune-upstream/`.

fortune-mod warns that its quotations were collected from many sources and that attribution and exact wording cannot be meaningfully verified. A displayed attribution is not evidence that the named person said the words. The source package's own warning is preserved in `../fortune-upstream/notes-upstream.txt`.

## Removal requests

If a quotation is misattributed, misquoted, or you hold rights to it and want it removed, open an issue. Cowsaver will remove it from `fortunes`, change the corresponding `curation.tsv` row to `exclude` with a dated removal reason, and keep the preserved upstream import unchanged.
