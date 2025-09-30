#!/bin/bash

set -eu

CONFIG_VERBOSE=0
CONFIG_EXTRACT=1
CONFIG_BORG_EXPORTER_RC=/etc/borg_exporter.rc

cleanup() {
    if [ ! -z ${TMP_FILE+x} ] && [ -f "$TMP_FILE" ]; then
      rm -f "$TMP_FILE"
    fi
}

trap cleanup EXIT

function log {
	echo "$@"
}

function verbose {
	[ "$CONFIG_VERBOSE" == "1" ] && log "$@"
}

function error {
  log "Error: " "$@" >&2
  exit 1
}

function usage {
    echo "Usage: $0 [-v|--verbose] [-h|--help]"
    echo "  -v, --verbose    Enable verbose mode"
    echo "  -h, --help       Display this help message"
    echo "  -x, --no-extract Disable archive extraction, recommended for large/remote repositories"
    echo "  -c, --config     Specify a configuration file (default: /etc/borg_exporter.rc)"
    echo "  -u, --user       Specify a user to to set as owner of the node exporter file"
    echo "  -g, --group      Specify a group to to set as owner of the node exporter file"
    exit 0
}

function calc_bytes {
  NUM=$1
  UNIT=$2

  case "$UNIT" in
    kB)
      echo "$NUM" | awk '{ print $1 * 1024 }'
      ;;
    MB)
      echo "$NUM" | awk '{ print $1 * 1024 * 1024 }'
      ;;
    GB)
      echo "$NUM" | awk '{ print $1 * 1024 * 1024 * 1024 }'
      ;;
    TB)
      echo "$NUM" | awk '{ print $1 * 1024 * 1024 * 1024 * 1024 }'
      ;;
  esac
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -v|--verbose) CONFIG_VERBOSE=1 ;;
        -h|--help) usage ;;
        -x|--no-extract) CONFIG_EXTRACT=0 ;;
        -c|--config) CONFIG_BORG_EXPORTER_RC="$2"; shift ;;
        -u|--user) CONFIG_USER="$2"; shift ;;
        -g|--group) CONFIG_GROUP="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if ! command -v borg > /dev/null 2>&1; then
  error "Unable to find borg executable in PATH, is borg installed?"
  exit 1
fi

if ! command -v dateutils.ddiff > /dev/null 2>&1; then
  error "Unable to find dateutils.ddiff executable in PATH, are dateutils installed?"
  exit 1
fi

[ -e "$CONFIG_BORG_EXPORTER_RC" ] || {
  error "Configuration file $CONFIG_BORG_EXPORTER_RC not found"
  exit 1
}

source "$CONFIG_BORG_EXPORTER_RC"

[ -z "$REPOSITORY" ] && {
  error "REPOSITORY is not set in $CONFIG_BORG_EXPORTER_RC"
  exit 1
}

[ -z "$COLLECTOR_DIR" ] && {
  error "COLLECTOR_DIR not set in $CONFIG_BORG_EXPORTER_RC"
  exit 1
}

PROM_FILE=$COLLECTOR_DIR/borg.prom
TMP_FILE=$(mktemp)
HOSTNAME=$(hostname)

if [ -e "$COLLECTOR_DIR" ]; then
  if [ ! -d "$COLLECTOR_DIR" ]; then
    error "$COLLECTOR_DIR is not a directory, aborting"
    exit 1
  fi
else
  mkdir -p "$COLLECTOR_DIR"
fi

verbose "PROM_FILE: $PROM_FILE"
verbose "TMP_FILE: $TMP_FILE"
verbose "HOSTNAME: $HOSTNAME"

verbose "Retrieving repository list..."
ARCHIVES=$(borg list "$REPOSITORY")
COUNTER=0

COUNTER=$(echo "$ARCHIVES" | wc -l)

verbose "Retrieving last archive..."
LAST_ARCHIVE=$(borg list --last 1 "$REPOSITORY" | sort -nr | head -n 1)
LAST_ARCHIVE_NAME=$(echo $LAST_ARCHIVE | awk '{print $1}')
LAST_ARCHIVE_DATE=$(echo $LAST_ARCHIVE | awk '{print $3" "$4}')
LAST_ARCHIVE_TIMESTAMP=$(date -d "$LAST_ARCHIVE_DATE" +"%s")
CURRENT_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
NB_HOUR_FROM_LAST_BCK=$(dateutils.ddiff "$LAST_ARCHIVE_DATE" "$CURRENT_DATE" -f '%H')

