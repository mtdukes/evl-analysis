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
dist_diff double precision;

-- show columns
\d voters_iso

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
round(round((SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END)- SUM(coord_null)) / COUNT(dist_diff)::numeric,3)*100::numeric,1) AS pct_invalid
FROM voters_iso;

/*
 reg_voters | no_coords | pct_null_coords | out_of_range | pct_invalid 
------------+-----------+-----------------+--------------+-----------
    6433969 |    145645 |             2.3 |        62325 |       1.0
(1 row)

Time: 33403.577 ms (00:33.404)
*/

-- Report out our null values by county
SELECT
county_desc,
COUNT(gid) AS reg_voters,
SUM(coord_null) AS no_coords,
round(round(SUM(coord_null) / COUNT(gid)::numeric,3)*100::numeric,1) AS pct_null_coords,
SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END) - SUM(coord_null) AS out_of_range,
round(round((SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END)- SUM(coord_null)) / COUNT(county_desc)::numeric,3)*100::numeric,1) AS pct_oor,
round(round(SUM(coord_null) / COUNT(gid)::numeric,3)*100::numeric,1) + round(round((SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END)- SUM(coord_null)) / COUNT(county_desc)::numeric,3)*100::numeric,1) AS total_invalid
FROM voters_iso
GROUP BY county_desc
ORDER BY total_invalid DESC;

/*
 county_desc  | reg_voters | no_coords | pct_null_coords | out_of_range | pct_oor | total_invalid 
--------------+------------+-----------+-----------------+--------------+---------+---------------
 HYDE         |       3421 |       131 |             3.8 |          950 |    27.8 |          31.6
 BERTIE       |      14173 |      1173 |             8.3 |         1908 |    13.5 |          21.8
 DARE         |      29954 |      5142 |            17.2 |         1171 |     3.9 |          21.1
 HALIFAX      |      38926 |       823 |             2.1 |         6404 |    16.5 |          18.6
 BLADEN       |      23029 |       492 |             2.1 |         3564 |    15.5 |          17.6
 ONSLOW       |     108364 |      6153 |             5.7 |         7880 |     7.3 |          13.0
 MONTGOMERY   |      16529 |       597 |             3.6 |         1263 |     7.6 |          11.2
 ASHE         |      19102 |      1093 |             5.7 |         1017 |     5.3 |          11.0
 STANLY       |      41649 |      2450 |             5.9 |         2097 |     5.0 |          10.9
 TRANSYLVANIA |      25941 |      2302 |             8.9 |          468 |     1.8 |          10.7
 SAMPSON      |      38182 |      1663 |             4.4 |         2163 |     5.7 |          10.1
 NORTHAMPTON  |      14605 |      1059 |             7.3 |          381 |     2.6 |           9.9
 GATES        |       8763 |       298 |             3.4 |          561 |     6.4 |           9.8
 HARNETT      |      75570 |      7069 |             9.4 |          256 |     0.3 |           9.7
 JACKSON      |      28573 |      2239 |             7.8 |          245 |     0.9 |           8.7
 DAVIE        |      29765 |      2517 |             8.5 |            5 |     0.0 |           8.5
 MOORE        |      67737 |      2076 |             3.1 |         3387 |     5.0 |           8.1
 VANCE        |      30179 |      2115 |             7.0 |          154 |     0.5 |           7.5
 DUPLIN       |      30231 |       402 |             1.3 |         1716 |     5.7 |           7.0
 ROBESON      |      76713 |      2825 |             3.7 |         2298 |     3.0 |           6.7
 CHATHAM      |      53420 |      3048 |             5.7 |          321 |     0.6 |           6.3
 PITT         |     124082 |      7398 |             6.0 |          272 |     0.2 |           6.2
 NASH         |      66708 |       696 |             1.0 |         3184 |     4.8 |           5.8
 JOHNSTON     |     127460 |      6061 |             4.8 |         1166 |     0.9 |           5.7
 YANCEY       |      14121 |       565 |             4.0 |          208 |     1.5 |           5.5
 CARTERET     |      52566 |      1119 |             2.1 |         1780 |     3.4 |           5.5
 CALDWELL     |      54603 |      2023 |             3.7 |          738 |     1.4 |           5.1
 COLUMBUS     |      37378 |       413 |             1.1 |         1476 |     3.9 |           5.0
 RICHMOND     |      30347 |       298 |             1.0 |         1033 |     3.4 |           4.4
 DAVIDSON     |     108371 |      4479 |             4.1 |           76 |     0.1 |           4.2
 MADISON      |      17103 |       282 |             1.6 |          424 |     2.5 |           4.1
 POLK         |      16028 |       594 |             3.7 |           65 |     0.4 |           4.1
 CABARRUS     |     136894 |      5418 |             4.0 |            7 |     0.0 |           4.0
 GUILFORD     |     373388 |     14611 |             3.9 |            2 |     0.0 |           3.9
 FORSYTH      |     259739 |     10205 |             3.9 |            0 |     0.0 |           3.9
 RANDOLPH     |      91803 |      1497 |             1.6 |         2041 |     2.2 |           3.8
 DURHAM       |     226100 |      8267 |             3.7 |            1 |     0.0 |           3.7
 CLEVELAND    |      64485 |       371 |             0.6 |         1874 |     2.9 |           3.5
 MITCHELL     |      11045 |       167 |             1.5 |          214 |     1.9 |           3.4
 WATAUGA      |      46949 |      1545 |             3.3 |           18 |     0.0 |           3.3
 ROWAN        |      95250 |      2862 |             3.0 |          240 |     0.3 |           3.3
 HENDERSON    |      85019 |      2476 |             2.9 |          265 |     0.3 |           3.2
 PENDER       |      41305 |       503 |             1.2 |          773 |     1.9 |           3.1
 MCDOWELL     |      29455 |       581 |             2.0 |          237 |     0.8 |           2.8
 WILKES       |      42793 |       648 |             1.5 |          435 |     1.0 |           2.5
 CUMBERLAND   |     217913 |      3846 |             1.8 |         1619 |     0.7 |           2.5
 CRAVEN       |      69386 |       446 |             0.6 |         1262 |     1.8 |           2.4
 WILSON       |      56090 |      1327 |             2.4 |           10 |     0.0 |           2.4
 BURKE        |      58353 |       634 |             1.1 |          587 |     1.0 |           2.1
 BRUNSWICK    |     101689 |      1487 |             1.5 |          595 |     0.6 |           2.1
 NEW HANOVER  |     170203 |      2948 |             1.7 |          378 |     0.2 |           1.9
 BUNCOMBE     |     196069 |      2815 |             1.4 |          659 |     0.3 |           1.7
 RUTHERFORD   |      45129 |       187 |             0.4 |          601 |     1.3 |           1.7
 UNION        |     155738 |      2346 |             1.5 |           49 |     0.0 |           1.5
 GRANVILLE    |      38563 |       308 |             0.8 |          226 |     0.6 |           1.4
 CASWELL      |      15697 |        82 |             0.5 |          101 |     0.6 |           1.1
 PERSON       |      26712 |       205 |             0.8 |           67 |     0.3 |           1.1
 ALAMANCE     |     101870 |       866 |             0.9 |          122 |     0.1 |           1.0
 IREDELL      |     120503 |       288 |             0.2 |          909 |     0.8 |           1.0
 LENOIR       |      38608 |       326 |             0.8 |            0 |     0.0 |           0.8
 SURRY        |      45816 |       203 |             0.4 |          192 |     0.4 |           0.8
 WAYNE        |      75125 |       463 |             0.6 |          113 |     0.2 |           0.8
 ROCKINGHAM   |      60167 |       374 |             0.6 |            0 |     0.0 |           0.6
 ORANGE       |     114051 |       584 |             0.5 |           19 |     0.0 |           0.5
 MECKLENBURG  |     734059 |      4027 |             0.5 |            0 |     0.0 |           0.5
 GASTON       |     144584 |       513 |             0.4 |            0 |     0.0 |           0.4
 ALEXANDER    |      24378 |        45 |             0.2 |           35 |     0.1 |           0.3
 WAKE         |     732858 |      2062 |             0.3 |           43 |     0.0 |           0.3
 CATAWBA      |     104863 |       324 |             0.3 |            0 |     0.0 |           0.3
 LINCOLN      |      57727 |       193 |             0.3 |            0 |     0.0 |           0.3
(70 rows)

Time: 26677.801 ms (00:26.678)
*/

-- Export the isochrones
COPY isochrones TO '/Users/mtdukes/Dropbox/projects/wral/electionland/data/early-voting/evl-analysis/isochrones-hifi.csv' DELIMITER ',' CSV HEADER;

-- let's get an overall average
SELECT round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso;

/*
 avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------
     0.36 |     2.21 |     18.5 |    -16.5
(1 row)

Time: 35559.084 ms (00:35.559)
*/

-- let's look at the breakdown by race
SELECT race_code, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY race_code
ORDER BY avg_dist;

/*
 race_code | avg_dist | std_dist | max_dist | min_dist 
-----------+----------+----------+----------+----------
 I         |    -0.68 |     3.19 |       18 |    -14.5
 A         |     0.04 |     1.42 |     17.5 |      -14
 M         |     0.19 |     1.80 |     17.5 |    -13.5
 O         |     0.20 |     1.93 |     17.5 |    -14.5
 U         |     0.22 |     1.91 |     17.5 |    -14.5
 B         |     0.28 |     2.17 |     18.5 |    -16.5
 W         |     0.42 |     2.24 |     18.5 |    -16.5
(7 rows)

Time: 37139.141 ms (00:37.139)
*/

-- breakdown by party
SELECT party_cd,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist, MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY party_cd
ORDER BY avg_dist;

/*
 party_cd | avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------+----------
 GRE      |     0.20 |     1.96 |       13 |      -10
 LIB      |     0.29 |     2.02 |     17.5 |    -15.5
 DEM      |     0.31 |     2.18 |     18.5 |    -16.5
 UNA      |     0.34 |     2.15 |     18.5 |    -16.5
 CST      |     0.39 |     1.99 |     14.5 |     -5.5
 REP      |     0.45 |     2.30 |     18.5 |      -16
(6 rows)

Time: 37132.904 ms (00:37.133)
*/

