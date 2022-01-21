#!/usr/bin/env bash

###########################################################################
# Google Album to PhotoPrism Album Transfer Script
#
# To use this script:
#
# 1. Download the desired album via Google Takeout.
# 2. Upload your Takeout photos or the original photos to PhotoPrism.
# 3. (Optional) Add a config.ini in the directory you're running the
#    script, defining the variables API_USERNAME, API_PASSWORD, SITE_URL
#    This file should be bash-compatible, as it is simply sourced.
# 4. Run the script. It will prompt interactively for any needed info.
#
# There are two methods of matching/identifying photos: By hash or by name.
#  - Use hash matching if you uploaded photos from your Google Takeout and
#    the files PhotoPrism and Google Photos are identical. This is faster.
#  - Use name matching if you uploaded original photos from another source
#    and you just want to re-create your google Photos albums in PhotoPrism.
#
# Call the script with --help for more information.
#
# Please note: Large photo libraries can take a while to process
#
#
# made with <3
# Author: https://github.com/inthreedee
# Contributor: https://github.com/cincodenada
#
# License: GPLv3
############################################################################

sessionAPI="/api/v1/session"
albumAPI="/api/v1/albums"
fileAPI="/api/v1/files"
# Note - Album photos API: /api/v1/albums/$albumUID/photos

# Get the location of this script
runDir="$(realpath "$0" | xargs dirname)"

############################################################################

shopt -s globstar

# PhotoPrism API request
function api_call() {
    response="$(curl --silent -H "Content-Type: application/json" -H "X-Session-ID: $sessionID" "$@")"

    # Check the response
    if echo "$response" | grep '"error":' >/dev/null; then
        echo -e "API request failed! Response:\n$response" >&2
    fi
    
    # Return the response
    echo "$response"
}

# Get a specific field from a json file
# Expects two arguments, the field name followed by the json file
function get_json_field() {
    field="$1"
    filename="$2"

    # This assumes a nicely formatted JSON with one key:value pair per line and no escaped quotes
    # It prints the first match only, ignoring the rest
    awk -F '"' '/"'"$field"'":/ {print $4;exit;}' "$filename"
    # This is more robust but only works if you have jq installed
    #jq -r '.albumData["'"$field"'"]' "$filename"
}

# Create a json array of photo UIDs
# ["uid1","uid2","uid3",...]
function make_json_array() {
    first="$1"; shift
    list=""
    if [ -n "$first" ]; then
        list="\"$first\""
    fi
    while [ -n "$1" ]; do
        list="$list,\"$1\""
        shift
    done
    echo "[$list]"
}

# Submit the batch to the API
function add_album_files() {
    albumUID="$1"; shift

    # Send an API request to add the photo to the album
    jsonArray="$(make_json_array $@)"
    echo "Submitting photo batch to album id $albumUID"
    api_call -X POST -d "{\"photos\": $jsonArray}" "$siteURL$albumPhotosAPI" >/dev/null
}

# Process the matched photo
# Add it to a batch, pending submission to the API
# or make individual API calls
function process_batch() {
    if [ -z "$1" ]; then
        echo "Script error: process_batch() function expects an argument!"
        exit 1
    fi
    state="$1"
    
    if [ "$batching" = "true" ]; then
        # Using batches.
        
        if [ "$state" = "scanning" ]; then
            # We are still scanning for photos to add to the album

            # Print messaging
            if [ "$matching" = "hash" ]; then
                echo "Adding $albumFile with hash $fileSHA and uid $photoUID to batch..."
            elif [ "$matching" = "name" ]; then
                echo "Adding photo $photoUID to batch..."
            else
                echo "Script error: Unexpected matching condition in process_batch() function: \"$matching\"" >&2
                exit 1
            fi

            # Add UID to the batch and increment the counter
            batchIds="$batchIds $photoUID"
            batchCount="$(($batchCount+1))"

            # Submit the batch if we have sufficient photos
            if [ "$batchCount" -gt 999 ]; then
                add_album_files "$albumUID" "$batchIds"

                # Reset the batch
                batchIds=""
                batchCount=1
            fi
        elif [ "$state" = "done" ]; then
            # Done scanning for potential matches. Submit the remaining batch to the API
            if [ "$batchCount" -gt 1 ]; then
                add_album_files "$albumUID" "$batchIds"
                batchIds=""
            fi
        else
            echo "Script error: Unexpected argument in process_batch() function: \"$state\"" >&2
            exit 1
        fi
    else
        # Not using batches. Just add the photo

        # Print messaging
        if [ "$matching" = "hash" ]; then
            echo "Adding $albumFile with hash $fileSHA and id $photoUID to album"
        elif [ "$matching" = "name" ]; then
            echo "Adding photo $photoUID to album"
        else
            echo "Script error: Unexpected matching condition in process_batch() function: \"$matching\"" >&2
            exit 1
        fi

        # Submit the photo to the API
        api_call -X POST -d "{\"photos\": [\"$photoUID\"]}" "$siteURL$albumPhotosAPI" >/dev/null

    fi
}

