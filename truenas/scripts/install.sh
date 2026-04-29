#!/usr/bin/env bash
# Deploy the forensic watcher as a TrueNAS Scale Custom App.
# Run from the directory containing docker-compose.yml.
set -euo pipefail

IMAGE="forensic-file-integrity-truenas:latest"

echo "Building Docker image..."
docker build -t "$IMAGE" .

echo "Starting container (detached)..."
docker compose up -d

echo ""
echo "Container started. Check logs with:"
echo "  docker compose logs -f forensic-watcher"
echo ""
echo "To run the verifier:"
echo "  docker compose exec forensic-watcher python src/verifier.py"
echo ""
echo "To generate a report:"
echo "  docker compose exec forensic-watcher python src/reporter.py"