if [ "$CONFIG_EXTRACT" == "1" ]; then
  verbose "Extracting archive..."
  BORG_EXTRACT_EXIT_CODE=$(borg extract --dry-run "$REPOSITORY::$LAST_ARCHIVE_NAME" > /dev/null 2>&1; echo $?)
else
  verbose "Skipping archive extraction"
  BORG_EXTRACT_EXIT_CODE=0
fi

verbose "Retrieving repository info..."
BORG_INFO=$(borg info "$REPOSITORY::$LAST_ARCHIVE_NAME")

verbose "Calculating sizes..."
# byte size
LAST_SIZE=$(calc_bytes $(echo "$BORG_INFO" | grep "This archive" | awk '{print $3}') $(echo "$BORG_INFO" | grep "This archive" | awk '{print $4}'))
LAST_SIZE_COMPRESSED=$(calc_bytes $(echo "$BORG_INFO" | grep "This archive" | awk '{print $5}') $(echo "$BORG_INFO" | grep "This archive" | awk '{print $6}'))
LAST_SIZE_DEDUP=$(calc_bytes $(echo "$BORG_INFO" | grep "This archive" | awk '{print $7}') $(echo "$BORG_INFO" | grep "This archive" | awk '{print $8}'))
TOTAL_SIZE=$(calc_bytes $(echo "$BORG_INFO" | grep "All archives" | awk '{print $3}') $(echo "$BORG_INFO" | grep "All archives" | awk '{print $4}'))
TOTAL_SIZE_COMPRESSED=$(calc_bytes $(echo "$BORG_INFO" | grep "All archives" | awk '{print $5}') $(echo "$BORG_INFO" | grep "All archives" | awk '{print $6}'))
TOTAL_SIZE_DEDUP=$(calc_bytes $(echo "$BORG_INFO" | grep "All archives" | awk '{print $7}') $(echo "$BORG_INFO" | grep "All archives" | awk '{print $8}'))

_metadata="host=\"${HOSTNAME}\",instance=\"${BORGEXPORTER_INSTANCE}\""

verbose "Writing data..."
{
  echo "borg_last_archive_timestamp{${_metadata}} $LAST_ARCHIVE_TIMESTAMP"
  echo "borg_extract_exit_code{${_metadata}} $BORG_EXTRACT_EXIT_CODE"
  echo "borg_hours_from_last_archive{${_metadata}} $NB_HOUR_FROM_LAST_BCK"
  echo "borg_archives_count{${_metadata}} $COUNTER"
  echo "borg_files_count{${_metadata}} $(echo "$BORG_INFO" | grep "Number of files" | awk '{print $4}')"
  echo "borg_chunks_unique{${_metadata}} $(echo "$BORG_INFO" | grep "Chunk index" | awk '{print $3}')"
  echo "borg_chunks_total{${_metadata}} $(echo "$BORG_INFO" | grep "Chunk index" | awk '{print $4}')"
  echo "borg_last_size{${_metadata}} $LAST_SIZE"
  echo "borg_last_size_compressed{${_metadata}} $LAST_SIZE_COMPRESSED"
  echo "borg_last_size_dedup{${_metadata}} $LAST_SIZE_DEDUP"
  echo "borg_total_size{${_metadata}} $TOTAL_SIZE"
  echo "borg_total_size_compressed{${_metadata}} $TOTAL_SIZE_COMPRESSED"
  echo "borg_total_size_dedup{${_metadata}} $TOTAL_SIZE_DEDUP"
} > "$TMP_FILE"

mv -f "$TMP_FILE" "$PROM_FILE"

if [ -n "${CONFIG_USER+x}" ]; then
  chown "$CONFIG_USER" "$PROM_FILE"
fi

if [ -n "${CONFIG_GROUP+x}" ]; then
  chgrp "$CONFIG_GROUP" "$PROM_FILE"
fi

exit 0