# Import a Google Takeout album
function import_album() {
    albumDir="$1"
    metadataFile="$albumDir/$metadataFilename"

    if [ ! -f "$metadataFile" ]; then
        echo -e "\nSkipping folder \"$albumDir\"; $metadataFilename not found."
        return
    fi

    # Parse JSON with awk, what could go wrong?
    albumTitle="$(get_json_field title "$metadataFile")"
    albumDescription="$(get_json_field description "$metadataFile")"

    # Filter out various autogenerated or bad albums unless the user specified the name
    if [ -z "$specifiedAlbum" ]; then
        # Albums without titles
        if [ -z "$albumTitle" ]; then
            echo -e "\nSkipping folder \"$albumDir\", no album title found!"
            return
        fi

        # Autogenerated auto-upload album
        if [[ "$albumDescription" == "Album for automatically uploaded content from cameras and mobile devices" ]]; then
            echo -e "\nSkipping album $albumTitle, seems to be an autogenerated date album"
            return
        fi

        # Autogenerated date album
        if [[ "$albumTitle" == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]* ]]; then
            echo -e "\nSkipping folder \"$albumDir\", looks like a date!"
            return
        fi

        # Autogenerated hangout album
        if [[ "$albumTitle" == "Hangout:"* ]]; then
            echo -e "\nSkipping album $albumTitle, seems to be an autogenerated Hangouts album"
            return
        fi
    elif [ -z "$albumTitle" ]; then
        # The metadata.json lacks an album title, use the user-specified folder name
        echo -e "\nNo title metadata found for \"$albumDir\", using \"$specifiedAlbum\""
        albumTitle="$specifiedAlbum"
    fi

    # Create a new album
    echo -e "\nCreating album \"$albumTitle\"..."
    albumUID="$(api_call -X POST \
        -d "{\"Title\": \"$albumTitle\", \"Description\": \"$albumDescription\"}" \
        "$siteURL$albumAPI" \
        | grep -Eo '"UID":.*"' \
        | awk -F '"' '{print $4}')"

    echo "Album UID: $albumUID"
    albumPhotosAPI="$albumAPI/$albumUID/photos"

    # Scan for photos
    photoCount=1
    batchCount=1
    if [ "$matching" = "hash" ]; then
        # Photos are looked up via their SHA-1 hashes using the /files API
        echo "Searching for photos..."
        # Scan the album directory for photos
        for albumFile in "$albumDir"/**/*.*; do
            # Don't try to add directories
            if [ -d "$albumFile" ]; then
                continue
            fi
            # Don't try to add metadata files
            if [[ "$albumFile" == *.json ]]; then
                continue
            fi

            echo "$photoCount: Trying to match $(basename "$albumFile")..."
            
            fileSHA="$(sha1sum "$albumFile" | awk '{print $1}')"
            photoUID="$(api_call -X GET "$siteURL$fileAPI/$fileSHA" | grep -Eo '"PhotoUID":.*"' | awk -F '"' '{print $4}')"

            if [ -z "$photoUID" ]; then
                # No match found
                echo "WARN: Couldn't find file $albumFile with hash $fileSHA in database, skipping!"
            else
                # Match found, process the photo
                process_batch scanning
            fi

            # Increment the attempted match counter
            photoCount="$(($photoCount+1))"
        done

        # Process the remaining batch
        if [ "$batching" = "true" ]; then
            echo "Search complete."
            process_batch done
        fi
    elif [ "$matching" = "name" ]; then
        # We're matching photos by name
        # Scan the google takeout dir for json files
        echo "Searching jsons..."
        for jsonFile in "$albumDir"/**/*.json; do
            # Don't try to add metadata files
            if [ "$(basename "$jsonFile")" = "$metadataFilename" ]; then
                continue
            fi
            # Get the photo title (filename) from the google json file
            googleFile="$(awk -F \" '/"title":/ {print $4}' "$jsonFile")"
            
            # Skip this file if it has no title
            if [ -z "$googleFile" ]; then
                continue
            fi
            
            echo "$photoCount: Trying to match $googleFile..."

            # Find a matching file in the PhotoPrism sidecar directory
            found=0
            for ymlFile in "$sidecarDirectory"/**/*.yml; do
                sidecarFile="$(basename "$ymlFile")"
                
                if [ "${sidecarFile%.*}" = "${googleFile%.*}" ]; then
                    # We found a match
                    echo "Match found: $sidecarFile"
                    found=1

                    # Get the photo's UID
                    photoUID="$(awk '/UID:/ {print $2}' "$ymlFile")"

                    # Process the matched photo
                    process_batch scanning

                    # Stop processing sidecar files for this json
                    break
                fi
            done
            
            if [ "$found" -eq 0 ]; then
                echo "WARN: No match found for $googleFile!"
            fi

            # Increment the attempted match counter
            photoCount="$((photoCount+1))"
        done

        # Process the remaining batch
        if [ "$batching" = "true" ]; then
            echo "Search complete."
            process_batch done
        fi
    else
        echo "Script error: Unexpected matching condition in import_album() function: \"$matching\"" >&2
        exit 1
    fi
}

