# Google Photos album to PhotoPrism Album
*A script to create albums from a Google Photos Takeout in PhotoPrism*

PhotoPrism does not yet support transferring albums from Google Photos.  Once a library 
has been fully transferred, this script will scrape the necessary data from a Google 
Takeout of an album and then, using the PhotoPrism API, create a new PhotoPrism 
album and populate it with the matching photos.

Note: You must import or index the photos from your Google Photos Takeout before 
running this script!  This script does not upload any photos for you.
  
[upstream]: https://github.com/inthreedee/photoprism-transfer-album
[insight]: https://github.com/photoprism/photoprism/issues/869#issuecomment-779488150

## To use this script:

1. Download the desired albums, or your whole collection, via Google Takeout.
2. If your Google language settings are set to a language other than English, look up the filename 
   in your Takeout and provide the `--metadata-file` argument to match your language. 
   ie. `Metadaten.json` for German.
4. Add your Takeout photos or the original photos to PhotoPrism's import or originals directory.
5. Import or index your files.
6. Run the script in the Takeout directory alongside the albums and respond to any prompts.

*Note:* If photos were uploaded from an original source in step 2 (not Google Takeout), 
use `--match name` as described below. PhotoPrism's sidecar yml files will be required.

## Tip:
Pipe the output to tee to watch it run and save the output to a file:
`./transfer-album.sh [options] 2>&1 | tee output.log`

Then, use grep to list the photos that couldn't be matched:
`grep WARN output.log > failures.log`


## A note on parsing json:
This script uses standard Linux tools to parse json files. It makes several assumptions about the formatting of those json files and may break if Google changes the formatting.

For more robust and reliable json parsing, the get_json_field() function includes an alternate option using the external tool jq. To use jq, install it from your package manager and then edit this script as explained in the get_json_field() function comments.


## Options:
```
Usage: transfer-album.sh <options>
  -a, --import-all            Import all photo albums (default)
  -n, --album-name [name]     Specify a single album name to import
  -d, --takeout-dir [dir]     Specify an alternate Google Takeout directory
                              Defaults to the current working directory
  -s, --sidecar-dir [dir]     Specify the sidecar directory (name matching only)
  -j, --metadata-file [name]  Specify the name of metadata files. Set for
                              non-English languages. Default: metadata.json
  -m, --match [option]        Set the method used to match/identify photos
                              Valid options: hash/name - Default matching: hash
  -b, --batching [option]     Set to true/false to configure batch submitting
                              to the API. When false, photos are submitted
                              to the API one at a time. (default: true)
  -c, --config [file]         Specify an optional configuration file
  -h, --help                  Display this help
```

If `--album-name` is not specified, all albums will be imported.
 - Google Photos automatically generates some albums (ie, hangouts albums, albums by year, or albums by date). 
   These will be skipped. Force import of one of these albums by specifying it with `--album-name`.

If `--takeout-dir` is not specified, it will use the current working directory.
- In this case, the script can be run either in a single album directory, or in the base Google Photos 
  directory. If it finds a `metadata.json` in the given directory it will import it as a 
  single album, otherwise it will try to import each subdirectory as an album.

If `--match` is not specified, hash mode will be used.
- Use hash matching if you've uploaded photos from your Google Takeout and 
  the files in PhotoPrism and Google Photos are identical. This method is significantly faster.
- Use name matching if you've uploaded original photos from another source 
  and you just want to re-create your google Photos albums in PhotoPrism.
  PhotoPrism's sidecar directory, or a copy containing the yml files, must be available to the script.

If `--batching` is not specified, it defaults to true.
Disabling batching will submit photos to the API one at a time as matches are found.

## Optional config file:
The script will prompt interactively for all the information it needs. 
An optional config file can be specified with `--config` to define 
the site URL, username, and password.

An example `config.conf`:

```
API_USERNAME=admin
API_PASSWORD=your really good password
SITE_URL=https://photos.example.com
```

## What it does:

1. For each album, it creates a new PhotoPrism album with the title and description from
   the album's `metadata.json`.

*Then, in hash matching mode*

2. It scans all files in the album's directory, hashing any non-JSON files.
3. It looks up each file in the database by its hash using PhotoPrism's files API.
4. If it finds a match, it adds the photo's UID to the album's batching list.
5. When all files are processed or every time it has gathered 999 files, an API request 
   is sent to the server to add the gathered photos to the album.

*Or, in name matching mode*

2. It scans the json files in the Google Takeout directory, pulling out the title field.
3. It scans the yml files in the PhotoPrism sidecar directory, attempting to find a matching filename.
4. If it finds a match, it pulls the photo's UID from the yml file and adds it to the album's batching list.
5. When all files are processed or every time it has gathered 999 files, an API request 
   is sent to the server to add the gathered photos to the album.
