# Google Photos album to Photoprism Album
*A quick and dirty script to transfer a Google Photos album to a new Photoprism album*

Photoprism does not yet support transferring albums from Google Photos.  Once a library has been fully transferred, this script will scrape the necessary data from a Google Takeout of an album and use it to generate a new Photoprism album without duplicating any files.

## To use this script:

1. Download the desired album via Google Takeout.
2. If not working directly on the server, download the photoprism sidecar directory.
3. Edit the variables at the top of the script to match your paths and server configuration.
4. Run the script.

## Notes:

- Only point this script to one google album directory at a time.
- Libraries with more than a few thousand photos can take a while; the more sidecar files that have to be scanned, the longer it will take.
- Sidecar files should be stored on an ssd for performance reasons.
- If an API becomes available to get a photo UID from its filename, that would be a much more efficient method than scanning sidecars files.