-- look at null distribution across subgroups
SELECT party_cd,
SUM(CASE WHEN dist_diff IS null THEN 1 ELSE 0 END) AS null_dist,
COUNT(party_cd) AS reg_voters,
round(round(SUM(CASE WHEN dist_diff IS null THEN 1 ELSE 0 END) / COUNT(party_cd)::numeric,3)*100::numeric,1) AS pct_null
FROM voters_iso
GROUP BY party_cd;

/*
 party_cd | null_dist | reg_voters | pct_null 
----------+-----------+------------+----------
 CST      |        25 |        363 |      6.9
 DEM      |     71402 |    2422903 |      2.9
 GRE      |        34 |        519 |      6.6
 LIB      |      1261 |      34162 |      3.7
 REP      |     64763 |    1921847 |      3.4
 UNA      |     70485 |    2054175 |      3.4
(6 rows)

Time: 30026.637 ms (00:30.027)
*/

-- same thing for race and nulls
SELECT race_code,
SUM(CASE WHEN dist_diff IS null THEN 1 ELSE 0 END) AS null_dist,
COUNT(race_code) AS reg_voters,
round(round(SUM(CASE WHEN dist_diff IS null THEN 1 ELSE 0 END) / COUNT(race_code)::numeric,3)*100::numeric,1) AS pct_null
FROM voters_iso
GROUP BY race_code
ORDER BY reg_voters DESC;

/*
 race_code | null_dist | reg_voters | pct_null 
-----------+-----------+------------+----------
 W         |    143124 |    4417582 |      3.2
 B         |     40525 |    1406177 |      2.9
 U         |     10500 |     244171 |      4.3
 O         |      5413 |     183123 |      3.0
 A         |      3283 |      88651 |      3.7
 I         |      3396 |      49812 |      6.8
 M         |      1729 |      44453 |      3.9
(7 rows)

Time: 30770.260 ms (00:30.770)
*/

-- check our null distribution by counties
SELECT county_desc,
SUM(CASE WHEN dist_diff IS null THEN 1 ELSE 0 END) AS null_dist,
COUNT(county_desc) AS reg_voters,
round(round(SUM(CASE WHEN dist_diff IS null THEN 1 ELSE 0 END) / COUNT(county_desc)::numeric,3)*100::numeric,1) AS pct_null
FROM voters_iso
GROUP BY county_desc
ORDER BY pct_null DESC;

/*
 county_desc  | null_dist | reg_voters | pct_null 
--------------+-----------+------------+----------
 HYDE         |      1081 |       3421 |     31.6
 BERTIE       |      3081 |      14173 |     21.7
 DARE         |      6313 |      29954 |     21.1
 HALIFAX      |      7227 |      38926 |     18.6
 BLADEN       |      4056 |      23029 |     17.6
 ONSLOW       |     14033 |     108364 |     12.9
 MONTGOMERY   |      1860 |      16529 |     11.3
 ASHE         |      2110 |      19102 |     11.0
 STANLY       |      4547 |      41649 |     10.9
 TRANSYLVANIA |      2770 |      25941 |     10.7
 SAMPSON      |      3826 |      38182 |     10.0
 NORTHAMPTON  |      1440 |      14605 |      9.9
 GATES        |       859 |       8763 |      9.8
 HARNETT      |      7325 |      75570 |      9.7
 JACKSON      |      2484 |      28573 |      8.7
 DAVIE        |      2522 |      29765 |      8.5
 MOORE        |      5463 |      67737 |      8.1
 VANCE        |      2269 |      30179 |      7.5
 DUPLIN       |      2118 |      30231 |      7.0
 ROBESON      |      5123 |      76713 |      6.7
 CHATHAM      |      3369 |      53420 |      6.3
 PITT         |      7670 |     124082 |      6.2
 NASH         |      3880 |      66708 |      5.8
 JOHNSTON     |      7227 |     127460 |      5.7
 YANCEY       |       773 |      14121 |      5.5
 CARTERET     |      2899 |      52566 |      5.5
 COLUMBUS     |      1889 |      37378 |      5.1
 CALDWELL     |      2761 |      54603 |      5.1
 RICHMOND     |      1331 |      30347 |      4.4
 DAVIDSON     |      4555 |     108371 |      4.2
 MADISON      |       706 |      17103 |      4.1
 POLK         |       659 |      16028 |      4.1
 CABARRUS     |      5425 |     136894 |      4.0
 GUILFORD     |     14613 |     373388 |      3.9
 FORSYTH      |     10205 |     259739 |      3.9
 RANDOLPH     |      3538 |      91803 |      3.9
 DURHAM       |      8268 |     226100 |      3.7
 CLEVELAND    |      2245 |      64485 |      3.5
 MITCHELL     |       381 |      11045 |      3.4
 WATAUGA      |      1563 |      46949 |      3.3
 ROWAN        |      3102 |      95250 |      3.3
 HENDERSON    |      2741 |      85019 |      3.2
 PENDER       |      1276 |      41305 |      3.1
 MCDOWELL     |       818 |      29455 |      2.8
 CUMBERLAND   |      5465 |     217913 |      2.5
 CRAVEN       |      1708 |      69386 |      2.5
 WILKES       |      1083 |      42793 |      2.5
 WILSON       |      1337 |      56090 |      2.4
 BURKE        |      1221 |      58353 |      2.1
 BRUNSWICK    |      2082 |     101689 |      2.0
 NEW HANOVER  |      3326 |     170203 |      2.0
 BUNCOMBE     |      3474 |     196069 |      1.8
 RUTHERFORD   |       788 |      45129 |      1.7
 UNION        |      2395 |     155738 |      1.5
 GRANVILLE    |       534 |      38563 |      1.4
 CASWELL      |       183 |      15697 |      1.2
 PERSON       |       272 |      26712 |      1.0
 ALAMANCE     |       988 |     101870 |      1.0
 IREDELL      |      1197 |     120503 |      1.0
 SURRY        |       395 |      45816 |      0.9
 LENOIR       |       326 |      38608 |      0.8
 WAYNE        |       576 |      75125 |      0.8
 ROCKINGHAM   |       374 |      60167 |      0.6
 ORANGE       |       603 |     114051 |      0.5
 MECKLENBURG  |      4027 |     734059 |      0.5
 GASTON       |       513 |     144584 |      0.4
 LINCOLN      |       193 |      57727 |      0.3
 ALEXANDER    |        80 |      24378 |      0.3
 WAKE         |      2105 |     732858 |      0.3
 CATAWBA      |       324 |     104863 |      0.3
(70 rows)

Time: 31173.828 ms (00:31.174)
*/

SELECT county_desc,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY county_desc
ORDER BY avg_dist DESC;

/*
 county_desc  | avg_dist | std_dist | max_dist | min_dist 
--------------+----------+----------+----------+----------
 HALIFAX      |     6.58 |     4.02 |       17 |      -12
 BERTIE       |     5.62 |     5.94 |       17 |     -5.5
 CASWELL      |     4.45 |     4.81 |     15.5 |        0
 STANLY       |     4.05 |     5.25 |     17.5 |      -10
 BLADEN       |     3.94 |     4.85 |       16 |    -10.5
 HENDERSON    |     3.07 |     3.49 |     12.5 |       -4
 POLK         |     2.50 |     3.46 |     16.5 |        0
 NORTHAMPTON  |     2.22 |     4.45 |     16.5 |    -10.5
 RICHMOND     |     2.04 |     2.75 |     12.5 |       -6
 SAMPSON      |     1.77 |     4.07 |       16 |     -9.5
 ONSLOW       |     1.67 |     3.29 |     13.5 |       -6
 ASHE         |     1.63 |     3.20 |     13.5 |        0
 PERSON       |     1.55 |     2.78 |     10.5 |        0
 JOHNSTON     |     1.48 |     3.02 |       15 |      -13
 GATES        |     1.44 |     1.97 |      8.5 |       -6
 RUTHERFORD   |     1.39 |     2.68 |       11 |       -4
 WILKES       |     1.29 |     2.66 |       13 |       -7
 COLUMBUS     |     1.25 |     2.91 |     13.5 |    -10.5
 DAVIE        |     1.25 |     2.30 |     14.5 |       -7
 TRANSYLVANIA |     1.24 |     2.86 |       13 |       -9
 CUMBERLAND   |     1.17 |     2.49 |       13 |    -12.5
 SURRY        |     1.16 |     3.58 |     15.5 |     -5.5
 NASH         |     1.07 |     2.72 |     13.5 |       -5
 LINCOLN      |     1.02 |     2.22 |       16 |      -16
 ROWAN        |     0.95 |     2.20 |       13 |       -9
 PENDER       |     0.93 |     2.05 |       12 |     -8.5
 MCDOWELL     |     0.92 |     1.49 |     10.5 |        0
 IREDELL      |     0.84 |     2.41 |     18.5 |    -12.5
 HARNETT      |     0.81 |     2.34 |     10.5 |    -10.5
 PITT         |     0.71 |     2.42 |       14 |     -6.5
 BRUNSWICK    |     0.66 |     2.49 |       15 |     -9.5
 DARE         |     0.60 |     1.93 |     15.5 |      -14
 MADISON      |     0.55 |     1.29 |        9 |    -12.5
 CLEVELAND    |     0.48 |     1.45 |        6 |       -6
 GASTON       |     0.41 |     0.73 |        5 |     -3.5
 BUNCOMBE     |     0.33 |     1.34 |     15.5 |    -13.5
 VANCE        |     0.32 |     0.82 |        4 |     -7.5
 CHATHAM      |     0.32 |     2.04 |        9 |    -12.5
 CRAVEN       |     0.25 |     1.59 |     12.5 |    -14.5
 ALAMANCE     |     0.24 |     0.52 |      4.5 |     -3.5
 WAYNE        |     0.22 |     2.01 |       10 |    -11.5
 GUILFORD     |     0.21 |     1.33 |       10 |     -4.5
 CALDWELL     |     0.18 |     0.53 |     10.5 |       -6
 CARTERET     |     0.16 |     1.72 |       17 |      -16
 MECKLENBURG  |     0.14 |     1.10 |     11.5 |     -7.5
 WILSON       |     0.09 |     0.46 |        9 |       -6
 NEW HANOVER  |     0.03 |     0.30 |       16 |    -10.5
 CATAWBA      |     0.00 |     0.55 |       10 |      -11
 YANCEY       |     0.00 |     0.25 |      9.5 |       -5
 WATAUGA      |     0.00 |     0.15 |      3.5 |     -3.5
 FORSYTH      |    -0.02 |     1.68 |      8.5 |     -7.5
 UNION        |    -0.04 |     0.42 |        5 |       -5
 WAKE         |    -0.05 |     0.46 |        8 |     -8.5
 RANDOLPH     |    -0.07 |     2.62 |     10.5 |      -12
 ROCKINGHAM   |    -0.09 |     0.96 |        8 |       -8
 ORANGE       |    -0.10 |     1.53 |       10 |       -7
 MITCHELL     |    -0.12 |     1.22 |     14.5 |    -13.5
 DUPLIN       |    -0.15 |     0.90 |        6 |       -5
 LENOIR       |    -0.29 |     0.96 |      9.5 |     -8.5
 JACKSON      |    -0.31 |     0.89 |     10.5 |      -12
 DAVIDSON     |    -0.34 |     1.18 |        8 |    -11.5
 CABARRUS     |    -0.34 |     1.11 |      5.5 |     -4.5
 HYDE         |    -0.48 |     1.42 |        5 |     -7.5
 DURHAM       |    -0.51 |     1.13 |        1 |     -9.5
 BURKE        |    -0.74 |     1.59 |      1.5 |     -7.5
 ALEXANDER    |    -0.74 |     1.95 |        0 |      -10
 GRANVILLE    |    -1.21 |     2.78 |      6.5 |    -11.5
 MONTGOMERY   |    -1.78 |     2.87 |       13 |    -11.5
 ROBESON      |    -2.42 |     4.31 |      1.5 |    -16.5
 MOORE        |    -2.66 |     5.65 |     13.5 |      -14
(70 rows)

Time: 37825.410 ms (00:37.825)
*/

