'''
A simple script to capture lat/lng coordinates
from the State Board of Elections & Ethics
Enforcement 2018 early voting lookup site
here: vt.ncsbe.gov/ossite

There does not appear to be lat/lng data from 
2014 early voting locations, which must be
geolocated manually.

Usage:
python getSites.py

By @mtdukes
'''
# import the libraries we need
import json, requests, csv

#json available via GET from the following site
url = "https://vt.ncsbe.gov/OSSite/GetSites/"
#define the election date
election2018 = '11/06/2018'
#county IDs run from 1 to 100, so we can iterate
countyID = 1

#open a new csv
with open('early_voting2018.csv','w') as f:
	writer = csv.writer(f)
	#establish the header row based on the data we want
	writer.writerow(['id','county','site','street','city_zip','lat','lng'])
	print('New file created...')

	#set up a loop to grab all data for each county
	while countyID < 101:
		#pass in the countyID and election data to return a list of
		#early voting locations for 2018 and store it as a dict
		county = requests.get(url, params={'CountyID': countyID, 'ElectionDate': election2018}).json()

		#iterate through the early voting sites for the given county
		for site in county['SiteList']:
			#write the json data to a row
			writer.writerow([
				countyID,
				county['SelectedCounty']['Name'],
				site['Name'],
				site['SiteAddressStreet'],
				site['SiteAddressCSZ'],
				site['SiteCoordLat'],
				site['SiteCoordLong']])
		print('County ID ' + str(countyID) + ' written to csv')
		#iterate the counter and move on to the next county
		countyID += 1

print('... done')