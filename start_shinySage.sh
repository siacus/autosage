#!/bin/bash

# Absolute path to your R script
APP_PATH="/Users/service/github/autosage/shinySage.R"

# Export the desired port
export SHINY_PORT=8083

# Optional: set to 0.0.0.0 if you want it accessible from outside
export SHINY_HOST=0.0.0.0


# Run the app
Rscript -e "shiny::runApp('${APP_PATH}', port=${SHINY_PORT}, host='${SHINY_HOST}')"