-- state house analysis
-- one consideration to remember: we don't have every county
SELECT nc_house_abbrv,
COUNT(nc_house_abbrv) as total_voters,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY nc_house_abbrv
ORDER BY avg_dist DESC;

/*
 nc_house_abbrv | total_voters | avg_dist | std_dist | max_dist | min_dist 
----------------+--------------+----------+----------+----------+----------
 001            |        14154 |     5.62 |     5.94 |       17 |     -5.5
 027            |        53503 |     5.30 |     4.60 |       17 |      -12
 007            |        11425 |     4.37 |     4.07 |     12.5 |     -4.5
 022            |        52172 |     3.01 |     4.72 |       16 |    -10.5
 117            |        61970 |     2.98 |     3.53 |     12.5 |       -4
 067            |        60678 |     2.76 |     4.84 |     17.5 |     -4.5
 004            |        46916 |     2.33 |     4.08 |     13.5 |       -5
 113            |        65013 |     2.32 |     3.34 |     16.5 |       -9
 045            |        61354 |     2.25 |     3.91 |       13 |    -12.5
 028            |        55839 |     2.11 |     4.01 |       15 |      -13
 015            |        39750 |     1.76 |     2.91 |      8.5 |     -4.5
 090            |        44333 |     1.67 |     3.89 |     15.5 |       -7
 026            |        69631 |     1.48 |     2.53 |     12.5 |       -4
 084            |        54092 |     1.47 |     3.24 |     18.5 |     -9.5
 005            |         8694 |     1.44 |     1.97 |      8.5 |       -6
 076            |        56098 |     1.24 |     1.69 |       13 |       -9
 008            |        57323 |     1.13 |     3.24 |       14 |     -6.5
 016            |        60603 |     1.09 |     2.30 |       12 |     -8.5
 017            |        76281 |     1.09 |     2.58 |       15 |       -4
 042            |        46944 |     1.05 |     1.48 |        8 |     -2.5
 112            |        51701 |     1.05 |     2.73 |       11 |       -5
 097            |        57726 |     1.02 |     2.22 |       16 |      -16
 077            |        59008 |     0.99 |     2.77 |     14.5 |       -7
 044            |        54792 |     0.99 |     1.81 |      7.5 |     -2.5
 050            |        62053 |     0.95 |     3.75 |     15.5 |       -7
 101            |        65905 |     0.94 |     2.43 |       10 |       -4
 062            |        65636 |     0.85 |     2.93 |       10 |     -4.5
 073            |        30451 |     0.81 |     1.17 |        5 |     -4.5
 066            |        52673 |     0.71 |     3.16 |       13 |    -11.5
 115            |        64549 |     0.65 |     1.56 |     15.5 |    -13.5
 085            |        40261 |     0.64 |     1.50 |     14.5 |    -13.5
 109            |        55661 |     0.57 |     0.81 |        5 |       -3
 025            |        55283 |     0.56 |     2.01 |     13.5 |       -5
 108            |        53807 |     0.52 |     0.75 |        5 |       -3
 006            |        33375 |     0.50 |     1.91 |     15.5 |      -14
 053            |        55609 |     0.49 |     1.55 |      9.5 |    -10.5
 102            |        57739 |     0.45 |     0.66 |        2 |     -0.5
 093            |        66024 |     0.44 |     1.82 |     13.5 |     -3.5
 116            |        61089 |     0.40 |     1.35 |        9 |      -10
 074            |        60880 |     0.40 |     2.25 |      8.5 |     -7.5
 111            |        49317 |     0.35 |     1.35 |        6 |       -6
 092            |        61748 |     0.34 |     1.11 |       11 |     -6.5
 012            |        50106 |     0.33 |     1.68 |      9.5 |     -8.5
 064            |        48953 |     0.33 |     0.60 |      4.5 |     -3.5
 010            |        40368 |     0.33 |     2.56 |       10 |    -11.5
 095            |        66411 |     0.32 |     1.19 |       14 |    -12.5
 105            |        61926 |     0.32 |     0.63 |        3 |       -1
 003            |        50652 |     0.31 |     1.70 |     12.5 |      -13
 094            |        52971 |     0.30 |     2.49 |     10.5 |      -10
 118            |        31223 |     0.30 |     1.01 |      9.5 |    -12.5
 043            |        54755 |     0.29 |     0.65 |      6.5 |       -3
 032            |        42142 |     0.27 |     0.72 |      5.5 |     -7.5
 098            |        68635 |     0.27 |     1.25 |     11.5 |     -7.5
 054            |        70771 |     0.24 |     1.76 |        9 |    -12.5
 110            |        50284 |     0.24 |     1.02 |        6 |     -5.5
 059            |        65244 |     0.23 |     0.53 |      3.5 |       -1
                |         2894 |     0.23 |     1.66 |       10 |     -9.5
 088            |        64256 |     0.20 |     0.43 |      5.5 |     -6.5
 087            |        54595 |     0.18 |     0.53 |     10.5 |       -6
 063            |        52917 |     0.16 |     0.43 |        4 |       -2
 013            |        52563 |     0.16 |     1.72 |       17 |      -16
 037            |        75995 |     0.14 |     0.40 |      7.5 |     -8.5
 061            |        69719 |     0.12 |     0.43 |      2.5 |        0
 104            |        65592 |     0.12 |     0.32 |      2.5 |     -0.5
 070            |        48754 |     0.12 |     0.92 |        5 |       -4
 040            |        68624 |     0.11 |     0.33 |        8 |       -4
 079            |        18727 |     0.10 |     1.21 |     11.5 |    -14.5
 024            |        56090 |     0.09 |     0.46 |        9 |       -6
 021            |        49174 |     0.09 |     1.00 |        7 |     -9.5
 099            |        56941 |     0.04 |     0.17 |        1 |       -1
 041            |        66143 |     0.04 |     0.29 |      3.5 |       -2
 020            |        65607 |     0.03 |     0.39 |       16 |    -10.5
 019            |        65854 |     0.03 |     0.21 |       13 |       -8
 089            |        52802 |     0.02 |     0.70 |       10 |      -11
 058            |        57166 |     0.02 |     0.15 |      1.5 |     -0.5
 100            |        51692 |     0.02 |     0.23 |        1 |       -1
 034            |        63578 |     0.01 |     0.19 |      0.5 |       -2
 051            |        16556 |     0.00 |     0.00 |        0 |        0
 035            |        73828 |     0.00 |     0.15 |      2.5 |       -2
 014            |        51895 |     0.00 |     0.28 |        5 |       -6
 103            |        62810 |     0.00 |     0.14 |        2 |     -1.5
 083            |        55850 |     0.00 |     0.19 |        3 |     -1.5
 036            |        67837 |     0.00 |     0.34 |        4 |     -4.5
 057            |        61530 |     0.00 |     0.00 |        0 |        0
 038            |        59838 |     0.00 |     0.14 |      1.5 |     -0.5
 091            |        22161 |    -0.01 |     0.75 |        8 |       -8
 056            |        67684 |    -0.01 |     0.35 |      1.5 |       -2
 069            |        55821 |    -0.01 |     0.51 |        3 |     -3.5
 060            |        53988 |    -0.02 |     0.69 |        2 |     -2.5
 096            |        52060 |    -0.03 |     0.33 |      4.5 |       -4
 055            |        36497 |    -0.03 |     0.46 |        5 |       -5
 080            |        54503 |    -0.03 |     0.51 |        8 |       -7
 114            |        69595 |    -0.03 |     0.97 |        6 |     -2.5
 039            |        64740 |    -0.04 |     0.39 |      4.5 |     -5.5
 068            |        63420 |    -0.07 |     0.27 |      1.5 |       -2
 009            |        55053 |    -0.07 |     0.57 |        9 |       -6
 065            |        53686 |    -0.09 |     0.92 |        6 |       -6
 072            |        54945 |    -0.12 |     0.87 |        4 |       -3
 002            |        53305 |    -0.12 |     3.41 |     10.5 |    -11.5
 029            |        72408 |    -0.13 |     0.60 |        1 |     -2.5
 075            |        60261 |    -0.15 |     1.41 |      3.5 |       -4
 033            |        62024 |    -0.17 |     0.68 |        1 |     -2.5
 106            |        55696 |    -0.17 |     0.42 |        1 |     -1.5
 049            |        69691 |    -0.22 |     0.52 |        2 |       -7
 018            |        64147 |    -0.24 |     1.08 |      4.5 |     -9.5
 119            |        28094 |    -0.30 |     0.89 |     10.5 |      -12
 078            |        50711 |    -0.31 |     3.47 |     10.5 |      -12
 030            |        67911 |    -0.43 |     0.74 |        0 |       -4
 011            |        60560 |    -0.48 |     0.78 |      0.5 |       -4
 082            |        65978 |    -0.63 |     1.48 |        4 |       -4
 081            |        53868 |    -0.65 |     1.53 |      3.5 |    -11.5
 086            |        51722 |    -0.67 |     1.56 |      1.5 |     -7.5
 071            |        53202 |    -0.75 |     1.70 |      3.5 |       -4
 107            |        60803 |    -0.94 |     1.27 |      6.5 |     -4.5
 031            |        68372 |    -1.08 |     1.65 |      0.5 |     -9.5
 047            |        48684 |    -1.72 |     3.51 |      1.5 |    -16.5
 046            |        45996 |    -1.79 |     5.07 |     13.5 |    -14.5
 052            |        60055 |    -2.94 |     5.93 |     13.5 |      -14
(118 rows)

Time: 36491.102 ms (00:36.491)
*/

