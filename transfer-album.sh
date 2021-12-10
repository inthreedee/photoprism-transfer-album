#!/usr/bin/env bash

###########################################################################
# Google Album to Photoprism Album Transfer Script
#
# To use this script:
#
# 1. Download the desired album via Google Takeout.
# 2. (Optional) Add a config.ini in the directory you're running the
#    script with the variables below (API_USERNAME, API_PASSWORD, SITE_URL)
#    defined. This file should be bash-compatible, as it is simply sourced
# 3. Run the script. It will prompt interactively for any missing config.
#
# Notes:
#
# - Only point this script to one google album directory at a time.
# - Libraries with more than a few thousand photos can take a while
# - Photos are looked up via their SHA-1 hashes using the /files API
############################################################################

sessionAPI="/api/v1/session"
albumAPI="/api/v1/albums"
fileAPI="/api/v1/files"
# Note - Album photos API: /api/v1/albums/$albumUID/photos

############################################################################

shopt -s globstar

# Handle executing commands
function logexec() {
    if [ -z "$commandFile" ] && [ -z "$verbosity" ]; then
        # Normal operation
        "$@"
    elif [ -z "$commandFile" ] && [ "$verbosity" -eq 1 ]; then
        # Verbose mode
        printf 'Exec: %q\n' "$@"
        "$@"
    elif [ ! -z "$commandFile" ]; then
        # Dry-run mode
        printf "%q\n" "$@" | tee -a "$commandFile"
    else
        # Oopsie mode
        echo "Script error: Unexpected condition in logexec() function" >&2
        exit 1
    fi
}

function api_call() {
    logexec curl --silent -H "Content-Type: application/json" -H "X-Session-ID: $sessionID" "$@"
}

# Get a specific field from a json file
# Expects two arguments, the field name followed by the json file
function get_json_field() {
    field="$1"
    filename="$2"

    # This assumes a nicely formatted JSON with one key:value pair per line and no escaped quotes
    awk -F '"' '/"'"$field"'":/ { print $4 }' "$filename"
    # This is more robust but only works if you have jq installed
    #jq -r '.albumData["'"$field"'"]' "$filename"
}

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

function add_album_files() {
    albumUID="$1"; shift
    albumPhotosAPI="$albumAPI/$albumUID/photos"

    # Send an API request to add the photo to the album
    jsonArray="$(make_json_array "$@")"
    echo "Submitting batch to album id $albumUID"
    api_call -X POST -d "{\"photos\": $jsonArray}" "$siteURL$albumPhotosAPI" >/dev/null
}

