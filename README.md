# How Do Agents Use Languages?

Experimental harness for measuring how LLM coding agents perform across programming languages on a fixed implementation task. Each experiment gives an agent a specification (a todo-list REST API with cookie-based auth), a target language, and a set of tools, then scores the resulting server against a 53-test suite.

Two agent variants are included. The **baseline agent** has four tools: write file, read file, execute command, and list files. The **MCP agent** extends this with three language-server tools (diagnostics, hover, definition) provided by [mcp-language-server](https://github.com/isaacphi/mcp-language-server) running as a sidecar process. The sidecar wraps any LSP server (pyright, rust-analyzer, gopls, clangd, etc.) and exposes its capabilities over MCP's JSON-RPC protocol.

## Repository layout

```
agents/
  agent.py              # Baseline agent (write/read/execute/list/done)
  agent_mcp.py          # MCP agent (adds diagnostics/hover/definition)
eval/
  spec.md               # Todo API specification given to agents
  test_server.sh        # TAP test suite (53 tests)
  smart_run.sh          # Port-passing wrapper for run.sh
scheduler/
  scheduler.py          # Batch scheduler for baseline experiments
  scheduler_mcp.py      # Batch scheduler for MCP experiments
  run_tests.py          # Score completed experiments against test suite
  watchdog.sh           # Auto-restart wrapper for long batch runs
data_baseline/
  {model}/{language}/rep{N}/   # Generated source code (baseline)
data_mcp/
  gpt-5/{language}/rep{N}/     # Generated source code (MCP)
results_baseline/
  {model}/{language}/rep{N}.json  # Experiment metadata (tokens, turns, duration)
  test_scores.jsonl               # Test pass/fail per experiment
results_mcp/
  gpt-5/{language}/rep{N}.json    # Experiment metadata
  gpt-5/{language}/rep{N}.log     # Agent tool-call traces
  test_scores.jsonl               # Test pass/fail per experiment
```

## The task

The specification in `eval/spec.md` defines a REST API server for managing personal todo items. It requires cookie-based authentication with session management, user registration and login, CRUD operations on per-user todos with timestamps, input validation, and user isolation (returning 404 for other users' resources to prevent ID enumeration). The server must accept `--port PORT` and bind to `0.0.0.0`.

## Agents

Both agents follow an agentic loop: system prompt with language-specific instructions, user message with the full specification, then iterative tool calls until the agent calls `done` or hits the turn limit (200).

**Baseline** (`agents/agent.py`): supports Anthropic and OpenAI-compatible APIs. Tools are write_file, read_file, execute, list_files, and done.

**MCP** (`agents/agent_mcp.py`): same base tools plus three language-server tools. On startup it launches `mcp-language-server` as a subprocess, initialises the MCP handshake, and proxies tool calls to the sidecar throughout the experiment. Supported language servers:

| Language | LSP server |
|----------|-----------|
| Python | pyright |
| TypeScript | typescript-language-server |
| JavaScript | typescript-language-server |
| Rust | rust-analyzer |
| Go | gopls |
| C | clangd |
| Java | jdtls |
| Scala | metals |

## Evaluation

`eval/test_server.sh` is a bash test suite in TAP format. It starts the agent's generated server, then exercises registration, login, auth enforcement, CRUD, user isolation, password changes, and logout. 53 assertions total.

Usage:
```bash
./eval/test_server.sh "bash /path/to/workdir/run.sh"
```

The test script picks a random high port, waits for the server to become ready, runs all tests, and prints TAP output with pass/fail counts.

## Running experiments

### Single experiment

```bash
# Baseline
python agents/agent.py \
  --model gpt-5 \
  --language python \
  --workdir /tmp/exp1 \
  --output /tmp/exp1_result.json

# MCP variant
python agents/agent_mcp.py \
  --model gpt-5 \
  --language rust \
  --workdir /tmp/exp2 \
  --output /tmp/exp2_result.json
```

### Batch

The schedulers run a full grid of (model, language, repetition) experiments with provider-aware rate limiting and configurable parallelism.

```bash
python scheduler/scheduler.py --max-workers 4
python scheduler/scheduler_mcp.py --max-workers 1
```

Both write per-experiment result JSON files (status, token counts, turn counts, duration) and per-experiment logs.

### Scoring

After experiments complete, score them:

```bash
python scheduler/run_tests.py
```

Produces a JSONL file with one entry per experiment: model, language, rep, passed, total.

## Data

The repository includes generated code and results from two experiment batches.

**Baseline** (`data_baseline/`, `results_baseline/`): 3 models (GPT-5, Qwen3-Coder-Plus, Qwen3.7-Plus) across 11 languages (Python, JavaScript, TypeScript, Python-mypy, Java, Go, Rust, Scala, C, Haskell, Lean, Assembly) with 10 repetitions each. 289 scored experiments in `results_baseline/test_scores.jsonl`.

**MCP** (`data_mcp/`, `results_mcp/`): GPT-5 across 9 languages (Python, JavaScript, TypeScript, Python-mypy, Java, Go, Rust, Scala, C) with 10 repetitions. 87 scored experiments in `results_mcp/test_scores.jsonl`. The MCP logs (`rep{N}.log`) record every tool call the agent made, including which language-server tools it chose to use and when.

Each result JSON contains:
```json
{
  "status": "completed",
  "model": "gpt-5",
  "language": "python",
  "input_tokens": 65213,
  "output_tokens": 13769,
  "total_tokens": 78982,
  "turns": 8,
  "duration_seconds": 119.86
}
```

Each test score entry contains:
```json
{"model": "gpt-5", "language": "python", "rep": 1, "passed": 53, "total": 53}
```

## Environment variables

| Variable | Used by |
|----------|---------|
| `OPENAI_API_KEY` | Both agents (OpenAI models) |
| `ANTHROPIC_API_KEY` | Baseline agent (Anthropic models) |
| `OPENROUTER_API_KEY` | Both agents (OpenRouter models) |
| `SPEC_PATH` | Override path to spec.md |
| `MCP_BIN` | Override path to mcp-language-server binary |

## Dependencies

- Python 3.10+ with `openai` and optionally `anthropic` packages
- [mcp-language-server](https://github.com/isaacphi/mcp-language-server) (for MCP agent)
- Language toolchains for target languages (compilers, package managers)
- `jq` and `curl` for the test suite