-- state senate analysis
-- one consideration to remember: we don't have every county
SELECT nc_senate_abbrv,
COUNT(nc_house_abbrv) as total_voters,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY nc_senate_abbrv
ORDER BY avg_dist DESC;

/*
 nc_senate_abbrv | total_voters | avg_dist | std_dist | max_dist | min_dist 
-----------------+--------------+----------+----------+----------+----------
 04              |        94991 |     2.47 |     3.98 |       17 |      -12
 48              |       149075 |     2.06 |     3.16 |       13 |      -10
 03              |        58934 |     1.93 |     4.14 |       17 |    -10.5
 33              |       136899 |     1.84 |     3.65 |     17.5 |      -10
 06              |       108331 |     1.67 |     3.29 |     13.5 |       -6
 12              |        82557 |     1.54 |     3.47 |       15 |    -10.5
 19              |       131523 |     1.52 |     2.98 |       13 |    -12.5
 11              |       147877 |     1.21 |     2.56 |     13.5 |       -5
 08              |       170957 |     1.09 |     2.94 |       16 |    -10.5
 45              |       133046 |     1.05 |     2.91 |     15.5 |       -7
 47              |       132626 |     1.04 |     2.30 |     16.5 |    -13.5
 34              |       120503 |     0.84 |     2.41 |     18.5 |    -12.5
 10              |       107710 |     0.73 |     2.78 |       16 |      -13
 01              |        42069 |     0.72 |     1.97 |     15.5 |      -14
 05              |       123888 |     0.71 |     2.42 |       14 |     -6.5
 44              |       128930 |     0.70 |     1.84 |       16 |      -16
 30              |        97438 |     0.66 |     2.65 |     15.5 |       -8
 41              |       161505 |     0.64 |     1.60 |     11.5 |     -7.5
 21              |        86322 |     0.63 |     1.23 |        8 |       -3
 31              |       151207 |     0.53 |     1.86 |     14.5 |     -7.5
 43              |       137865 |     0.43 |     0.74 |        5 |     -3.5
 49              |       157118 |     0.32 |     1.44 |     15.5 |    -13.5
 27              |       151342 |     0.28 |     2.01 |       10 |     -4.5
 24              |       139680 |     0.28 |     0.56 |      4.5 |     -3.5
                 |         2894 |     0.23 |     1.66 |       10 |     -9.5
 02              |       121942 |     0.21 |     1.64 |       17 |      -16
 37              |       148483 |     0.18 |     0.61 |        2 |       -2
 17              |       158647 |     0.09 |     0.37 |      7.5 |     -8.5
 39              |       153300 |     0.08 |     0.32 |        3 |     -1.5
 28              |       151644 |     0.06 |     0.30 |      2.5 |     -0.5
 40              |       127630 |     0.05 |     0.24 |      1.5 |       -1
 26              |       124278 |     0.05 |     2.27 |     10.5 |      -12
 07              |       113718 |     0.05 |     1.74 |       10 |    -11.5
 23              |       167451 |     0.03 |     1.71 |       10 |    -12.5
 18              |       119118 |     0.02 |     0.27 |        8 |       -4
 09              |       165189 |     0.02 |     0.30 |       16 |    -10.5
 16              |       160948 |     0.00 |     0.32 |        2 |       -7
 14              |       144244 |    -0.02 |     0.28 |      4.5 |     -5.5
 35              |       146510 |    -0.05 |     0.43 |        5 |       -5
 42              |       129240 |    -0.14 |     1.02 |       10 |      -11
 22              |       132523 |    -0.18 |     2.24 |     10.5 |    -11.5
 50              |        28094 |    -0.30 |     0.89 |     10.5 |      -12
 46              |       112899 |    -0.30 |     1.29 |     10.5 |     -7.5
 38              |       142825 |    -0.31 |     1.51 |        6 |     -4.5
 36              |       146089 |    -0.32 |     1.07 |      5.5 |     -4.5
 15              |       149901 |    -0.33 |     0.72 |        1 |       -4
 32              |       138289 |    -0.37 |     1.58 |      4.5 |       -4
 29              |       124871 |    -0.52 |     1.57 |       13 |    -11.5
 20              |       158807 |    -0.60 |     1.28 |        1 |     -9.5
 25              |        97997 |    -1.16 |     5.38 |     13.5 |      -14
 13              |       114045 |    -1.20 |     4.26 |     13.5 |    -16.5
(51 rows)

Time: 35295.984 ms (00:35.296)
*/


-- add crosstab functionality
CREATE EXTENSION IF NOT EXISTS tablefunc;

-- Count the frequency of bins for each party
SELECT party_cd AS party,
SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY party_cd;

/*
 party | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
-------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 CST   |              0 |           1 |         17 |       280 |          30 |            7 |               3 |            3 |        22
 DEM   |           6091 |       19220 |     129537 |   1917722 |      195849 |        61708 |           21374 |        22527 |     48875
 GRE   |              0 |           6 |         36 |       388 |          43 |           10 |               2 |            2 |        32
 LIB   |             67 |         242 |       1822 |     26959 |        2766 |          863 |             182 |          293 |       968
 REP   |           2856 |       17174 |      94734 |   1477298 |      181856 |        66484 |           16682 |        21879 |     42884
 UNA   |           3626 |       15936 |     109919 |   1607997 |      172256 |        59040 |           14916 |        17621 |     52864
(6 rows)

Time: 43456.147 ms (00:43.456)
*/

-- View as a percentage of the party_cd population
SELECT party_cd AS party,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY party_cd;

/*
 party | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
-------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 CST   |            0.0 |         0.3 |        4.7 |      77.1 |         8.3 |          1.9 |             0.8 |          0.8 |       6.1
 DEM   |            0.3 |         0.8 |        5.3 |      79.1 |         8.1 |          2.5 |             0.9 |          0.9 |       2.0
 GRE   |            0.0 |         1.2 |        6.9 |      74.8 |         8.3 |          1.9 |             0.4 |          0.4 |       6.2
 LIB   |            0.2 |         0.7 |        5.3 |      78.9 |         8.1 |          2.5 |             0.5 |          0.9 |       2.8
 REP   |            0.1 |         0.9 |        4.9 |      76.9 |         9.5 |          3.5 |             0.9 |          1.1 |       2.2
 UNA   |            0.2 |         0.8 |        5.4 |      78.3 |         8.4 |          2.9 |             0.7 |          0.9 |       2.6
(6 rows)

Time: 44457.311 ms (00:44.457)
*/

-- Count the frequency of bins for each race subgroup
SELECT race_code AS race,
SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY race_code;

/*
 race | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 A    |             50 |         300 |       5375 |     74050 |        4505 |          935 |             153 |          205 |      3078
 B    |           4011 |        9897 |      79119 |   1114452 |      112983 |        31860 |           13330 |        10964 |     29561
 I    |            715 |        3944 |       3018 |     35064 |        2435 |         1073 |             167 |         1544 |      1852
 M    |             65 |         233 |       2543 |     35735 |        3098 |          867 |             183 |          189 |      1540
 O    |            424 |        1462 |      10396 |    146164 |       14658 |         3805 |             801 |          889 |      4524
 U    |            277 |        1266 |      15362 |    193253 |       16989 |         5194 |            1330 |         1384 |      9116
 W    |           7098 |       35477 |     220252 |   3431926 |      398132 |       144378 |           37195 |        47150 |     95974
(7 rows)

Time: 44202.917 ms (00:44.203)
*/

-- View as a percentage of the race_code population
SELECT race_code AS race,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY race_code;

/*
 race | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 A    |            0.1 |         0.3 |        6.1 |      83.5 |         5.1 |          1.1 |             0.2 |          0.2 |       3.5
 B    |            0.3 |         0.7 |        5.6 |      79.3 |         8.0 |          2.3 |             0.9 |          0.8 |       2.1
 I    |            1.4 |         7.9 |        6.1 |      70.4 |         4.9 |          2.2 |             0.3 |          3.1 |       3.7
 M    |            0.1 |         0.5 |        5.7 |      80.4 |         7.0 |          2.0 |             0.4 |          0.4 |       3.5
 O    |            0.2 |         0.8 |        5.7 |      79.8 |         8.0 |          2.1 |             0.4 |          0.5 |       2.5
 U    |            0.1 |         0.5 |        6.3 |      79.1 |         7.0 |          2.1 |             0.5 |          0.6 |       3.7
 W    |            0.2 |         0.8 |        5.0 |      77.7 |         9.0 |          3.3 |             0.8 |          1.1 |       2.2
(7 rows)

Time: 44731.408 ms (00:44.731)
*/

SELECT county_desc AS county,
SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY county_desc;

