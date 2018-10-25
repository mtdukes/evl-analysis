# Early voting location analysis

WRAL News is working to use early voting locations for 2018 and 2014, as well as voter registration data, to gage the potential impact of changes for the midterms. Among those changes is a [2018 law mandating that early voting locations](https://www2.ncleg.net/BillLookUp/2017/s325) be open from 7 a.m. to 7 p.m. on any day they are open. A [subsequent law](https://www2.ncleg.net/BillLookup/2017/H335) restored the last Saturday before early voting.

Early, or so-called "one-stop," voting locations allow anybody in the county to vote at any location, instead of voting at a specific precinct.

Republican lawmakers said the changes were important to ensure consistency within counties and cut down on voter confusion. But opponents of the measure said it reduces county flexibility and worried that it could cut voting opportunities for those that couldn't afford to keep sites open for 12 hours straight.

In practice, the number of hours available statewide to vote early at one-stop locations nearly doubled since 2014 - from 25,887 to 49,696. Total early voting hours increased in all but six counties: Henderson, Bladen, Stanly, Polk and McDowell and Halifax.

But the [total number of early locations dropped](https://www.propublica.org/article/bipartisan-furor-as-north-carolina-election-law-shrinks-early-voting-locations-by-almost-20-percent) by about 17 percent since 2014, from 368 to 304. In all, 43 counties lost at least one voting location. Two counties - Henderson and Buncombe - lost four.

Yet a question remains: Did the change in early voting locations disproportionately impact any group of voters in particular?

We're working to answer the question using data on more than 7 million registered voters.

## The data

WRAL News is using the following publicly available data from the State Board of Elections and Ethics Enforcement:

* [2018 voter registration file as of Sept. 22, 2018](https://s3.amazonaws.com/dl.ncsbe.gov/data/ncvoter_Statewide.zip). Coordinates in WGS 84 decimal degrees (EPSG:4326).
* [Latitude/Longitude coordinates for unique NC voter addresses](https://s3.amazonaws.com/dl.ncsbe.gov/ShapeFiles/address_points_sboe.zip)
* 2018 early voting locations
* 2014 early voting locations

## Methodology

Latitude and longitude coordinates for 2018 early voting locations were obtained from the State Board of Elections lookup tool by using the Python script [```getSites.py```](getSites.py). Usage:

```bash
python getSites.py
```

Coordinates were not available for 2014 through this tool, so the bulk of these locations were generated using the [U.S. Census geocoder tool](https://geocoding.geo.census.gov/geocoder/). Addresses that could not be matched were manually researched and recorded using [Google's geocoder tool](https://google-developers.appspot.com/maps/documentation/utils/geocoder/).

In 30 North Carolina counties, there were no changes in early voting locations between 2014 and 2018, so these counties were omitted from the analysis. This left 580 sites for the two midterm elections. Voters in these counties were also omitted from this analysis, leaving 6,433,969 active and inactive voters (both of which are eligible to cast ballots according to state elections officials).

Latitude and longitude coordinates were then matched to active and inactive registered voters on addresses, city, county and zip using MySQL database software. The query failed to match the addresses of 145,645 voters, a 97.7 percent match rate.

We used the free application programming interface (API) from the [Open Route Service](https://openrouteservice.org/documentation/#/reference/isochrones/isochrones/isochrones-service) to generate isochrones - polygons for geographic information systems used to determine driving distances radiating outward from a point source. Isochrones were generated programatically using the Python script [```getIsochrones.py```](getIsochrones.py) (NOTE: Use of the services requires a valid API key). Usage:

```bash
python getIsochrones.py data/early_voting2018.csv 2018
```

Open Route Service limits queries through its API to 10 shapefiles at a time. The service also limits total API queries to 2,500 a day.

Due to these limitations, the Python script runs queries for each site four times to produce a geojson feature collection with shapefiles at 0.5-mile intervals from 0.5 to 20, which each polygon describing a driving distance range.

For example, a point that appears in the isochrone with a mile value of 5, but not in an isochrone with a mile value of 4.5, is within 4.5 and 5 miles from the early voting location.

Voter registration data, in CSV format, [is loaded into the database](http://www.kevfoo.com/2012/01/Importing-CSV-to-PostGIS/), and a separate Python script is used to import the isochrone geojsons using [ogr2ogr](https://www.gdal.org/ogr2ogr.html) and its [pygdaltools wrapper](https://pypi.org/project/pygdaltools/). Usage for [```loadIsochrones.py```](loadIsochrones.py):

```bash
python loadIsochrones.py data/isochrones_lookup.csv
```

[SQL queries](processIsochrones.sql) can then generate mile values for each isochrone intersecting each voter, by county. And by [deduplicating](https://www.periscopedata.com/blog/first-row-per-group-5x-faster) the table based on the voter and keeping the smallest value, we can find the closest site and distance for each voter in 2014 and 2018.

We then used database software to calculate the change in distance from the closest voting location in 2014 and the closest early voting location in 2018 for every active and inactive voter.

Using these values, we can calculate average, median, maximum and standard deviation values for each of the following subroup types defined in the voter registration data:

* Political Party
* Race
* Ethnicity

In addition to the SBOE-defined subgroups, we can also calculate average, median, maximum and standard deviation values for two types of county geographic designations:

* [Federal Office of Management & Budget classifications of urban, surburban and rural counties](https://www.oldnorthstatepolitics.com/p/blog-page_5.html)
* [N.C. Department of Commerce 2018 county tier designations](https://www.nccommerce.com/research-publications/incentive-reports/county-tier-designations)