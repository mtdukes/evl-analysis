'''
A simple script to load in isochrone shapes
to our PostgreSQL database using ogr2ogr and
its pygdaltools wrapper

Usage:
python loadIsochrones.py data/isochrones_lookup.csv

by @mtdukes
'''
#load in the libraries we need
import gdaltools, argparse, csv

#specificy the ogr2ogr basepath on this machine
gdaltools.Wrapper.BASEPATH = "//usr/local/bin/"

#this is the query we want to mimic
##ogr2ogr -f "PostgreSQL" PG:"dbname=evl user=mtdukes" "source_data.json" -nln destination_table -append
def main(csv_file):
	#open the csv file
	with open(csv_file,'r') as csv_input:
		#establish the data as a header-accessible dictionary
		reader = csv.DictReader(csv_input)
		#for each row in the data, read in a filename,
		#grab the file and append it to a table in the evl
		#postgres database for later use
		for row in reader:
			print(row['filename'])
			#initialize ogr2ogr
			ogr = gdaltools.ogr2ogr()
			ogr.set_encoding("UTF-8")
			#establish connection settings
			conn = gdaltools.PgConnectionString(
				host='localhost',
				port=5432,
				dbname='evl',
				user='mtdukes'
			)
			#set up the file input from the isochrones directory
			ogr.set_input('data/isochrones/' + row['filename'])
			#specify the table and postgres format for PostGIS
			ogr.set_output(conn, table_name='isochrones')
			#make sure we append the data
			ogr.set_output_mode(layer_mode=ogr.MODE_LAYER_APPEND)
			#run ogr2ogr
			ogr.execute()

if __name__ == '__main__':
	parser = argparse.ArgumentParser(description='Load isochrones from OpenRouteService into PostgreSQL')
	parser.add_argument('file',help='Enter the address file')
	args = parser.parse_args()

	print('Starting up...')

	main(args.file)

	print('...done')