############################################################################
# MAIN
############################################################################

# Process command line arguments
if [ "$#" -gt 0 ]; then
    while [ "$#" -gt 0 ]
    do
        case "$1" in
            --help | -h )
                printf "This script imports albums from a downloaded Google Takeout.

By default, it will import all albums that aren't auto-generated
(ie, hangouts albums, albums by year, or albums by date)

Use --album-name to specify any single album to upload.
This will also bypass the auto-generated album checks.

There are two methods of matching/identifying photos: By hash or by name.
- Use hash matching if you've uploaded photos from your Google Takeout and
  the files in PhotoPrism and Google Photos are identical. This is faster.
- Use name matching if you've uploaded original photos from another source
  and you just want to re-create your google Photos albums in PhotoPrism.
See --match below.

By default, matched photos are batched for bulk submission to the API.
If this causes problems, see --batching below to disable it.

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
"
                exit 0
                ;;
            --import-all | -a )
                importAll="true"
                
                # Shift to the next argument
                shift
                ;;
            --album-name | -n )
                if [ "$importAll" = "true" ]; then
                    echo "Cannot specify both -a and -n" >&2
                    exit 1
                elif [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 \"Album Name\"" >&2
                    exit 1
                elif [ -n "$specifiedAlbum" ]; then
                    echo "Only one album can be specified at a time. Use -a to import all albums" >&2
                    exit 1
                fi
                specifiedAlbum="$2"

                # Shift to the next argument
                shift 2
                ;;
            --takeout-dir | -d )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 /path/to/Takeout/Google Photos" >&2
                    exit 1
                elif [ ! -d "$2" ]; then
                    echo "Invalid directory: $2" >&2
                    exit 1
                else
                    importDirectory="$2"

                    # Shift to the next argument
                    shift 2
                fi
                ;;
            --sidecar-dir | -s )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 /path/to/sidecar/directory" >&2
                    exit 1
                elif [ ! -d "$2" ]; then
                    echo "Invalid directory: $2" >&2
                    exit 1
                else
                    sidecarDirectory="$2"

                    # Shift to the next argument
                    shift 2
                fi
                ;;
            --metadata-file | -j )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 metadata.json" >&2
                    exit 1
                else
                    # set the metadata filename
                    metadataFilename="$(basename "$2" .json).json"
                    echo "Using user-specified metadata file: $metadataFilename"

                    # Shift to the next agument
                    shift 2
                fi
                ;;
            --match | -m )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 [hash/name]" >&2
                    exit 1
                elif [ "$2" != "hash" ] && [ "$2" != "name" ]; then
                    echo "Usage: transfer-album $1 [hash/name]" >&2
                    exit 1
                else
                    matching="$2"
                    
                    # Shift to the next argument
                    shift 2
                fi
                ;;
            --batching | -b )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 [true/false]" >&2
                    exit 1
                elif [ "$2" != "true" ] && [ "$2" != "false" ]; then
                    echo "Usage: transfer-album $1 [true/false]" >&2
                    exit 1
                else
                    batching="$2"
                    
                    # Shift to the next argument
                    shift 2
                fi
                ;;
            --config | -c )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 /path/to/config.conf" >&2
                    exit 1
                elif [ ! -f "$2" ]; then
                    echo "Config file not found: $2" >&2
                    exit 1
                else
                    # Source the file and set variables
                    . "$2"
                    apiUsername="$API_USERNAME"
                    apiPassword="$API_PASSWORD"
                    siteURL="$SITE_URL"

                    # Shift to the next argument
                    shift 2
                fi
                ;;
            * )
                echo -e "Invalid option '$1'\nUse -h for help" >&2
                exit 0
                ;;
        esac
    done
