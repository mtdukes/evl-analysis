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
SUM(CASE WHEN dist_diff >= -1 AND dist_diff < 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff >= 1 AND dist_diff < 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff >= 5 AND dist_diff < 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY party_cd;

/*
 party | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
-------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 CST   |              0 |           1 |         17 |       270 |          37 |            9 |               3 |            3 |        22
 DEM   |           6091 |       19220 |     129537 |   1849376 |      250189 |        71524 |           21374 |        22527 |     48875
 GRE   |              0 |           6 |         36 |       378 |          50 |           13 |               2 |            2 |        32
 LIB   |             67 |         242 |       1822 |     25969 |        3526 |         1044 |             182 |          293 |       968
 REP   |           2856 |       17174 |      94734 |   1416035 |      229591 |        76455 |           16682 |        21879 |     42884
 UNA   |           3626 |       15936 |     109919 |   1547542 |      220069 |        68378 |           14916 |        17621 |     52864
(6 rows)

Time: 34324.165 ms (00:34.324)
*/

-- View as a percentage of the party_cd population
SELECT party_cd AS party,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff < 1 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= 1 AND dist_diff < 5 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= 5 AND dist_diff < 10 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(party_cd)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(party_cd)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY party_cd;

/*
 party | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
-------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 CST   |            0.0 |         0.3 |        4.7 |      74.4 |        10.2 |          2.5 |             0.8 |          0.8 |       6.1
 DEM   |            0.3 |         0.8 |        5.3 |      76.3 |        10.3 |          3.0 |             0.9 |          0.9 |       2.0
 GRE   |            0.0 |         1.2 |        6.9 |      72.8 |         9.6 |          2.5 |             0.4 |          0.4 |       6.2
 LIB   |            0.2 |         0.7 |        5.3 |      76.0 |        10.3 |          3.1 |             0.5 |          0.9 |       2.8
 REP   |            0.1 |         0.9 |        4.9 |      73.7 |        11.9 |          4.0 |             0.9 |          1.1 |       2.2
 UNA   |            0.2 |         0.8 |        5.4 |      75.3 |        10.7 |          3.3 |             0.7 |          0.9 |       2.6
(6 rows)

Time: 36968.567 ms (00:36.969)
*/

-- Count the frequency of bins for each race subgroup
SELECT race_code AS race,
SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END) AS "closer_than_10",
SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END) AS "5_10_closer",
SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END) AS "1_5_closer",
SUM(CASE WHEN dist_diff >= -1 AND dist_diff < 1 THEN 1 ELSE 0 END) AS "no change",
SUM(CASE WHEN dist_diff >= 1 AND dist_diff < 5 THEN 1 ELSE 0 END) AS "1_5_further",
SUM(CASE WHEN dist_diff >= 5 AND dist_diff < 10 THEN 1 ELSE 0 END) AS "5_10_further",
SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END) AS "further_than_10",
SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END) AS out_of_range,
SUM(coord_null) AS no_coords
FROM voters_iso
GROUP BY race_code;

/*
 race | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 A    |             50 |         300 |       5375 |     72204 |        6104 |         1142 |             153 |          205 |      3078
 B    |           4011 |        9897 |      79119 |   1078057 |      141563 |        37263 |           13330 |        10964 |     29561
 I    |            715 |        3944 |       3018 |     34134 |        3089 |         1311 |             167 |         1544 |      1852
 M    |             65 |         233 |       2543 |     34655 |        3974 |         1026 |             183 |          189 |      1540
 O    |            424 |        1462 |      10396 |    140906 |       19124 |         4422 |             801 |          889 |      4524
 U    |            277 |        1266 |      15362 |    186812 |       22224 |         6158 |            1330 |         1384 |      9116
 W    |           7098 |       35477 |     220252 |   3292802 |      507384 |       166101 |           37195 |        47150 |     95974
(7 rows)

Time: 35783.816 ms (00:35.784)
*/

-- View as a percentage of the race_code population
SELECT race_code AS race,
ROUND(ROUND(SUM(CASE WHEN dist_diff < -10 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "closer_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -10 AND dist_diff < -5 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "5_10_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -5 AND dist_diff < -1 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "1_5_closer",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= -1 AND dist_diff < 1 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "no change",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= 1 AND dist_diff < 5 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "1_5_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff >= 5 AND dist_diff < 10 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "5_10_further",
ROUND(ROUND(SUM(CASE WHEN dist_diff > 10 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS "further_than_10",
ROUND(ROUND(SUM(CASE WHEN dist_diff IS NULL AND coord_null = 0 THEN 1 ELSE 0 END)/count(race_code)::numeric,3)*100::numeric,1) AS out_of_range,
ROUND(ROUND(SUM(coord_null)/count(race_code)::numeric,3)*100::numeric,1) AS no_coords
FROM voters_iso
GROUP BY race_code;

/*
  race | closer_than_10 | 5_10_closer | 1_5_closer | no change | 1_5_further | 5_10_further | further_than_10 | out_of_range | no_coords 
-------+----------------+-------------+------------+-----------+-------------+--------------+-----------------+--------------+-----------
 A     |            0.1 |         0.3 |        6.1 |      81.4 |         6.9 |          1.3 |             0.2 |          0.2 |       3.5
 B     |            0.3 |         0.7 |        5.6 |      76.7 |        10.1 |          2.6 |             0.9 |          0.8 |       2.1
 I     |            1.4 |         7.9 |        6.1 |      68.5 |         6.2 |          2.6 |             0.3 |          3.1 |       3.7
 M     |            0.1 |         0.5 |        5.7 |      78.0 |         8.9 |          2.3 |             0.4 |          0.4 |       3.5
 O     |            0.2 |         0.8 |        5.7 |      76.9 |        10.4 |          2.4 |             0.4 |          0.5 |       2.5
 U     |            0.1 |         0.5 |        6.3 |      76.5 |         9.1 |          2.5 |             0.5 |          0.6 |       3.7
 W     |            0.2 |         0.8 |        5.0 |      74.5 |        11.5 |          3.8 |             0.8 |          1.1 |       2.2
(7 rows)

Time: 34814.091 ms (00:34.814)
*/
