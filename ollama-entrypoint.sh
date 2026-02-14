#!/bin/sh
set -e

# Start the Ollama server in the background
ollama serve &
OLLAMA_PID=$!

# Wait until the server is ready
echo "Waiting for Ollama to start..."
until ollama list >/dev/null 2>&1; do
  sleep 1
done
echo "Ollama is ready."

# Pull models if not already present
ollama pull qwen3-vl:4b
ollama pull embeddinggemma

# Hand off to the server process (keeps container alive)
wait $OLLAMA_PID