/*
    county    | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
--------------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 ALAMANCE     |              0 |           0 |        421 |     94627 |        5834 |            0 |               0 |          122 |       866
 ALEXANDER    |              0 |        1550 |       2271 |     20477 |           0 |            0 |               0 |           35 |        45
 ASHE         |              0 |           0 |          0 |     12960 |        1423 |         2499 |             110 |         1017 |      1093
 BERTIE       |              0 |           4 |         65 |      4905 |         930 |         1993 |            3195 |         1908 |      1173
 BLADEN       |             12 |          38 |        278 |      9303 |        2060 |         4118 |            3164 |         3564 |       492
 BRUNSWICK    |              0 |          11 |      11436 |     67280 |       12876 |         7976 |              28 |          595 |      1487
 BUNCOMBE     |              4 |          64 |       8807 |    157273 |       24802 |         1584 |              61 |          659 |      2815
 BURKE        |              0 |        1967 |       8036 |     47120 |           9 |            0 |               0 |          587 |       634
 CABARRUS     |              0 |           0 |      17950 |    108638 |        4880 |            1 |               0 |            7 |      5418
 CALDWELL     |              0 |          22 |         63 |     51034 |         662 |           56 |               5 |          738 |      2023
 CARTERET     |             61 |         178 |        474 |     45778 |        2422 |          436 |             318 |         1780 |      1119
 CASWELL      |              0 |           0 |          0 |      6007 |        3909 |         2564 |            3034 |          101 |        82
 CATAWBA      |             24 |          67 |        540 |    103251 |         546 |          111 |               0 |            0 |       324
 CHATHAM      |             19 |         249 |       6373 |     34144 |        7060 |         2206 |               0 |          321 |      3048
 CLEVELAND    |              0 |          16 |       6993 |     37842 |       17348 |           41 |               0 |         1874 |       371
 COLUMBUS     |             11 |         415 |       3767 |     16940 |        9892 |         4457 |               7 |         1476 |       413
 CRAVEN       |             87 |         135 |       7259 |     50515 |        7901 |         1729 |              52 |         1262 |       446
 CUMBERLAND   |             57 |        3492 |       4398 |    133406 |       51454 |        19541 |             100 |         1619 |      3846
 DARE         |              4 |         124 |        113 |     20100 |        1943 |         1315 |              42 |         1171 |      5142
 DAVIDSON     |              1 |         772 |       8844 |     93854 |         338 |            7 |               0 |           76 |      4479
 DAVIE        |              0 |          13 |         52 |     20076 |        4153 |         2938 |              11 |            5 |      2517
 DUPLIN       |              0 |           0 |        332 |     27020 |         760 |            1 |               0 |         1716 |       402
 DURHAM       |              0 |         660 |      34301 |    182871 |           0 |            0 |               0 |            1 |      8267
 FORSYTH      |              0 |        1880 |      44194 |    159385 |       43930 |          145 |               0 |            0 |     10205
 GASTON       |              0 |           0 |        529 |    118124 |       25418 |            0 |               0 |            0 |       513
 GATES        |              0 |           2 |        391 |      3834 |        3655 |           22 |               0 |          561 |       298
 GRANVILLE    |             24 |        5357 |       2850 |     29227 |         556 |           15 |               0 |          226 |       308
 GUILFORD     |              0 |           0 |      16382 |    311951 |       22614 |         7828 |               0 |            2 |     14611
 HALIFAX      |              7 |           8 |        217 |      3502 |        6971 |        13126 |            7868 |         6404 |       823
 HARNETT      |              3 |          20 |        272 |     59649 |        3227 |         5059 |              15 |          256 |      7069
 HENDERSON    |              0 |           0 |          3 |     39011 |       21253 |        18987 |            3024 |          265 |      2476
 HYDE         |              0 |          68 |        240 |      1974 |          58 |            0 |               0 |          950 |       131
 IREDELL      |             14 |         125 |        557 |     99986 |       10493 |         6209 |            1922 |          909 |       288
 JACKSON      |              6 |          67 |       2468 |     23286 |         225 |           36 |               1 |          245 |      2239
 JOHNSTON     |              8 |          10 |       1151 |     86816 |       16960 |        12022 |            3266 |         1166 |      6061
 LENOIR       |              0 |          28 |       6435 |     30696 |        1058 |           65 |               0 |            0 |       326
 LINCOLN      |             68 |           0 |        372 |     43682 |        9675 |         3637 |             100 |            0 |       193
 MADISON      |              2 |          12 |        391 |     11713 |        4188 |           91 |               0 |          424 |       282
 MCDOWELL     |              0 |           0 |          0 |     20001 |        8265 |          359 |              12 |          237 |       581
 MECKLENBURG  |              0 |          55 |      40271 |    623816 |       58719 |         7160 |              11 |            0 |      4027
 MITCHELL     |              3 |          19 |        372 |     10058 |         144 |           51 |              17 |          214 |       167
 MONTGOMERY   |              3 |        4012 |        843 |      9381 |         410 |           18 |               2 |         1263 |       597
 MOORE        |           4900 |       16074 |      15684 |     16611 |        2281 |         3884 |            2840 |         3387 |      2076
 NASH         |              0 |           0 |        349 |     52923 |        3131 |         5223 |            1202 |         3184 |       696
 NEW HANOVER  |              2 |           6 |        159 |    166525 |         113 |           39 |              33 |          378 |      2948
 NORTHAMPTON  |              2 |           3 |        183 |      9475 |        1071 |          972 |            1459 |          381 |      1059
 ONSLOW       |              0 |           8 |       2033 |     66294 |       13236 |         8234 |            4526 |         7880 |      6153
 ORANGE       |              0 |         126 |       9795 |     98147 |        3719 |         1661 |               0 |           19 |       584
 PENDER       |              0 |         152 |        428 |     30319 |        8158 |          950 |              22 |          773 |       503
 PERSON       |              0 |           0 |          0 |     19351 |        2759 |         4328 |               2 |           67 |       205
 PITT         |              0 |          10 |        351 |    101000 |        9534 |         2104 |            3413 |          272 |      7398
 POLK         |              0 |           0 |          0 |      8880 |        4032 |         1523 |             934 |           65 |       594
 RANDOLPH     |             14 |        5483 |      11635 |     48318 |       22558 |          254 |               3 |         2041 |      1497
 RICHMOND     |              0 |          10 |         65 |     16490 |        9942 |         2492 |              17 |         1033 |       298
 ROBESON      |           7303 |        8864 |       3012 |     52409 |           2 |            0 |               0 |         2298 |      2825
 ROCKINGHAM   |              0 |          57 |       6741 |     50511 |        2427 |           57 |               0 |            0 |       374
 ROWAN        |              0 |          10 |       6981 |     56478 |       25193 |         3405 |              81 |          240 |      2862
 RUTHERFORD   |              0 |           0 |        137 |     33155 |        5276 |         5747 |              26 |          601 |       187
 SAMPSON      |              0 |          78 |        368 |     26723 |        1944 |         2452 |            2791 |         2163 |      1663
 STANLY       |              0 |           5 |        111 |     18840 |        5407 |         6126 |            6613 |         2097 |      2450
 SURRY        |              0 |           1 |        120 |     40146 |         876 |         1488 |            2790 |          192 |       203
 TRANSYLVANIA |              0 |          40 |        105 |     18436 |        1482 |         3093 |              15 |          468 |      2302
 UNION        |              0 |           0 |        672 |    151222 |        1449 |            0 |               0 |           49 |      2346
 VANCE        |              0 |           9 |        122 |     24036 |        3743 |            0 |               0 |          154 |      2115
 WAKE         |              0 |          58 |      23893 |    705495 |        1287 |           20 |               0 |           43 |      2062
 WATAUGA      |              0 |           0 |          7 |     45374 |           5 |            0 |               0 |           18 |      1545
 WAYNE        |              1 |         126 |      11737 |     44225 |       18128 |          332 |               0 |          113 |       463
 WILKES       |              0 |          18 |        366 |     31195 |        4866 |         5238 |              27 |          435 |       648
 WILSON       |              0 |           1 |        273 |     53283 |        1111 |           85 |               0 |           10 |      1327
 YANCEY       |              0 |           0 |         27 |     13270 |          49 |            2 |               0 |          208 |       565
(70 rows)

Time: 45220.256 ms (00:45.220)
*/

SELECT county_desc AS county,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY county_desc;

