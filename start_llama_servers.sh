#!/bin/bash


# Model paths
MODEL1_PATH="/Users/service/gguf/llama2-7B-categories-Q4_K_M.gguf"
MODEL2_PATH="/Users/service/gguf/llama32-3B-keywords-Q4_K_M.gguf"

# Ports
PORT1=8081  # subject categories
PORT2=8082  # keywords

# Compiled llama server binary
LLAMA_SERVER="/Users/service/github/llama.cpp/build/bin/llama-server"

# Threads (tune as needed)
N_THREADS=$(($(sysctl -n hw.logicalcpu) - 1))

# Ensure log dir
mkdir -p logs

echo "Starting category classification model on port $PORT1..."
"$LLAMA_SERVER" \
  --model "$MODEL1_PATH" \
  --host 0.0.0.0 \
  --port "$PORT1" \
  --ctx-size 4096 \
  --n-predict 256 \
  --threads "$N_THREADS" \
  --n-gpu-layers -1 \
  > logs/categories.log 2>&1 &

PID1=$!

echo "Starting keyword generation model on port $PORT2..."
"$LLAMA_SERVER" \
  --model "$MODEL2_PATH" \
  --host 0.0.0.0 \
  --port "$PORT2" \
  --ctx-size 4096 \
  --n-predict 256 \
  --threads "$N_THREADS" \
  --n-gpu-layers -1 \
  > logs/keywords.log 2>&1 &

PID2=$!

echo "Models running:"
echo " - Categories → http://localhost:$PORT1"
echo " - Keywords   → http://localhost:$PORT2"
echo "PIDs: $PID1 $PID2"

# Keep alive
wait
