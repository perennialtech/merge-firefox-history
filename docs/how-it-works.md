# How it works

Developer notes for `merge-firefox-history.sh`: the tables it touches, how rows
are matched, and which schemas are supported. See the [README](../README.md)
for usage.

## Schema support

The Places schema is discovered at runtime, so the script works with the
current schema (tested with Firefox 157, Places schema version 87) and with
much older profiles. Fields that are missing on either side are skipped.

The merged database keeps the schema version of the target. Open Firefox
afterwards and it recalculates frecency.

## What gets merged

- `moz_places` (URLs, titles, visit counts, frecency, GUIDs, origins)
- `moz_historyvisits` (individual visits, including redirects and visit types)
- `moz_origins`
- `moz_inputhistory` (address bar history, highest use count wins)
- `moz_places_metadata` (view time, key presses, scrolling, …) when present

## Matching and deduplication

Places are matched by URL, and existing target rows are never duplicated, while
visits are deduplicated by `(place, visit_date)`. GUIDs from the source are kept
unless they are invalid or already in use, in which case a new valid GUID is
generated. The `visit_count`, `last_visit_date` and `foreign_count` counters are
recalculated with the same rules Firefox uses, and frecency is marked for
recalculation so that Firefox refreshes it on idle.

## URL hashes

Firefox stores a 48-bit hash of the URL in `moz_places.url_hash` and uses it
for lookups. Rows merged from a profile that predates that column have no
hash, and Firefox fills them in during its (at most daily) idle maintenance.

When `python3` is available the script calculates the hashes immediately,
mirroring `PlacesHashString()`/`HashURL()` in
`toolkit/components/places/Helpers.cpp`. The implementation is verified
against real databases.

## Not merged, on purpose

Favicons live in `favicons.sqlite`, a separate database, and bookmarks,
keywords and annotations fall outside a history merge. Sync metadata
(`moz_places_extra`, `moz_historyvisits_extra`) and new-tab interaction
statistics are also left out, because merging them between two Sync
accounts/profiles could cause duplicated uploads or misleading statistics.
