#!/bin/bash

#########################################################
# S3 to CleverTap SFTP Transfer Script
#
# This script automates the transfer of data files from
# an AWS S3 bucket to CleverTap via SFTP
# No remote path required - uses the default SFTP landing directory
#########################################################

# Set error handling
set -e  # Exit immediately if a command exits with non-zero status
set -o pipefail  # Return value of a pipeline is the status of the last command

# Define log function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
}

# Path variables
LOCAL_PATH="/tmp/clevertap_data_transfer/temp/"  # Local temporary storage
SSH_KEY_PATH="/tmp/clevertap_data_transfer/.ssh_key"  # Temporary SSH key file
CSV_FILE_PATTERN="*.csv"  # Pattern of CSV files to transfer
MANIFEST_FILE_PATTERN="*.manifest"  # Pattern of manifest files to transfer
SFTP_BATCH_FILE="/tmp/clevertap_data_transfer/sftp_commands.txt"

# Create required directories
mkdir -p "$LOCAL_PATH" "$(dirname "$SSH_KEY_PATH")" "$(dirname "$SFTP_BATCH_FILE")"

# Write the SSH key to a temporary file
echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"

# Start logging
log "=== Starting S3 to CleverTap data transfer ==="
log "S3 Bucket: $S3_BUCKET/$S3_PREFIX"
log "CleverTap SFTP: $CLEVERTAP_USER@$CLEVERTAP_HOST"

# Function to clean up on exit
cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$LOCAL_PATH"/*
    rm -f "$SSH_KEY_PATH"  # Remove the temporary SSH key file
    log "Cleanup complete."
}

# Register the cleanup function
trap cleanup EXIT INT TERM

# Download files from S3
log "Downloading CSV files from S3 bucket..."
aws s3 sync "s3://$S3_BUCKET/$S3_PREFIX" "$LOCAL_PATH" --exclude "*" --include "$CSV_FILE_PATTERN" --include "$MANIFEST_FILE_PATTERN"

# Check if any files were downloaded
csv_count=$(find "$LOCAL_PATH" -name "*.csv" -type f | wc -l)
manifest_count=$(find "$LOCAL_PATH" -name "*.manifest" -type f | wc -l)

log "Downloaded $csv_count CSV files and $manifest_count manifest files for transfer."

if [ "$csv_count" -eq 0 ]; then
    log "No CSV files found to transfer. Exiting."
    exit 0
fi

# # Generate manifest files for any CSV without one
# for csv_file in "$LOCAL_PATH"/*.csv; do
#     if [ -f "$csv_file" ]; then
#         base_name="${csv_file%.csv}"
#         manifest_file="${base_name}.manifest"

#         # If manifest doesn't exist, create one
#         if [ ! -f "$manifest_file" ]; then
#             log "Creating manifest file for $(basename "$csv_file")"
#             csv_filename=$(basename "$csv_file")

#             # Get the first few lines from CSV to analyze structure
#             header_line=$(head -n 1 "$csv_file")
#             IFS=',' read -ra HEADERS <<< "$header_line"

#             # Look for common identity columns
#             identity_column=""
#             for column in "${HEADERS[@]}"; do
#                 # Remove quotes and whitespace
#                 clean_column=$(echo "$column" | tr -d '"' | sed 's/^ *//;s/ *$//')

#                 # Convert to lowercase for comparison
#                 lower_column=$(echo "$clean_column" | tr '[:upper:]' '[:lower:]')

#                 # Check for common identity column names
#                 if [[ "$lower_column" == *"email"* ||
#                       "$lower_column" == *"identity"* ||
#                       "$lower_column" == *"id"* ||
#                       "$lower_column" == *"user"* ]]; then
#                     identity_column="$clean_column"
#                     break
#                 fi
#             done

#             # If no identity column found, use the first column
#             if [ -z "$identity_column" ]; then
#                 identity_column="${HEADERS[0]}"
#                 identity_column=$(echo "$identity_column" | tr -d '"' | sed 's/^ *//;s/ *$//')
#             fi

#             log "Using '$identity_column' as identity column"

#             # Create CleverTap manifest file based on existing successful formats
#             cat > "$manifest_file" << EOF
# {
#   "version": 1,
#   "format": "csv",
#   "header": true,
#   "identity": "$identity_column",
#   "objectId": "objectId",
#   "type": "type",
#   "evtName": "evtName",
#   "evtData": "evtData",
#   "ts": "ts",
#   "profile": "profile",
#   "delimiter": ",",
#   "quote": "\"",
#   "escape": "\\\\",
#   "file": "$csv_filename"
# }
# EOF
#             log "Created manifest file: $(basename "$manifest_file")"
#         fi
#     fi
# done

# # Recount manifest files after potential creation
# manifest_count=$(find "$LOCAL_PATH" -name "*.manifest" -type f | wc -l)
# log "Ready to transfer $csv_count CSV files and $manifest_count manifest files."

# Create batch file for SFTP commands
echo "pwd" > "$SFTP_BATCH_FILE"  # Print working directory to verify location
echo "lcd $LOCAL_PATH" >> "$SFTP_BATCH_FILE"

# First upload all CSV files
echo "# Uploading CSV files" >> "$SFTP_BATCH_FILE"
for csv_file in "$LOCAL_PATH"/*.csv; do
    if [ -f "$csv_file" ]; then
        echo "put \"$(basename "$csv_file")\"" >> "$SFTP_BATCH_FILE"
    fi
done

# Then upload all manifest files
echo "# Uploading manifest files" >> "$SFTP_BATCH_FILE"
for manifest_file in "$LOCAL_PATH"/*.manifest; do
    if [ -f "$manifest_file" ]; then
        echo "put \"$(basename "$manifest_file")\"" >> "$SFTP_BATCH_FILE"
    fi
done

echo "ls -la" >> "$SFTP_BATCH_FILE"  # List files to verify upload
echo "bye" >> "$SFTP_BATCH_FILE"

# Upload files via SFTP
log "Uploading files to CleverTap via SFTP..."
sftp -b "$SFTP_BATCH_FILE" -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$CLEVERTAP_USER@$CLEVERTAP_HOST"

# Check if SFTP transfer was successful
if [ $? -ne 0 ]; then
    log "ERROR: SFTP transfer failed."
    exit 1
fi

# Count successfully transferred files
total_files=$((csv_count + manifest_count))
log "Successfully transferred $total_files files to CleverTap ($csv_count CSV files with $manifest_count manifest files)."

# Optional: Move processed files to a 'processed' folder in S3
#if [ "$csv_count" -gt 0 ]; then
#    log "Moving processed files to archive folder in S3..."
#    # Ensure the processed directory exists in S3
#    aws s3api put-object --bucket "$S3_BUCKET" --key "${S3_PREFIX}processed/"
#    for file in "$LOCAL_PATH"/*.csv "$LOCAL_PATH"/*.manifest; do
#        if [ -f "$file" ]; then
#            filename=$(basename "$file")
#            aws s3 mv "s3://$S3_BUCKET/$S3_PREFIX$filename" "s3://$S3_BUCKET/$S3_PREFIX"processed/"$filename"
#        fi
#    done
#fi

log "=== Transfer complete ==="
exit 0