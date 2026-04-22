APPS_DIR="./apps"
if [ ! -d "$APPS_DIR" ]; then
  echo "Directory $APPS_DIR does not exist."
  exit 1
fi

# Loop over each subdirectory of ./apps
for dir in "$APPS_DIR"/*/; do
  if [ -d "$dir" ]; then
    echo "Processing directory: $dir"
    cd "$dir" || continue
    
    # Check if a docker-compose file exists (either .yml or .yaml)
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
      echo "Found docker-compose file in $dir. Executing commands..."
      # Use the root .env file for all apps
      docker compose --env-file ../../.env pull && docker compose --env-file ../../.env up -d --remove-orphans
    else
      echo "No docker-compose file found in $dir. Skipping."
    fi

    # Return to the previous directory
    cd - > /dev/null || exit
  fi
done

echo "All subdirectories processed."
