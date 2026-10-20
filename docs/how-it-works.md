# How it works

Developer notes for `merge-firefox-history.sh`: the tables it touches, how rows
are matched, and which schemas are supported. See the [README](../README.md)
for usage.

## Schema support

The Places schema is discovered at runtime, so the script works with the
current schema (tested with Firefox 157, Places schema version 87) and with
older profiles that still have the core Places tables. Columns shared by
`moz_places` and `moz_historyvisits` are copied dynamically; columns missing
on either side are skipped. The `moz_places_metadata` merge is deliberately
stricter: it requires the complete modern eleven-column layout plus the
`moz_places_metadata_search_queries.terms` column, and is skipped otherwise.

The merged database keeps the schema version of the target. Open Firefox
afterwards and it recalculates frecency. Targets with `recalc_frecency` /
`recalc_alt_frecency` are marked for recalculation. Older targets use the
pre-Places-70 convention instead: `frecency = -1` on affected places and
origins requests recalculation.

## What gets merged

- `moz_places` (URLs, titles, visit counts, frecency, GUIDs, origins)
- `moz_historyvisits` (individual visits, including redirects and visit types)
- `moz_origins`
- `moz_inputhistory` (address bar history, highest use count wins)
- `moz_places_metadata` (view time, key presses, scrolling, …) when present

## Matching and deduplication

Places are matched by URL, and existing target rows are never duplicated. If a
source database contains several places with the same URL, the lowest source
id is used.

Visits are deduplicated by `(destination place, visit_date)`. This includes
duplicates within the source database, not just visits that already exist in
the target. The lowest source visit id for a pair is retained, and references
from `from_visit` are mapped to the retained visit (or to the existing target
visit when the pair was already present). The choice is deterministic, so
repeating an import does not keep adding data.

GUIDs from the source are kept unless they are invalid or already in use, in
which case a new valid GUID is generated. The `visit_count`, `last_visit_date`
and `foreign_count` counters are recalculated with the same rules Firefox uses,
and frecency is marked for recalculation so that Firefox refreshes it on idle.

## URL hashes

Firefox stores a 48-bit hash of the URL in `moz_places.url_hash` and uses it
for lookups. Rows merged from a profile that predates that column have no
hash, and Firefox fills them in during its (at most daily) idle maintenance.

When `python3` is available the script calculates the hashes immediately,
mirroring `PlacesHashString()`/`HashURL()` in
`toolkit/components/places/Helpers.cpp`. The test suite contains fixed
reference vectors for ASCII, non-ASCII, prefix, and length-limit cases, so the
implementation is checked on every CI run rather than only against a live
profile.

## Not merged, on purpose

Favicons live in `favicons.sqlite`, a separate database, and bookmarks,
keywords and annotations fall outside a history merge. Sync metadata
(`moz_places_extra`, `moz_historyvisits_extra`) and new-tab interaction
statistics are also left out, because merging them between two Sync
accounts/profiles could cause duplicated uploads or misleading statistics.
