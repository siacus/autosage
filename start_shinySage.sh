#!/bin/bash

export PATH="/usr/local/bin:$PATH"

# --- Configuration ---
# Absolute path to your app directory
APP_DIR="/Users/service/github/autosage"

# Export the desired port and host
export SHINY_PORT=8083
export SHINY_HOST=0.0.0.0


# --- Check for and Kill Existing Process ---
echo "Checking for any process running on port ${SHINY_PORT}..."

# Use lsof -t to get only the PID of the process on the specified port.
# The output will be empty if no process is found.
PID=$(lsof -t -i:${SHINY_PORT})

# Check if the PID variable is non-empty
if [ -n "$PID" ]; then
  echo "Found existing process with PID: ${PID}. Killing it now."
  kill ${PID}
  # Wait a moment for the process to terminate and release the port
  sleep 2
  echo "Process killed."
else
  echo "No existing process found. Starting a new one."
fi


# --- Run the Shiny App ---
echo "Starting Shiny app on ${SHINY_HOST}:${SHINY_PORT}..."
# Run the app using directory path, not a single file
/usr/local/bin/Rscript -e "shiny::runApp('${APP_DIR}', port=${SHINY_PORT}, host='${SHINY_HOST}', launch.browser = FALSE)"