/*
    county    | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
--------------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 ALAMANCE     |            0.0 |         0.0 |        0.4 |      92.9 |         5.7 |          0.0 |             0.0 |          0.1 |       0.9
 ALEXANDER    |            0.0 |         6.4 |        9.3 |      84.0 |         0.0 |          0.0 |             0.0 |          0.1 |       0.2
 ASHE         |            0.0 |         0.0 |        0.0 |      67.8 |         7.4 |         13.1 |             0.6 |          5.3 |       5.7
 BERTIE       |            0.0 |         0.0 |        0.5 |      34.6 |         6.6 |         14.1 |            22.5 |         13.5 |       8.3
 BLADEN       |            0.1 |         0.2 |        1.2 |      40.4 |         8.9 |         17.9 |            13.7 |         15.5 |       2.1
 BRUNSWICK    |            0.0 |         0.0 |       11.2 |      66.2 |        12.7 |          7.8 |             0.0 |          0.6 |       1.5
 BUNCOMBE     |            0.0 |         0.0 |        4.5 |      80.2 |        12.6 |          0.8 |             0.0 |          0.3 |       1.4
 BURKE        |            0.0 |         3.4 |       13.8 |      80.7 |         0.0 |          0.0 |             0.0 |          1.0 |       1.1
 CABARRUS     |            0.0 |         0.0 |       13.1 |      79.4 |         3.6 |          0.0 |             0.0 |          0.0 |       4.0
 CALDWELL     |            0.0 |         0.0 |        0.1 |      93.5 |         1.2 |          0.1 |             0.0 |          1.4 |       3.7
 CARTERET     |            0.1 |         0.3 |        0.9 |      87.1 |         4.6 |          0.8 |             0.6 |          3.4 |       2.1
 CASWELL      |            0.0 |         0.0 |        0.0 |      38.3 |        24.9 |         16.3 |            19.3 |          0.6 |       0.5
 CATAWBA      |            0.0 |         0.1 |        0.5 |      98.5 |         0.5 |          0.1 |             0.0 |          0.0 |       0.3
 CHATHAM      |            0.0 |         0.5 |       11.9 |      63.9 |        13.2 |          4.1 |             0.0 |          0.6 |       5.7
 CLEVELAND    |            0.0 |         0.0 |       10.8 |      58.7 |        26.9 |          0.1 |             0.0 |          2.9 |       0.6
 COLUMBUS     |            0.0 |         1.1 |       10.1 |      45.3 |        26.5 |         11.9 |             0.0 |          3.9 |       1.1
 CRAVEN       |            0.1 |         0.2 |       10.5 |      72.8 |        11.4 |          2.5 |             0.1 |          1.8 |       0.6
 CUMBERLAND   |            0.0 |         1.6 |        2.0 |      61.2 |        23.6 |          9.0 |             0.0 |          0.7 |       1.8
 DARE         |            0.0 |         0.4 |        0.4 |      67.1 |         6.5 |          4.4 |             0.1 |          3.9 |      17.2
 DAVIDSON     |            0.0 |         0.7 |        8.2 |      86.6 |         0.3 |          0.0 |             0.0 |          0.1 |       4.1
 DAVIE        |            0.0 |         0.0 |        0.2 |      67.4 |        14.0 |          9.9 |             0.0 |          0.0 |       8.5
 DUPLIN       |            0.0 |         0.0 |        1.1 |      89.4 |         2.5 |          0.0 |             0.0 |          5.7 |       1.3
 DURHAM       |            0.0 |         0.3 |       15.2 |      80.9 |         0.0 |          0.0 |             0.0 |          0.0 |       3.7
 FORSYTH      |            0.0 |         0.7 |       17.0 |      61.4 |        16.9 |          0.1 |             0.0 |          0.0 |       3.9
 GASTON       |            0.0 |         0.0 |        0.4 |      81.7 |        17.6 |          0.0 |             0.0 |          0.0 |       0.4
 GATES        |            0.0 |         0.0 |        4.5 |      43.8 |        41.7 |          0.3 |             0.0 |          6.4 |       3.4
 GRANVILLE    |            0.1 |        13.9 |        7.4 |      75.8 |         1.4 |          0.0 |             0.0 |          0.6 |       0.8
 GUILFORD     |            0.0 |         0.0 |        4.4 |      83.5 |         6.1 |          2.1 |             0.0 |          0.0 |       3.9
 HALIFAX      |            0.0 |         0.0 |        0.6 |       9.0 |        17.9 |         33.7 |            20.2 |         16.5 |       2.1
 HARNETT      |            0.0 |         0.0 |        0.4 |      78.9 |         4.3 |          6.7 |             0.0 |          0.3 |       9.4
 HENDERSON    |            0.0 |         0.0 |        0.0 |      45.9 |        25.0 |         22.3 |             3.6 |          0.3 |       2.9
 HYDE         |            0.0 |         2.0 |        7.0 |      57.7 |         1.7 |          0.0 |             0.0 |         27.8 |       3.8
 IREDELL      |            0.0 |         0.1 |        0.5 |      83.0 |         8.7 |          5.2 |             1.6 |          0.8 |       0.2
 JACKSON      |            0.0 |         0.2 |        8.6 |      81.5 |         0.8 |          0.1 |             0.0 |          0.9 |       7.8
 JOHNSTON     |            0.0 |         0.0 |        0.9 |      68.1 |        13.3 |          9.4 |             2.6 |          0.9 |       4.8
 LENOIR       |            0.0 |         0.1 |       16.7 |      79.5 |         2.7 |          0.2 |             0.0 |          0.0 |       0.8
 LINCOLN      |            0.1 |         0.0 |        0.6 |      75.7 |        16.8 |          6.3 |             0.2 |          0.0 |       0.3
 MADISON      |            0.0 |         0.1 |        2.3 |      68.5 |        24.5 |          0.5 |             0.0 |          2.5 |       1.6
 MCDOWELL     |            0.0 |         0.0 |        0.0 |      67.9 |        28.1 |          1.2 |             0.0 |          0.8 |       2.0
 MECKLENBURG  |            0.0 |         0.0 |        5.5 |      85.0 |         8.0 |          1.0 |             0.0 |          0.0 |       0.5
 MITCHELL     |            0.0 |         0.2 |        3.4 |      91.1 |         1.3 |          0.5 |             0.2 |          1.9 |       1.5
 MONTGOMERY   |            0.0 |        24.3 |        5.1 |      56.8 |         2.5 |          0.1 |             0.0 |          7.6 |       3.6
 MOORE        |            7.2 |        23.7 |       23.2 |      24.5 |         3.4 |          5.7 |             4.2 |          5.0 |       3.1
 NASH         |            0.0 |         0.0 |        0.5 |      79.3 |         4.7 |          7.8 |             1.8 |          4.8 |       1.0
 NEW HANOVER  |            0.0 |         0.0 |        0.1 |      97.8 |         0.1 |          0.0 |             0.0 |          0.2 |       1.7
 NORTHAMPTON  |            0.0 |         0.0 |        1.3 |      64.9 |         7.3 |          6.7 |            10.0 |          2.6 |       7.3
 ONSLOW       |            0.0 |         0.0 |        1.9 |      61.2 |        12.2 |          7.6 |             4.2 |          7.3 |       5.7
 ORANGE       |            0.0 |         0.1 |        8.6 |      86.1 |         3.3 |          1.5 |             0.0 |          0.0 |       0.5
 PENDER       |            0.0 |         0.4 |        1.0 |      73.4 |        19.8 |          2.3 |             0.1 |          1.9 |       1.2
 PERSON       |            0.0 |         0.0 |        0.0 |      72.4 |        10.3 |         16.2 |             0.0 |          0.3 |       0.8
 PITT         |            0.0 |         0.0 |        0.3 |      81.4 |         7.7 |          1.7 |             2.8 |          0.2 |       6.0
 POLK         |            0.0 |         0.0 |        0.0 |      55.4 |        25.2 |          9.5 |             5.8 |          0.4 |       3.7
 RANDOLPH     |            0.0 |         6.0 |       12.7 |      52.6 |        24.6 |          0.3 |             0.0 |          2.2 |       1.6
 RICHMOND     |            0.0 |         0.0 |        0.2 |      54.3 |        32.8 |          8.2 |             0.1 |          3.4 |       1.0
 ROBESON      |            9.5 |        11.6 |        3.9 |      68.3 |         0.0 |          0.0 |             0.0 |          3.0 |       3.7
 ROCKINGHAM   |            0.0 |         0.1 |       11.2 |      84.0 |         4.0 |          0.1 |             0.0 |          0.0 |       0.6
 ROWAN        |            0.0 |         0.0 |        7.3 |      59.3 |        26.4 |          3.6 |             0.1 |          0.3 |       3.0
 RUTHERFORD   |            0.0 |         0.0 |        0.3 |      73.5 |        11.7 |         12.7 |             0.1 |          1.3 |       0.4
 SAMPSON      |            0.0 |         0.2 |        1.0 |      70.0 |         5.1 |          6.4 |             7.3 |          5.7 |       4.4
 STANLY       |            0.0 |         0.0 |        0.3 |      45.2 |        13.0 |         14.7 |            15.9 |          5.0 |       5.9
 SURRY        |            0.0 |         0.0 |        0.3 |      87.6 |         1.9 |          3.2 |             6.1 |          0.4 |       0.4
 TRANSYLVANIA |            0.0 |         0.2 |        0.4 |      71.1 |         5.7 |         11.9 |             0.1 |          1.8 |       8.9
 UNION        |            0.0 |         0.0 |        0.4 |      97.1 |         0.9 |          0.0 |             0.0 |          0.0 |       1.5
 VANCE        |            0.0 |         0.0 |        0.4 |      79.6 |        12.4 |          0.0 |             0.0 |          0.5 |       7.0
 WAKE         |            0.0 |         0.0 |        3.3 |      96.3 |         0.2 |          0.0 |             0.0 |          0.0 |       0.3
 WATAUGA      |            0.0 |         0.0 |        0.0 |      96.6 |         0.0 |          0.0 |             0.0 |          0.0 |       3.3
 WAYNE        |            0.0 |         0.2 |       15.6 |      58.9 |        24.1 |          0.4 |             0.0 |          0.2 |       0.6
 WILKES       |            0.0 |         0.0 |        0.9 |      72.9 |        11.4 |         12.2 |             0.1 |          1.0 |       1.5
 WILSON       |            0.0 |         0.0 |        0.5 |      95.0 |         2.0 |          0.2 |             0.0 |          0.0 |       2.4
 YANCEY       |            0.0 |         0.0 |        0.2 |      94.0 |         0.3 |          0.0 |             0.0 |          1.5 |       4.0
(70 rows)

Time: 43234.934 ms (00:43.235)
*/

-- create new table
CREATE TABLE omb_county
(
	county_desc varchar(255),
	designation varchar(255)
);

-- load in our OMB county designations
COPY omb_county FROM '/Users/mtdukes/Dropbox/projects/wral/electionland/data/early-voting/evl-analysis/data/omb_county.csv' DELIMITERS ',' CSV;

-- create new tier table
CREATE TABLE tier_county
(
	county_desc varchar(255),
	tier varchar(255)
);

-- load in our commerce county designations
COPY tier_county FROM '/Users/mtdukes/Dropbox/projects/wral/electionland/data/early-voting/evl-analysis/data/commerce_county_tiers.csv' DELIMITERS ',' CSV;

ALTER TABLE voters_iso
ADD COLUMN
omb varchar(255);

ALTER TABLE voters_iso
ADD COLUMN
tier varchar(255);

-- update our omb designation
UPDATE voters_iso
SET omb = omb_county.designation
FROM omb_county
WHERE voters_iso.county_desc = omb_county.county_desc;

/*
UPDATE 6433969
Time: 181281.681 ms (03:01.282)
*/

-- update our county tier
UPDATE voters_iso
SET tier = tier_county.tier
FROM tier_county
WHERE voters_iso.county_desc = tier_county.county_desc;

/*
UPDATE 6433969
Time: 178110.801 ms (02:58.111)
*/

-- let's look at the breakdown by omb designation
SELECT omb, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY omb
ORDER BY avg_dist;

/*
   omb    | avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------+----------
 urban    |     0.18 |     1.49 |       16 |    -14.5
 suburban |     0.58 |     2.22 |     18.5 |      -16
 rural    |     0.68 |     3.69 |     17.5 |    -16.5
(3 rows)

Time: 66469.327 ms (01:06.469)
*/

-- binning by raw number and omb
SELECT omb AS county,
SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY omb;

/*
  county  | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
----------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 rural    |          12339 |       35457 |      46299 |    776952 |      103688 |        69255 |           35297 |        37912 |     42385
 suburban |            126 |        8446 |      76777 |   1103834 |      183493 |        63090 |            8459 |         7534 |     34892
 urban    |            175 |        8676 |     212989 |   3149858 |      265619 |        55767 |            9403 |        16879 |     68368
(3 rows)

Time: 46745.142 ms (00:46.745)
*/