fi

# Initialize variables
if [ -z "$batching" ]; then
    batching="true"
fi
if [ -z "$matching" ]; then
    matching="hash"
fi
if [ -z "$metadataFilename" ]; then
    metadataFilename="metadata.json"
fi

# Prompt user for input if necessary
if [ -z "$siteURL" ]; then
    read -rp 'Site URL? ' siteURL
fi
if [ -z "$apiUsername" ]; then
    read -rp 'Username? ' apiUsername
fi
if [ -z "$apiPassword" ]; then
    read -srp 'Password? ' apiPassword
    echo ""
fi

# Set the Google Takeout directory if needed
if [ -z "$importDirectory" ]; then
    echo "Import directory not set, using current working directory"
    importDirectory="$(pwd)"
fi

# Get the sidecar directory if needed
if [ "$matching" = "name" ] && [ -z "$sidecarDirectory" ]; then
    while read -rp 'Path to PhotoPrism sidecar directory? ' sidecarDirectory; do
        if [ ! -d "$sidecarDirectory" ]; then
            echo "That directory is invalid or does not exist. Please try again."
        else
            break
        fi
    done
fi

# Create a new session
echo "Creating PhotoPrism session..."

# Call the session API
session="$(curl --silent -X POST -H "Content-Type: application/json" -d "{\"username\": \"$apiUsername\", \"password\": \"$apiPassword\"}" "$siteURL$sessionAPI")"

# Check the login credentials
if echo "$session" | grep "Invalid credentials" >/dev/null; then
    echo "Invalid login credentials, bailing!" >&2
    exit 1
fi

# Get the session ID
sessionID="$(echo "$session" | grep -Eo '"id":.*"' | awk -F '"' '{print $4}')"

if [ -z "$sessionID" ]; then
    echo "Failed to get session id, bailing!" >&2
    exit 1
fi

echo -e "Session created.\n"

# Clean up the session on script exit
trap 'echo -e "\nDeleting PhotoPrism session..." && api_call -X DELETE "$siteURL$sessionAPI/$sessionID" >/dev/null && echo "Done."' EXIT

# Run the imports
if [ -n "$specifiedAlbum" ]; then
    # Importing a single specified album
    if [ "$specifiedAlbum" = "$(pwd | xargs basename)" ]; then
        # We're already working in the right directory
        echo "Importing album \"$specifiedAlbum\"..."
        import_album "$importDirectory"
    else
        # Try to find the right directory
        foundAlbum="$(find "$importDirectory" -maxdepth 1 -type d -name "$specifiedAlbum")"
        if [ -z "$foundAlbum" ]; then
            echo "Unable to locate album \"$specifiedAlbum\" in \"$importDirectory\""
            exit 0
        else
            echo "Importing album \"$specifiedAlbum\"..."
            import_album "$foundAlbum"
        fi
    fi
elif [ -f "$metadataFilename" ]; then
    # If we are being run from an album directory, just import this album
    echo "\"$importDirectory\" appears to be an album; importing in single album mode..."
    import_album "$importDirectory"
else
    # Else import all albums found in this directory
    echo "Importing all albums in \"$importDirectory\"..."
    find "$importDirectory" -maxdepth 1 -type d | \
    while read album; do
        import_album "$album"
    done
fi
