#!/bin/bash
# Watchdog: restarts the scheduler if it dies, until all 90 experiments are done
source /root/experiments/.env
cd /root/experiments

while true; do
    done_count=$(ls results_mcp/gpt-5/*/rep*.json 2>/dev/null | wc -l)
    echo "[watchdog] $(date): $done_count/90 done, starting scheduler..."

    # Kill ALL orphaned experiment processes aggressively
    pkill -9 -f "mcp-language-server" 2>/dev/null
    pkill -9 -f "gopls" 2>/dev/null
    pkill -9 -f "rust-analyzer" 2>/dev/null
    pkill -9 -f "metals" 2>/dev/null
    pkill -9 -f "pyright-langserver" 2>/dev/null
    pkill -9 -f "typescript-language-server" 2>/dev/null
    pkill -9 -f "clangd" 2>/dev/null
    pkill -9 -f "jdtls" 2>/dev/null
    pkill -9 -f "todo_server\|todo-server\|server.*--port" 2>/dev/null
    # Kill anything on common experiment ports
    for port in $(seq 8080 8100) $(seq 9090 9100) $(seq 19000 19100) $(seq 22000 22300); do
        fuser -k "$port/tcp" 2>/dev/null
    done
    sleep 2
    echo "[watchdog] $(date): memory before: $(free -m | awk '/Mem:/{print $4}')MB free"

    python3 scheduler_mcp.py --max-workers 1 2>&1 | tee -a scheduler_mcp.log

    done_count=$(ls results_mcp/gpt-5/*/rep*.json 2>/dev/null | wc -l)
    if [ "$done_count" -ge 90 ]; then
        echo "[watchdog] $(date): All 90 done!"
        break
    fi

    echo "[watchdog] $(date): Scheduler exited at $done_count/90, restarting in 5s..."
    sleep 5
done
