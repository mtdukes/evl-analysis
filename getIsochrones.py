'''
Simple script for getting isochrone shapes for designated
county early voting sites for the given year. Saves each 
site's isochrone into a geojson feature collection
in a separate file.

API Docs
https://openrouteservice.org/documentation/#/reference/isochrones/isochrones/isochrones-service

Except there's apparently a python wrapper (maybe we'll rewrite?):
https://github.com/GIScience/openrouteservice-py

Usage
python getIsochrones.py data/early_voting2018.csv 2018

Optionally, you can skip to a specific row in the spreadsheet with:
python getIsochrones.py data/early_voting2018.csv 2018 -s 57

By @mtdukes
'''
import json, argparse, csv, requests
from urllib.request import urlopen
from time import sleep

#create blank array for secrets
secret_keys = []

#establish an array to report errors
error_sites = []
#error messages for reporting
error_dict = {
	'400':'The request is incorrect and therefore can not be processed.',
	'401':'Authorization field missing.',
	'403':'Key not authorised.',
	'405':'The specified HTTP method is not supported. For more details, refer to the EndPoint documentation.',
	'413':'The request is larger than the server is able to process, the data provided in the request exceeds the capacity limit.',
	'500':'Unspecified error.',
	'501':'Indicates that the server does not support the functionality needed to fulfill the request.',
	'503':'The server is currently unavailable due to overload or maintenance.',
}

#params for url stored here to change easily
base_url = 'https://api.openrouteservice.org/isochrones?'
locations = ''
profile = 'driving-car'
range_type = 'distance'
interval = 0.5
units = 'mi'
location_type = 'start'

def main(csv_file, year, skipto):
	#get secret keys
	_get_secrets()
	#build file name
	#open input csv
	print('Opening site CSV...')
	with open(csv_file,'r') as csv_input:
		#use dictreader so we can call by column name
		reader = csv.DictReader(csv_input)
		#translate the skip line from the 0 index row to the site_id for the users
		if skipto > 0:
			print('Skipping to row ' + str(skipto+1) + '...')
		#for each line in csv
		for row_id,row in enumerate(reader):
			#if a skipto value was entered, jump to that row
			if row_id >= skipto:
				#if line is a county we are analyzing, construct the url
				if row['is_changed'] == '1':
					#get the coords fromt the spreadsheet
					lnglat = str(row['lng']) + ',' + str(row['lat'])
					#contstruct the file name from the spreadsheet details
					json_output = (row['county'].lower() + '_' + 
						#make sure our site id is stored with leading zeros
						'%03d' % (int(row['site_id']),) +
						'_' + str(year) + '.json')
					#build our list of iso ranges
					iso_range_list = _build_range(interval)
					print('Querying ' + row['site'] + ' data...')
					#loop through our range list so we make two passes
					for idx, iso_range in enumerate(iso_range_list):
						print('Capturing range: ' + str(iso_range))
						#query the openrouteservice api
						site = requests.get(base_url, params={
							'api_key': secret_keys[0],
							'locations': lnglat,
							'profile': profile,
							'range_type': range_type,
							'range': ','.join(map(str, iso_range)), 
							'units': units,
							'location_type': location_type,
							})
						#save a jsonified version
						site_json = site.json()
						#check if we received a valid response
						if site.status_code == 200:
							print('Valid data received...')
							#add some extra features for later identification
							for isochrone in site_json['features']:
								print(isochrone['properties']['value'])
								#use the predefined group index as a county id
								isochrone['properties']['group_index'] = row['county_id']
								#site id is specific to year
								isochrone['properties']['site_id'] = row['site_id']
								isochrone['properties']['year'] = year
								#convert km to miles and add as an explicit property
								isochrone['properties']['mile_value'] = round(isochrone['properties']['value'] / 1609.34,1)
								#if this isn't the first time this runs, append the data to our existing json
								if idx != 0:
									final_json['features'].append(isochrone)
						#if the response isn't valid, deal with errors
						else:
							error_code = str(site.status_code)
							#add the site ID and error code to our error array
							error_sites.append([row['site_id'],error_code])
							#disclose the details with the user
							print('Error ' + error_code + ' in site ID: ' + row['site_id'])
							if error_code in error_dict:
								print(error_dict[error_code])
							else:
								print('An unexpected error was encountered. See detailed error code.')
						#if this is the first run, initialize our final json
						if idx == 0:
							final_json = site_json
						#save the json file for each site in a folder
						with open('data/isochrones/' + json_output, 'w') as outfile:
							json.dump(final_json, outfile)
						print('...saved')
						#pause for rate limiting
						sleep(1)
	print('All valid JSON files saved...')
	#summarize the errors we received
	error_count = len(error_sites)
	print('There were ' + str(error_count) + ' errors:')
	if(error_count > 0):
		for error in error_sites:
			print('Site ID: ' + error[0] + ', Error code: ' + error[1])

def _get_secrets():
	global secret_keys
	with open('.keys') as f:
		secret_keys = f.read().splitlines()

#build a range suitable for the ORS specs and returns list of intervals
def _build_range(interval):
	#ORS only allows queries of 10 isochrones at a time
	shape_max = 10
	#API allows a max of 2,500 queries/day so 2500/580 polling sites
	#gives us 4 queries per polling site
	daily_max = 4
	#initialize our list
	iso_intervals = [[] for x in range(daily_max)]
	daily_counter = 0
	#loop until the daily counter hits the maximum
	while daily_counter < daily_max:
		shape_counter = 0
		#loop until the shape counter hits the maximum 
		while shape_counter < shape_max:
			#build our intervals and append to the appropriate place in the list
			iso_intervals[daily_counter].append(
				(shape_counter + 1 + daily_counter * shape_max) * interval
				)
			shape_counter += 1
		daily_counter += 1
	#return the list
	return iso_intervals

if __name__ == '__main__':
	parser = argparse.ArgumentParser(description='Download isochrones from OpenRouteService')
	parser.add_argument('file',help='Enter the address file')
	parser.add_argument('year',help='Enter the year')
	#takes an optional argument to skip to the noted row
	parser.add_argument('-s','--skipto',default=1,type=int,nargs='?',help='Optional: Enter a starting ID')
	args = parser.parse_args()

	print('Starting up...')

	main(args.file, args.year, args.skipto-1)

	print('...done')