function import_album() {
    albumDir="$1"
    metadataFile="$albumDir/metadata.json"

    if [ ! -f "$metadataFile" ]; then
        echo "Skipping folder \"$albumDir\"; no metadata.json!"
        return
    fi

    # Parse JSON with awk, what could go wrong?
    albumTitle="$(get_json_field title "$metadataFile")"
    albumDescription="$(get_json_field description "$metadataFile")"

    # Filter out various autogenerated or bad albums. Feel free to comment out
    # any of the following if blocks if you want to import that type of album

    # Albums without titles
    if [ -z "$albumTitle" ]; then
        echo "Skipping folder \"$albumDir\", no album title found!"
        return
    fi

    # Autogenerated auto-upload album
    if [[ "$albumDescription" == "Album for automatically uploaded content from cameras and mobile devices" ]]; then
        echo "Skipping album $albumTitle, seems to be an autogenerated date album"
        return
    fi

    # Autogenerated date album
    if [[ "$albumTitle" == [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]* ]]; then
        echo "Skipping folder \"$albumDir\", looks like a date!"
        return
    fi

    # Autogenerated hangout album
    if [[ "$albumTitle" == "Hangout:"* ]]; then
        echo "Skipping album $albumTitle, seems to be an autogenerated Hangouts album"
        return
    fi

    # Create a new album
    echo "Creating album $albumTitle..."
    albumUID="$(api_call -X POST \
        -d "{\"Title\": \"$albumTitle\", \"Description\": \"$albumDescription\"}" \
        "$siteURL$albumAPI" 2>&1 \
        | grep -Eo '"UID":.*"' \
        | awk -F '"' '{print $4}')"
    echo "Album UID: $albumUID"

    # Scan the google takeout dir for json files
    echo "Adding photos..."
    count=1
    batchFiles=""
    batchCount=1
    for albumFile in "$albumDir"/**/*.*; do
        # Don't try to add metadata files or directories
        [ -f "$albumFile" ] || continue
        [[ "$albumFile" == *.json ]] && continue
	
        fileSHA="$(sha1sum "$albumFile" | awk '{print $1}')"
        photoUID="$(api_call -X GET "$siteURL$fileAPI/$fileSHA" | grep -Eo '"PhotoUID":.*"' | awk -F '"' '{print $4}')"
	
        if [ -z "$photoUID" ]; then
            echo "WARN: Couldn't find file $albumFile with hash $fileSHA in database, skipping!"
            continue
        fi

        echo "$count: Adding $albumFile with hash $fileSHA and id $photoUID to album..."
        batchIds="$batchIds $photoUID"
        count="$(($count+1))"
        batchCount="$(($batchCount+1))"

        # If for some reason the batching doesn't seem to be working, you can
        # just add the files one a time by commenting out the api_call line in
        # the add_album_files function above and uncommenting this next line:
        # api_call -X POST -d "{\"photos\": \[\"$photoUID\"\]}" "$siteURL$albumPhotosAPI" >/dev/null

        if [ $batchCount -gt 999 ]; then
            add_album_files $albumUID $batchIds
            batchIds=""
            batchCount=1
        fi
    done

    if [ -n $batchFiles ]; then
        add_album_files $albumUID $batchIds
        batchIds=""
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
                printf "Import Google Photos albums into Photoprism
Usage: transfer-album.sh <options>
  -a, --import-all         Import all photo albums (default)
  -n, --album-name [name]  Specify a single album name to import
  -d, --takeout-dir [dir]  Specify an alternate Google Takeout directory
                           Defaults to the current working directory
  -c, --config [file]      Specify a configuration file
  -r, --dry-run            Dump commands to a file instead of executing them
  -v, --verbose            Print each command as it is executed
  -h, --help               Display this help
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
                elif [ ! -z "$importAlbum" ]; then
                    echo "Only one album can be specified at a time. Use -a to import all albums" >&2
                    exit 1
                fi
                importAlbum="$2"

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
            --dry-run | -r )
                if [ -z "$2" ]; then
                    echo "Usage: transfer-album $1 /path/to/file.txt" >&2
                    exit 1
                else
                    commandFile="$2"
                    # Create an empty file and directory structure
                    install -D -m 644 /dev/null "$commandFile"

                    # Shift to the next argument
                    shift 2
                fi
                ;;
            --verbose | -v )
                verbosity=1
                shift
                ;;
            * )
                echo "Invalid option '$1'" >&2
                exit 0
                ;;
        esac
    done
fi

# Set the Google Takeout directory if needed
if [ -z "$importDirectory" ]; then
    echo "Import directory not set, using current working directory"
    importDirectory="$(pwd)"
fi

# Prompt user for input if necessary
if [ -z "$siteURL" ]; then
    read -p 'Site URL? ' siteURL
fi
if [ -z "$apiUsername" ]; then
    read -p 'Username? ' apiUsername
fi
if [ -z "$apiPassword" ]; then
    read -sp 'Password? ' apiPassword
    echo
fi

# Create a new session
echo "Creating session..."
sessionID="$(logexec curl --silent -X POST -H "Content-Type: application/json" -d "{\"username\": \"$apiUsername\", \"password\": \"$apiPassword\"}" "$siteURL$sessionAPI" | grep -Eo '"id":.*"' | awk -F '"' '{print $4}')"

if [ -z "$sessionID" ]; then
    echo "Failed to get session id, bailing!" >&2
    exit 1
fi

# Clean up the session on script exit
trap 'echo "Deleting session..." && api_call -X DELETE "$siteURL$sessionAPI/$sessionID" >/dev/null' EXIT

if [ ! -z "$albumName" ]; then
    # Importing a single specified album
    if [ "$albumName" = "$(pwd | xargs basename)" ]; then
        # We're already working in the right directory
        echo "Importing album \"$albumName\""
        import_album "$importDirectory"
    else
        # Try to find the right directory
        foundAlbum="$(find "$importDirectory" -maxdepth 1 -type d -name "$albumName")"
        if [ -z "$foundAlbum" ]; then
            echo "Unable to locate album \"$albumName\" in \"$importDirectory\""
            exit 0
        else
            echo "Importing album \"$albumName\""
            import_album "$foundAlbum"
        fi
    fi
elif [ -f "metadata.json" ]; then
    # If we are being run from an album directory, just import this album
    echo "\"$importDirectory\" appears to be an album; importing in single album mode"
    import_album "$importDirectory"
else
    # Else import all albums found in this directory
    echo "Importing all albums in \"$importDirectory\""
    find "$importDirectory" -maxdepth 1 -type d | \
    while read album; do
        import_album "$album"
    done
fi
