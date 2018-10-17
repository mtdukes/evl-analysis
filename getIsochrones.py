'''
Simple script for getting isochrone shapes for designated
county early voting sites for the given year. Saves each 
site's isochrone into a geojson feature collection
in a separate file.

API Docs
https://openrouteservice.org/documentation/#/reference/isochrones/isochrones/isochrones-service

Except there's apparently a python wrapper (oh well):
https://github.com/GIScience/openrouteservice-py

Usage
python getIsochrones.py data/early_voting2018.csv 2018

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
#our function will loop through twice for each site to get features 1-20
#this gets around the API limitation
#NOTE: This does not return what we want it to return, so we need to revisit
iso_range_list = [20,9]
interval = 2
units = 'mi'
location_type = 'start'

def main(csv_file, year):
	#get secret keys
	_get_secrets()
	#build file name
	#open input csv
	print('Opening site CSV...')
	with open(csv_file,'r') as csv_input:
		#use dictreader so we can call by column name
		reader = csv.DictReader(csv_input)
		#for each line in csv
		for row in reader:
			#if line is a county we are analyzing construct the url
			if row['is_changed'] == '1':
				#get the coords fromt the spreadsheet
				lnglat = str(row['lng']) + ',' + str(row['lat'])
				#contstruct the file name from the spreadsheet details
				json_output = (row['county'].lower() + '_' + 
					#make sure our site id is stored with leading zeros
					'%03d' % (int(row['site_id']),) +
					'_' + str(year) + '.json')
				print('Querying ' + row['site'] + ' data...')
				#loop through our range list so we make two passes
				for iso_range in iso_range_list:
					#query the openrouteservice api
					site = requests.get(base_url, params={
						'api_key': secret_keys[0],
						'locations': lnglat,
						'profile': profile,
						'range_type': range_type,
						'range': str(iso_range),
						'interval': str(interval),
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
							isochrone['properties']['mile_value'] = int(isochrone['properties']['value'] / 1609.34)
							if iso_range != 20:
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
					if iso_range == 20:
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

if __name__ == '__main__':
	parser = argparse.ArgumentParser(description='Download isochrones from OpenRouteService')
	parser.add_argument('file',help='Enter the address file')
	parser.add_argument('year',help='Enter the year')
	args = parser.parse_args()

	print('Starting up...')

	main(args.file, args.year)

	print('...done')