-- binning by pct and omb
SELECT omb AS county,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY omb;

/*
  county  | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
----------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 rural    |            1.1 |         3.1 |        4.0 |      67.0 |         8.9 |          6.0 |             3.0 |          3.3 |       3.7
 suburban |            0.0 |         0.6 |        5.2 |      74.2 |        12.3 |          4.2 |             0.6 |          0.5 |       2.3
 urban    |            0.0 |         0.2 |        5.6 |      83.2 |         7.0 |          1.5 |             0.2 |          0.4 |       1.8
(3 rows)

Time: 43028.714 ms (00:43.029)
*/

-- let's look at the breakdown by tier designation
-- 3 is the 20 least distressed counties
SELECT tier, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY tier
ORDER BY avg_dist;

/*
 tier | avg_dist | std_dist | max_dist | min_dist 
------+----------+----------+----------+----------
 3    |     0.15 |     1.80 |     18.5 |      -16
 2    |     0.51 |     2.18 |     17.5 |    -14.5
 1    |     1.01 |     4.06 |       17 |    -16.5
(3 rows)

Time: 42088.957 ms (00:42.089)
*/

-- binning by raw number and tier
SELECT tier AS county,
SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY tier;

/*
 county | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
--------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 1      |           7347 |       13547 |      18485 |    287878 |       56566 |        37102 |           18888 |        22081 |     15482
 2      |            193 |       15907 |     142397 |   2010551 |      309526 |        84223 |           22646 |        29648 |     82592
 3      |           5100 |       23125 |     175183 |   2732215 |      186708 |        66787 |           11625 |        10596 |     47571
(3 rows)

Time: 42576.725 ms (00:42.577)
*/

-- binning by pct and tier
SELECT tier AS county,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY tier;

/*
 county | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
--------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 1      |            1.5 |         2.8 |        3.9 |      60.3 |        14.4 |          7.8 |             4.0 |          4.6 |       3.2
 2      |            0.0 |         0.6 |        5.3 |      74.5 |        15.3 |          3.1 |             0.8 |          1.1 |       3.1
 3      |            0.2 |         0.7 |        5.4 |      83.8 |         8.0 |          2.0 |             0.4 |          0.3 |       1.5
(3 rows)

Time: 43466.286 ms (00:43.466)
*/

-- how many voters were affected in each county?
-- Durham and Alexander had none in this category
SELECT county_desc,
COUNT(county_desc) AS voter_count
FROM voters_iso
WHERE dist_diff > 1
GROUP BY county_desc
ORDER BY voter_count DESC;

-- calculate the probability that a subgroup voter was moved more than 1 mile away
SELECT race_code AS race,
SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END) AS moved_voters,
COUNT(race_code) AS registered_voters,
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "moved_pct"
FROM voters_iso
WHERE dist_diff IS NOT NULL
GROUP BY race_code;

/*
 race | moved_voters | registered_voters | moved_pct 
------+--------------+-------------------+-----------
 A    |         5593 |             85368 |       6.6
 B    |       158173 |           1365652 |      11.6
 I    |         3675 |             46416 |       7.9
 M    |         4148 |             42724 |       9.7
 O    |        19264 |            177710 |      10.8
 U    |        23513 |            233671 |      10.1
 W    |       579705 |           4274458 |      13.6
(7 rows)

Time: 37464.624 ms (00:37.465)
*/

-- calculate the probability that a subgroup voter was moved more than 1 mile away
SELECT party_cd AS party,
SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END) AS moved_voters,
COUNT(party_cd) AS registered_voters,
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "moved_pct"
FROM voters_iso
WHERE dist_diff IS NOT NULL
GROUP BY party_cd;

/*
 party | moved_voters | registered_voters | moved_pct 
-------+--------------+-------------------+-----------
 CST   |           40 |               338 |      11.8
 DEM   |       278931 |           2351501 |      11.9
 GRE   |           55 |               485 |      11.3
 LIB   |         3811 |             32901 |      11.6
 REP   |       265022 |           1857084 |      14.3
 UNA   |       246212 |           1983690 |      12.4
(6 rows)

Time: 37115.033 ms (00:37.115)
*/

SELECT omb,
SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END) AS moved_voters,
COUNT(omb) AS registered_voters,
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END)/count(omb)::numeric,3)*100::numeric,1) AS "moved_pct"
FROM voters_iso
WHERE dist_diff IS NOT NULL
GROUP BY omb;

/*
   omb    | moved_voters | registered_voters | moved_pct 
----------+--------------+-------------------+-----------
 rural    |       208240 |           1079287 |      19.3
 suburban |       255042 |           1444225 |      17.7
 urban    |       330789 |           3702487 |       8.9
(3 rows)

Time: 39020.502 ms (00:39.021)
*/

SELECT tier,
SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END) AS moved_voters,
COUNT(tier) AS registered_voters,
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END)/count(tier)::numeric,3)*100::numeric,1) AS "moved_pct"
FROM voters_iso
WHERE dist_diff IS NOT NULL
GROUP BY tier;

/*
 tier | moved_voters | registered_voters | moved_pct 
------+--------------+-------------------+-----------
 1    |       112556 |            439813 |      25.6
 2    |       416395 |           2585443 |      16.1
 3    |       265120 |           3200743 |       8.3
(3 rows)

Time: 35143.678 ms (00:35.144)
*/

-- let's look at ethnicity by stats
SELECT ethnic_code, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
GROUP BY ethnic_code
ORDER BY avg_dist;

/*
 ethnic_code | avg_dist | std_dist | max_dist | min_dist 
-------------+----------+----------+----------+----------
 HL          |     0.23 |     1.92 |     17.5 |    -14.5
 UN          |     0.35 |     2.04 |     18.5 |      -16
 NL          |     0.37 |     2.26 |     18.5 |    -16.5
*/

-- Ethnicity by rate
SELECT ethnic_code,
SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END) AS moved_voters,
COUNT(ethnic_code) AS registered_voters,
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 THEN 1 ELSE 0 END)/count(ethnic_code)::numeric,3)*100::numeric,1) AS "moved_pct"
FROM voters_iso
WHERE dist_diff IS NOT NULL
GROUP BY ethnic_code;

/*
 ethnic_code | moved_voters | registered_voters | moved_pct 
-------------+--------------+-------------------+-----------
 HL          |        19748 |            175702 |      11.2
 NL          |       627883 |           4850140 |      12.9
 UN          |       146440 |           1200157 |      12.2
*/

SELECT ethnic_code,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY ethnic_code;

/*
 ethnic_code | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
-------------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 HL          |            0.2 |         0.7 |        6.1 |      78.7 |         8.2 |          2.2 |             0.4 |          0.5 |       3.0
 NL          |            0.2 |         0.9 |        5.1 |      78.1 |         8.7 |          3.0 |             0.9 |          1.0 |       2.1
 UN          |            0.1 |         0.6 |        5.6 |      78.4 |         8.3 |          2.8 |             0.7 |          0.8 |       2.8
(3 rows)

Time: 43573.523 ms (00:43.574)
*/

-- show me county stats and nulls
SELECT county_desc,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
round(round(SUM(coord_null) / COUNT(gid)::numeric,3)*100::numeric,1) AS pct_null_coords,
round(round((SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END)- SUM(coord_null)) / COUNT(county_desc)::numeric,3)*100::numeric,1) AS pct_oor,
round(round(SUM(coord_null) / COUNT(gid)::numeric,3)*100::numeric,1) + round(round((SUM(CASE WHEN dist_diff IS NULL THEN 1 ELSE 0 END)- SUM(coord_null)) / COUNT(county_desc)::numeric,3)*100::numeric,1) AS total_invalid
FROM voters_iso
GROUP BY county_desc
ORDER BY avg_dist DESC;

