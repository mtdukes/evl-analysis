-- We now have updated isochrones for 0.5 values up to 20 miles out 
-- from each of the 580 polling sites
-- Dropped all our old tables so we don't get interference.
-- Ran loadIsochrones.py to import our shapes

-- turn on timing
\timing

-- let's export our new isochrones:
COPY isochrones TO '/Users/mtdukes/Dropbox/projects/wral/electionland/data/early-voting/evl-analysis/isochrones.csv' DELIMITER ',' CSV HEADER;
-- Copied 23,200 rows (580*40) successfully

-- check our nulls again
SELECT SUM(CASE WHEN latitude ~ '^[0-9\.]+$' THEN 1 ELSE 0 END) AS valid_coords,
COUNT(latitude) AS reg_voters,
round(round(SUM(CASE WHEN latitude ~ '^[0-9\.]+$' THEN 1 ELSE 0 END) / COUNT(latitude)::numeric,3)*100::numeric,1) AS pct_valid
FROM voters;
/*
 valid_coords | reg_voters | pct_valid 
--------------+------------+-----------
      6288324 |    6433969 |      97.7
(1 row)

Time: 32083.728 ms (00:32.084)
*/

-- produces list of all isochrones that intersect with all voters
CREATE TABLE distances AS
SELECT voters.gid AS voter_id,
isochrones.ogc_fid AS iso_id,
isochrones.group_index AS county_id,
isochrones.value AS km_value,
isochrones.site_id,
isochrones.year,
isochrones.mile_value
FROM voters
INNER JOIN isochrones
ON ST_Within(voters.the_geom, isochrones.wkb_geometry)
AND voters.county_id = isochrones.group_index;

/*
SELECT 1666426265
Time: 29772034.102 ms (08:16:12.034)
*/

-- Old methods of deduplicating didn't work because the data
-- are too large, so following instrucstions here:
-- https://www.periscopedata.com/blog/first-row-per-group-5x-faster

-- Start by indexing the values based on what we're deduplicting for
-- This took about two hours
create index iso_idx on
distances (voter_id, mile_value, iso_id);

-- deduplicate and filter values for 2014
CREATE TABLE iso_2014 AS
SELECT DISTINCT ON (voter_id) *
FROM distances
WHERE year = '2014'
ORDER BY voter_id, mile_value, iso_id;

/*
SELECT 6260641
Time: 6583903.012 ms (01:49:43.903)
*/

-- Grab a few test columns to see if it worked
SELECT *
FROM iso_2014
WHERE voter_id = 5644786 OR voter_id = 4488888 OR voter_id = 5663736
ORDER BY voter_id, mile_value;

/*
 voter_id | iso_id | county_id | km_value | site_id | year | mile_value 
----------+--------+-----------+----------+---------+------+------------
  4488888 |  16417 | 68        | 13679.39 | 261     | 2014 |        8.5
  5644786 |  21410 | 92        |   8046.7 | 337     | 2014 |          5
  5663736 |  21685 | 92        |  4023.35 | 344     | 2014 |        2.5
*/

-- do the same for 2018
CREATE TABLE iso_2018 AS
SELECT DISTINCT ON (voter_id) *
FROM distances
WHERE year = '2018'
ORDER BY voter_id, mile_value, iso_id;

/*
SELECT 6233019
Time: 5753083.587 ms (01:35:53.084)
*/

-- before we do the join, let's index
CREATE INDEX idx14
ON iso_2014 (voter_id);

/*
CREATE INDEX
Time: 5403.603 ms (00:05.404)
*/

CREATE INDEX idx18
ON iso_2018 (voter_id);

/*
CREATE INDEX
Time: 5056.372 ms (00:05.056)
*/

-- and do part 1 of the big join - 9:53
CREATE TABLE voters_p1 AS
SELECT voters.*,
iso_2014.iso_id AS iso_2014_id,
iso_2014.mile_value AS iso_2014_dist
FROM voters
LEFT JOIN iso_2014
ON iso_2014.voter_id = voters.gid;

/*
SELECT 6433969
Time: 211607.494 ms (03:31.607)
*/

-- then part 2 of the big join
CREATE TABLE voters_p2 AS
SELECT voters_p1.*,
iso_2018.iso_id AS iso_2018_id,
iso_2018.mile_value AS iso_2018_dist
FROM voters_p1
LEFT JOIN iso_2018
ON iso_2018.voter_id = voters_p1.gid;

/*
SELECT 6433969
Time: 169051.564 ms (02:49.052)
*/

-- to clean up, let's drop our p1 table
DROP TABLE voters_p1;

-- and rename our final table
ALTER TABLE voters_p2
RENAME TO voters_iso;

-- add our difference column
ALTER TABLE voters_iso
ADD COLUMN
dist_diff integer;

-- calculate our new column
UPDATE voters_iso
SET
dist_diff = iso_2018_dist - iso_2014_dist
WHERE iso_2014_dist IS NOT null AND iso_2018_dist IS NOT NULL;

/*
UPDATE 6225999
Time: 127588.863 ms (02:07.589)
*/

-- calculate new column to indicate nulls
ALTER TABLE voters_iso
ADD COLUMN
coord_null integer;

UPDATE voters_iso
SET
coord_null =
CASE WHEN latitude ~ '^[0-9\.]+$' THEN 0 ELSE 1
END;

/*
UPDATE 6433969
Time: 149103.359 ms (02:29.103)
*/

SELECT SUM(coord_null)
FROM voters_iso;

-- Export the voter file
COPY voters_iso TO '/Users/mtdukes/Dropbox/projects/wral/electionland/data/early-voting/evl-analysis/voters_iso.csv' DELIMITER ',' CSV HEADER;

-- Report out our null values
SELECT
COUNT(gid) AS reg_voters,
SUM(coord_null) AS no_coords,
round(round(SUM(coord_null) / COUNT(gid)::numeric,3)*100::numeric,1) AS pct_null_coords,
SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END) - SUM(coord_null) AS out_of_range,
round(round((SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END)- SUM(coord_null)) / COUNT(dist_diff)::numeric,3)*100::numeric,1) AS pct_valid
FROM voters_iso;

/*
 reg_voters | no_coords | pct_null_coords | out_of_range | pct_valid 
------------+-----------+-----------------+--------------+-----------
    6433969 |    145645 |             2.3 |        62325 |       1.0
(1 row)

Time: 33403.577 ms (00:33.404)
*/

-- Export the isochrones
COPY isochrones TO '/Users/mtdukes/Dropbox/projects/wral/electionland/data/early-voting/evl-analysis/isochrones-hifi.csv' DELIMITER ',' CSV HEADER;