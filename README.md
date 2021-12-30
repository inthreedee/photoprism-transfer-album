# Google Photos album to Photoprism Album
*A script to import albums from a Google Photos Takeout*

Photoprism does not yet support transferring albums from Google Photos.  Once a library 
has been fully transferred, this script will scrape the necessary data from a Google 
Takeout of an album and use it to generate a new Photoprism album without duplicating any 
files.

Note: You must import and fully index the photos in your Google Photos takeout before 
running this script! It depends heavily on the photos already being in Photoprism's database.
  
[upstream]: https://github.com/inthreedee/photoprism-transfer-album
[insight]: https://github.com/photoprism/photoprism/issues/869#issuecomment-779488150

## To use this script:

1. Download the desired albums, or your whole collection, via Google Takeout.
2. Upload your Takeout photos or the original photos to Photoprism.
3. (Optional) Add a config.ini, see below.
4. Run the script in the Takeout directory alongside the album and respond to any prompts.

Tip: Pipe the output to tee to watch it run and save the output to a file for easy grepping:
`./transfer-album.sh [options] | tee output.log`

## Options:
```
Usage: transfer-album.sh <options>
  -a, --import-all         Import all photo albums (default)
  -n, --album-name [name]  Specify a single album name to import
  -d, --takeout-dir [dir]  Specify an alternate Google Takeout directory
                           Defaults to the current working directory
  -s, --sidecar-dir [dir]  Specify the sidecar directory (name matching only)
  -m, --match [option]     Set the method used to match/identify photos
                           Valid options: hash/name - Default matching: hash
  -b, --batching [option]  Set to true/false to enable/disable batch submitting
                           to the API (default: true, hash mode only)
                           Instead, add photos one at a time as they are found
  -c, --config [file]      Specify an optional configuration file
  -h, --help               Display this help
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
  the files in Photoprism and Google Photos are identical. This method is faster.
- Use name matching if you've uploaded original photos from another source 
  and you just want to re-create your google Photos albums in Photoprism.

If `--batching` is not specified, it defaults to true for hash matching mode 
and false for name matching mode. 
Disabling batching will submit photos to the API one at a time as matches are found. 
Batching currently has no effect in name matching mode.

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

1. For each album, it creates a new Photoprism album with the title and description from
   the album's `metadata.json`.

*Then, in hash matching mode*

2. It scans all files in the album's directory, hashing any non-JSON files.
3. It looks up each file in the database by its hash using Photoprism's files API.
4. If it finds a match, it adds the photo's UID to the current album's list.
5. When all files are processed, or every time it has gathered 999 files, an API request 
   is sent to the server to add the gathered photos to the album.

*Or, in name matching mode*

2. It scans the json files in the Google Takeout directory, pulling out the title field.
3. It scans the yml files in the Photoprism sidecar directory, attempting to find a matching filename.
4. Once it finds a match, it pulls the photo's UID from the yml file.
5. An API request is sent to the server to add that UID to the album.