/*
 county_desc  | avg_dist | std_dist | pct_null_coords | pct_oor | total_invalid 
--------------+----------+----------+-----------------+---------+---------------
 HALIFAX      |     6.58 |     4.02 |             2.1 |    16.5 |          18.6
 BERTIE       |     5.62 |     5.94 |             8.3 |    13.5 |          21.8
 CASWELL      |     4.45 |     4.81 |             0.5 |     0.6 |           1.1
 STANLY       |     4.05 |     5.25 |             5.9 |     5.0 |          10.9
 BLADEN       |     3.94 |     4.85 |             2.1 |    15.5 |          17.6
 HENDERSON    |     3.07 |     3.49 |             2.9 |     0.3 |           3.2
 POLK         |     2.50 |     3.46 |             3.7 |     0.4 |           4.1
 NORTHAMPTON  |     2.22 |     4.45 |             7.3 |     2.6 |           9.9
 RICHMOND     |     2.04 |     2.75 |             1.0 |     3.4 |           4.4
 SAMPSON      |     1.77 |     4.07 |             4.4 |     5.7 |          10.1
 ONSLOW       |     1.67 |     3.29 |             5.7 |     7.3 |          13.0
 ASHE         |     1.63 |     3.20 |             5.7 |     5.3 |          11.0
 PERSON       |     1.55 |     2.78 |             0.8 |     0.3 |           1.1
 JOHNSTON     |     1.48 |     3.02 |             4.8 |     0.9 |           5.7
 GATES        |     1.44 |     1.97 |             3.4 |     6.4 |           9.8
 RUTHERFORD   |     1.39 |     2.68 |             0.4 |     1.3 |           1.7
 WILKES       |     1.29 |     2.66 |             1.5 |     1.0 |           2.5
 COLUMBUS     |     1.25 |     2.91 |             1.1 |     3.9 |           5.0
 DAVIE        |     1.25 |     2.30 |             8.5 |     0.0 |           8.5
 TRANSYLVANIA |     1.24 |     2.86 |             8.9 |     1.8 |          10.7
 CUMBERLAND   |     1.17 |     2.49 |             1.8 |     0.7 |           2.5
 SURRY        |     1.16 |     3.58 |             0.4 |     0.4 |           0.8
 NASH         |     1.07 |     2.72 |             1.0 |     4.8 |           5.8
 LINCOLN      |     1.02 |     2.22 |             0.3 |     0.0 |           0.3
 ROWAN        |     0.95 |     2.20 |             3.0 |     0.3 |           3.3
 PENDER       |     0.93 |     2.05 |             1.2 |     1.9 |           3.1
 MCDOWELL     |     0.92 |     1.49 |             2.0 |     0.8 |           2.8
 IREDELL      |     0.84 |     2.41 |             0.2 |     0.8 |           1.0
 HARNETT      |     0.81 |     2.34 |             9.4 |     0.3 |           9.7
 PITT         |     0.71 |     2.42 |             6.0 |     0.2 |           6.2
 BRUNSWICK    |     0.66 |     2.49 |             1.5 |     0.6 |           2.1
 DARE         |     0.60 |     1.93 |            17.2 |     3.9 |          21.1
 MADISON      |     0.55 |     1.29 |             1.6 |     2.5 |           4.1
 CLEVELAND    |     0.48 |     1.45 |             0.6 |     2.9 |           3.5
 GASTON       |     0.41 |     0.73 |             0.4 |     0.0 |           0.4
 BUNCOMBE     |     0.33 |     1.34 |             1.4 |     0.3 |           1.7
 VANCE        |     0.32 |     0.82 |             7.0 |     0.5 |           7.5
 CHATHAM      |     0.32 |     2.04 |             5.7 |     0.6 |           6.3
 CRAVEN       |     0.25 |     1.59 |             0.6 |     1.8 |           2.4
 ALAMANCE     |     0.24 |     0.52 |             0.9 |     0.1 |           1.0
 WAYNE        |     0.22 |     2.01 |             0.6 |     0.2 |           0.8
 GUILFORD     |     0.21 |     1.33 |             3.9 |     0.0 |           3.9
 CALDWELL     |     0.18 |     0.53 |             3.7 |     1.4 |           5.1
 CARTERET     |     0.16 |     1.72 |             2.1 |     3.4 |           5.5
 MECKLENBURG  |     0.14 |     1.10 |             0.5 |     0.0 |           0.5
 WILSON       |     0.09 |     0.46 |             2.4 |     0.0 |           2.4
 NEW HANOVER  |     0.03 |     0.30 |             1.7 |     0.2 |           1.9
 CATAWBA      |     0.00 |     0.55 |             0.3 |     0.0 |           0.3
 YANCEY       |     0.00 |     0.25 |             4.0 |     1.5 |           5.5
 WATAUGA      |     0.00 |     0.15 |             3.3 |     0.0 |           3.3
 FORSYTH      |    -0.02 |     1.68 |             3.9 |     0.0 |           3.9
 UNION        |    -0.04 |     0.42 |             1.5 |     0.0 |           1.5
 WAKE         |    -0.05 |     0.46 |             0.3 |     0.0 |           0.3
 RANDOLPH     |    -0.07 |     2.62 |             1.6 |     2.2 |           3.8
 ROCKINGHAM   |    -0.09 |     0.96 |             0.6 |     0.0 |           0.6
 ORANGE       |    -0.10 |     1.53 |             0.5 |     0.0 |           0.5
 MITCHELL     |    -0.12 |     1.22 |             1.5 |     1.9 |           3.4
 DUPLIN       |    -0.15 |     0.90 |             1.3 |     5.7 |           7.0
 LENOIR       |    -0.29 |     0.96 |             0.8 |     0.0 |           0.8
 JACKSON      |    -0.31 |     0.89 |             7.8 |     0.9 |           8.7
 DAVIDSON     |    -0.34 |     1.18 |             4.1 |     0.1 |           4.2
 CABARRUS     |    -0.34 |     1.11 |             4.0 |     0.0 |           4.0
 HYDE         |    -0.48 |     1.42 |             3.8 |    27.8 |          31.6
 DURHAM       |    -0.51 |     1.13 |             3.7 |     0.0 |           3.7
 BURKE        |    -0.74 |     1.59 |             1.1 |     1.0 |           2.1
 ALEXANDER    |    -0.74 |     1.95 |             0.2 |     0.1 |           0.3
 GRANVILLE    |    -1.21 |     2.78 |             0.8 |     0.6 |           1.4
 MONTGOMERY   |    -1.78 |     2.87 |             3.6 |     7.6 |          11.2
 ROBESON      |    -2.42 |     4.31 |             3.7 |     3.0 |           6.7
 MOORE        |    -2.66 |     5.65 |             3.1 |     5.0 |           8.1
(70 rows)
*/

-- let's look at averages without anything less than 1
SELECT round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff > 1;

/*
 avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------
     4.43 |     3.13 |     18.5 |      1.5
*/

-- now by race without anything less than 1
SELECT race_code, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff > 1
GROUP BY race_code
ORDER BY avg_dist;

/*
 race_code | avg_dist | std_dist | max_dist | min_dist 
-----------+----------+----------+----------+----------
 A         |     3.45 |     2.50 |     17.5 |      1.5
 O         |     3.90 |     2.76 |     17.5 |      1.5
 M         |     3.97 |     2.79 |     17.5 |      1.5
 U         |     4.20 |     3.04 |     17.5 |      1.5
 B         |     4.36 |     3.25 |     18.5 |      1.5
 W         |     4.49 |     3.11 |     18.5 |      1.5
 I         |     4.56 |     2.81 |       18 |      1.5
(7 rows)

Time: 42211.927 ms (00:42.212)
*/

-- by political party without anything less than 1
SELECT party_cd,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist, MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff > 1
GROUP BY party_cd
ORDER BY avg_dist;

/*
 party_cd | avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------+----------
 GRE      |     3.89 |     2.83 |       13 |      1.5
 LIB      |     4.17 |     2.84 |     17.5 |      1.5
 CST      |     4.28 |     3.49 |     14.5 |      1.5
 UNA      |     4.37 |     3.04 |     18.5 |      1.5
 DEM      |     4.42 |     3.21 |     18.5 |      1.5
 REP      |     4.49 |     3.12 |     18.5 |      1.5
(6 rows)

Time: 41921.700 ms (00:41.922)
*/

-- by omb designation without anything less than 1
SELECT omb, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff > 1
GROUP BY omb
ORDER BY avg_dist;

/*
  omb    | avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------+----------
 urban    |     3.54 |     2.38 |       16 |      1.5
 suburban |     4.21 |     2.75 |     18.5 |      1.5
 rural    |     6.11 |     3.86 |     17.5 |      1.5
(3 rows)

Time: 43682.898 ms (00:43.683)
*/

-- by tier without anything less than 1
SELECT tier, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff > 1
GROUP BY tier
ORDER BY avg_dist;

/*
 tier | avg_dist | std_dist | max_dist | min_dist 
------+----------+----------+----------+----------
 2    |     4.13 |     2.99 |     17.5 |      1.5
 3    |     4.22 |     2.84 |     18.5 |      1.5
 1    |     6.03 |     3.71 |       17 |      1.5
*/

-- let's look at averages without anything between -1 and 1
SELECT round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff < -1 OR dist_diff > 1;

/*
 avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------
     1.78 |     4.73 |     18.5 |    -16.5
(1 row)

Time: 41666.379 ms (00:41.666)
*/

-- by race without anything between -1 and 1
SELECT race_code, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff < -1 OR dist_diff > 1
GROUP BY race_code
ORDER BY avg_dist;

/*
 race_code | avg_dist | std_dist | max_dist | min_dist 
-----------+----------+----------+----------+----------
 I         |    -2.84 |     5.93 |       18 |    -14.5
 A         |     0.23 |     3.81 |     17.5 |      -14
 O         |     1.06 |     4.43 |     17.5 |    -14.5
 M         |     1.13 |     4.27 |     17.5 |    -13.5
 U         |     1.21 |     4.40 |     17.5 |    -14.5
 B         |     1.47 |     4.83 |     18.5 |    -16.5
 W         |     2.01 |     4.68 |     18.5 |    -16.5
(7 rows)

Time: 44622.030 ms (00:44.622)
*/

-- by political party without anything between -1 and 1
SELECT party_cd,
round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist, MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff < -1 OR dist_diff > 1
GROUP BY party_cd
ORDER BY avg_dist;

/*
 party_cd | avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------+----------
 GRE      |     0.89 |     4.26 |       13 |      -10
 LIB      |     1.48 |     4.50 |     17.5 |    -15.5
 DEM      |     1.59 |     4.83 |     18.5 |    -16.5
 UNA      |     1.70 |     4.65 |     18.5 |    -16.5
 REP      |     2.06 |     4.70 |     18.5 |      -16
 CST      |     2.13 |     4.36 |     14.5 |     -5.5
(6 rows)

Time: 44187.885 ms (00:44.188)
*/

-- by omb designation without anything between -1 and 1
SELECT omb, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff < -1 OR dist_diff > 1
GROUP BY omb
ORDER BY avg_dist;

/*
   omb    | avg_dist | std_dist | max_dist | min_dist 
----------+----------+----------+----------+----------
 urban    |     1.05 |     3.64 |       16 |    -14.5
 suburban |     2.38 |     4.04 |     18.5 |      -16
 rural    |     2.42 |     6.65 |     17.5 |    -16.5
(3 rows)

Time: 43878.881 ms (00:43.879)
*/

-- by tier without anything between -1 and 1
SELECT tier, round(AVG(dist_diff)::numeric,2) as avg_dist,
round(STDDEV_POP(dist_diff)::numeric,2) as std_dist,
MAX(dist_diff) as max_dist,
MIN(dist_diff) as min_dist
FROM voters_iso
WHERE dist_diff < -1 OR dist_diff > 1
GROUP BY tier
ORDER BY avg_dist;

/*
 tier | avg_dist | std_dist | max_dist | min_dist 
------+----------+----------+----------+----------
 3    |     0.94 |     4.57 |     18.5 |      -16
 2    |     2.16 |     4.17 |     17.5 |    -14.5
 1    |     2.91 |     6.47 |       17 |    -16.5
(3 rows)

Time: 43847.453 ms (00:43.847)
*/

-- binning overall by pct
SELECT ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(gid)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(gid)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso;

/*
 closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
            0.2 |         0.8 |        5.2 |      78.2 |         8.6 |          2.9 |             0.8 |          1.0 |       2.3
(1 row)

Time: 42238.007 ms (00:42.238)
*/

-- bining by raw number
SELECT SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff <= 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff > 1 AND dist_diff <= 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff > 5 AND dist_diff <= 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso;

/*
 closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
          12640 |       52579 |     336065 |   5030644 |      552800 |       188112 |           53159 |        62325 |    145645
(1 row)

Time: 41082.848 ms (00:41.083)
*/
