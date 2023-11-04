#!/bin/sh

# merge-firefox-history <db1> <db2>

# Check for exactly two arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <db1> <db2>"
    exit 1
fi

# Ensure both arguments are files that exist
if [ ! -f "$1" ] || [ ! -f "$2" ]; then
    echo "Both arguments must be valid files."
    exit 1
fi

# Start transaction to ensure atomicity
(
# Calculate the offset to ensure unique IDs
offset=$(sqlite3 "$1" "select ifnull(max(id), 0) + 1 from moz_historyvisits;")
if [ $? -ne 0 ]; then
    echo "Error calculating offset from $1"
    exit 1
fi

# Execute SQLite commands
sqlite3 "$1" <<EOF
BEGIN TRANSACTION;

attach "$2" as db2;

-- Insert or ignore to prevent conflicts with existing records
insert or ignore into moz_places(url,title,visit_count,hidden,typed,frecency,last_visit_date)
select url,title,visit_count,hidden,typed,frecency,last_visit_date from db2.moz_places;

-- Create a view to prepare for history visits insertion
create view if not exists db2.v1 as
select db2.moz_places.url, db2.moz_historyvisits.id, db2.moz_historyvisits.from_visit, db2.moz_historyvisits.visit_date
from db2.moz_places
inner join db2.moz_historyvisits on db2.moz_places.id = db2.moz_historyvisits.place_id;

-- Temporary table for adjusted IDs and visit dates, without setting a primary key
create temporary table if not exists t1(place_id integer, url longvarchar, id integer, from_visit integer, visit_date integer);

-- Insert into the temporary table, adjusting IDs and from_visit values
insert into t1(place_id, id, from_visit, visit_date)
select moz_places.id, db2.v1.id + $offset,
       case when db2.v1.from_visit = 0 then 0 else db2.v1.from_visit + $offset end,
       db2.v1.visit_date
from moz_places
inner join db2.v1 on moz_places.url = db2.v1.url;

-- Insert into the history visits, using the adjusted values from the temporary table
insert or ignore into moz_historyvisits(place_id, id, from_visit, visit_date, visit_type, session)
select place_id, id, from_visit, visit_date, 2, 0 from t1;

COMMIT;

-- Clean up: drop the view and temporary table
drop view if exists db2.v1;
drop table if exists t1;

EOF
) || {
    echo "An error occurred. Rolling back transaction."
    sqlite3 "$1" "ROLLBACK;"
    exit 1
}
