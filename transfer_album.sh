#!/usr/bin/env bash

###########################################################################
# Google Album to Photoprism Album Transfer Script
#
# To use this script:
#
# 1. Download the desired album via Google Takeout.
# 2. If not working directly on the server, download the
#    photoprism sidecar directory.
# 3. Edit the variables below to match your paths and server configuration.
# 4. Run the script.
#
# Notes:
#
# - Only point this script to one google album directory at a time.
# - Libraries with more than a few thousand photos can take a while;
#   The more sidecar files that have to be scanned, the longer it will take.
# - Sidecar files should be stored on an ssd for performance reasons.
# - If an API becomes available to get a photo UID from its filename,
#   that would be a much more efficient method than scanning sidecars files.
############################################################################

googleTakeoutDir="/path/to/takeout/directory"
googleAlbumDir="$googleTakeoutDir/Google Album Name"
sidecarDir="/path/to/sidecar/directory"

# A new photoprism album will be created with the following name
newAlbumName="New Photoprism Album Name"

siteURL="https://photos.example.com"
sessionAPI="/api/v1/session"
albumAPI="/api/v1/albums"
# Note - Album photos API: /api/v1/albums/$albumUID/photos

apiUsername="admin"
apiPassword='password'

############################################################################

shopt -s globstar

# Create a new session
echo "Creating session..."
sessionID="$(curl --silent -X POST -H "Content-Type: application/json" -d "{\"username\": \"$apiUsername\", \"password\": \"$apiPassword\"}" "$siteURL$sessionAPI" 2>&1 | grep -Eo '"id":.*"' | awk -F '"' '{print $4}')"

# Clean up the session on script exit
trap 'echo "Deleting session..." & curl --silent -X DELETE -H "X-Session-ID: $sessionID" -H "Content-Type: application/json" "$siteURL$sessionAPI/$sessionID" >/dev/null' EXIT

# Create a new album
echo "Creating album $newAlbumName..."
albumUID="$(curl --silent -X POST -H "X-Session-ID: $sessionID" -H "Content-Type: application/json" -d "{\"Title\": \"$newAlbumName\"}" "$siteURL$albumAPI" 2>&1 | grep -Eo '"UID":.*"' | awk -F '"' '{print $4}')"

echo "Album UID: $albumUID"
albumPhotosAPI="$albumAPI/$albumUID/photos"

# Scan the google takeout dir for json files
echo "Searching jsons..."
count=1
for jsonFile in "$googleAlbumDir"/**/*.json; do
    # Get the photo title (filename) from the google json file
    googleFile="$(awk -F \" '/"title":/ {print $4}' "$jsonFile")"
    
    # Skip this file if it has no title
    if [ -z "$googleFile" ]; then
        continue
    fi
    
    echo "$count: Trying to match $googleFile..."

    # Find a matching file in the photoprism sidecar directory
    found=0
    for ymlFile in "$sidecarDir"/**/*.yml; do
        sidecarFile="$(basename "$ymlFile")"
        
        if [ "${sidecarFile%.*}" = "${googleFile%.*}" ]; then
            # We found a match
            echo "Match found: $sidecarFile"
            found=1

            # Get the photo's UID
            photoUID="$(awk '/UID:/ {print $2}' "$ymlFile")"

            # Send an API request to add the photo to the album
            echo "Adding photo $photoUID to album..."
            curl --silent -X POST -H "X-Session-ID: $sessionID" -H "Content-Type: application/json" -d "{\"photos\": [\"$photoUID\"]}" "$siteURL$albumPhotosAPI" >/dev/null
            
            # Stop processing sidecar files for this json
            break
        fi
    done
    
    if [ "$found" -eq 0 ]; then
        echo "WARNING: No match found for $googleFile!"
    fi
    
    count="$((count+1))"
done
