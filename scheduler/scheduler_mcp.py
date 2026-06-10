#!/usr/bin/env python3
"""
Scheduler for running coding agent experiments with rate limiting per provider.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from collections import defaultdict

LANGUAGES = [
    "c", "python", "javascript", "python-mypy",
    "typescript", "java", "go", "scala", "rust",
]

# Provider grouping for rate limiting
# Group 1: OpenAI direct (uses OPENAI_API_KEY)
# Group 2: OpenRouter/Anthropic (uses OPENROUTER_API_KEY, routes to Anthropic backend)
# Group 3: OpenRouter/Other (uses OPENROUTER_API_KEY, routes to other backends)
MODELS = {
    "gpt-5": "openai",
}

PROVIDER_CONCURRENCY = {
    "openai": 1,
    "openrouter-other": 1,
}

# Cleanup: delete heavy build caches from workdir after testing
# to prevent disk from filling up. Keeps compiled binaries (target/, .scala-build/)
# so the test runner can execute them without rebuilding.
CLEANUP_DIRS = ["node_modules", ".cache", "__pycache__", ".bloop", ".metals"]

REPS = 10
BASE_DIR = "/root/experiments"
DATA_DIR = f"{BASE_DIR}/data_mcp"
RESULTS_DIR = f"{BASE_DIR}/results_mcp"

# Provider semaphores
provider_sems = {p: threading.Semaphore(c) for p, c in PROVIDER_CONCURRENCY.items()}
# Global lock for results file
results_lock = threading.Lock()
# Counter
counter_lock = threading.Lock()
completed_count = 0


def _cleanup_processes():
    """Kill orphaned server/build processes left by experiments."""
    # Kill processes listening on experiment ports (8080-8090)
    for port in range(8080, 8091):
        subprocess.run(
            ["fuser", "-k", f"{port}/tcp"],
            capture_output=True, timeout=5
        )
    # Kill any orphaned bloop/sbt daemons
    subprocess.run(["pkill", "-f", "bloop"], capture_output=True)
    subprocess.run(["pkill", "-f", "sbt.launch"], capture_output=True)


def get_result_path(model, language, rep):
    model_safe = model.replace("/", "__")
    return f"{RESULTS_DIR}/{model_safe}/{language}/rep{rep}.json"


def get_workdir(model, language, rep):
    model_safe = model.replace("/", "__")
    return f"{DATA_DIR}/{model_safe}/{language}/rep{rep}"


def run_one(model, language, rep, total):
    """Run a single experiment."""
    global completed_count
    provider = MODELS[model]
    result_path = get_result_path(model, language, rep)
    workdir = get_workdir(model, language, rep)

    # Skip if already completed
    if os.path.exists(result_path):
        try:
            with open(result_path) as f:
                existing = json.load(f)
            if existing.get("status") == "completed":
                with counter_lock:
                    completed_count += 1
                    c = completed_count
                print(f"[{c}/{total}] SKIP {model}/{language}/rep{rep}", file=sys.stderr, flush=True)
                return f"SKIP"
        except:
            pass

    # Acquire provider semaphore
    sem = provider_sems[provider]
    sem.acquire()
    try:
        # Clean workdir
        if os.path.exists(workdir):
            subprocess.run(["rm", "-rf", workdir], capture_output=True)
        os.makedirs(workdir, exist_ok=True)

        env = {
            **os.environ,
            "ANTHROPIC_API_KEY": os.environ.get("ANTHROPIC_API_KEY", ""),
            "OPENAI_API_KEY": os.environ.get("OPENAI_API_KEY", ""),
            "OPENROUTER_API_KEY": os.environ.get("OPENROUTER_API_KEY", ""),
        }

        cmd = [
            sys.executable, f"{BASE_DIR}/agent_mcp_lsp.py",
            "--model", model,
            "--language", language,
            "--workdir", workdir,
            "--output", result_path,
            "--max-turns", "200",
        ]

        with counter_lock:
            c = completed_count
        print(f"[{c}/{total}] START {model}/{language}/rep{rep}", file=sys.stderr, flush=True)

        # Log agent stderr to per-experiment log file
        log_dir = os.path.dirname(result_path)
        os.makedirs(log_dir, exist_ok=True)
        log_path = result_path.replace(".json", ".log")
        with open(log_path, "w") as log_f:
            proc = subprocess.run(
                cmd, stdout=subprocess.PIPE, stderr=log_f, text=True, timeout=1800, env=env
            )

        with counter_lock:
            completed_count += 1
            c = completed_count

        # Read result to get summary info
        try:
            with open(result_path) as f:
                r = json.load(f)
            status = r.get("status", "unknown")
            tokens = r.get("total_tokens", 0)
            turns = r.get("turns", 0)
            dur = r.get("duration_seconds", 0)
            elapsed_msg = f"{dur:.0f}s" if dur else ""
            print(f"[{c}/{total}] DONE {model}/{language}/rep{rep} status={status} tokens={tokens} turns={turns} {elapsed_msg}",
                  file=sys.stderr, flush=True)
        except:
            print(f"[{c}/{total}] DONE {model}/{language}/rep{rep} (no result file)", file=sys.stderr, flush=True)

        # Kill any leftover server processes (agents spawn servers on ports 8080-8090)
        _cleanup_processes()

        # Clean up heavy build artifacts to save disk space
        for d in CLEANUP_DIRS:
            artifact = os.path.join(workdir, d)
            if os.path.exists(artifact):
                subprocess.run(["rm", "-rf", artifact], capture_output=True)
            # Also check one level deep (e.g., todo_app/target)
            for sub in os.listdir(workdir):
                artifact = os.path.join(workdir, sub, d)
                if os.path.isdir(artifact):
                    subprocess.run(["rm", "-rf", artifact], capture_output=True)

        return f"DONE"

    except subprocess.TimeoutExpired:
        _cleanup_processes()
        with counter_lock:
            completed_count += 1
            c = completed_count
        os.makedirs(os.path.dirname(result_path), exist_ok=True)
        with open(result_path, "w") as f:
            json.dump({
                "status": "timeout",
                "model": model,
                "language": language,
                "error": "Experiment timed out after 30 minutes",
                "input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "turns": 0,
            }, f, indent=2)
        print(f"[{c}/{total}] TIMEOUT {model}/{language}/rep{rep}", file=sys.stderr, flush=True)
        return f"TIMEOUT"
    except Exception as e:
        _cleanup_processes()
        with counter_lock:
            completed_count += 1
            c = completed_count
        print(f"[{c}/{total}] ERROR {model}/{language}/rep{rep}: {e}", file=sys.stderr, flush=True)
        return f"ERROR"
    finally:
        sem.release()


def schedule_all(models=None, languages=None, reps=None, max_workers=8):
    """Schedule all experiments with provider-aware rate limiting."""
    global completed_count
    completed_count = 0

    if models is None:
        models = list(MODELS.keys())
    if languages is None:
        languages = LANGUAGES
    if reps is None:
        reps = REPS

    # Build task list
    tasks = []
    for rep in range(1, reps + 1):
        for lang in languages:
            for model in models:
                tasks.append((model, lang, rep))

    # Sort: fast languages first, then interleave providers within each tier
    LANG_SPEED = {
        "python": 0, "javascript": 0, "typescript": 0, "python-mypy": 1,
        "go": 1, "java": 1, "rust": 2, "scala": 2, "c": 2,
    }
    import random
    random.seed(42)
    random.shuffle(tasks)  # shuffle first for provider interleaving
    tasks.sort(key=lambda t: LANG_SPEED.get(t[1], 99))  # stable sort preserves shuffle within tier

    total = len(tasks)
    start = time.time()

    print(f"Scheduling {total} experiments: {len(models)} models × {len(languages)} languages × {reps} reps", file=sys.stderr, flush=True)
    print(f"Models: {models}", file=sys.stderr, flush=True)
    print(f"Provider concurrency: {PROVIDER_CONCURRENCY}", file=sys.stderr, flush=True)

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for model, lang, rep in tasks:
            f = executor.submit(run_one, model, lang, rep, total)
            futures[f] = (model, lang, rep)

        for f in as_completed(futures):
            try:
                f.result()
            except Exception as e:
                model, lang, rep = futures[f]
                print(f"EXCEPTION {model}/{lang}/rep{rep}: {e}", file=sys.stderr, flush=True)

    elapsed = time.time() - start
    print(f"\nAll done. {total} experiments in {elapsed:.0f}s ({elapsed/60:.1f}m)", file=sys.stderr, flush=True)


def show_progress():
    """Show current progress."""
    total = 0
    completed = 0
    errors = 0
    by_model = defaultdict(lambda: {"done": 0, "total": 0, "error": 0, "tokens": []})
    by_lang = defaultdict(lambda: {"done": 0, "total": 0, "error": 0, "tokens": []})

    for model in MODELS:
        for lang in LANGUAGES:
            for rep in range(1, REPS + 1):
                total += 1
                by_model[model]["total"] += 1
                by_lang[lang]["total"] += 1
                path = get_result_path(model, lang, rep)
                if os.path.exists(path):
                    try:
                        with open(path) as f:
                            r = json.load(f)
                        if r.get("status") == "completed":
                            completed += 1
                            by_model[model]["done"] += 1
                            by_lang[lang]["done"] += 1
                            by_model[model]["tokens"].append(r.get("total_tokens", 0))
                            by_lang[lang]["tokens"].append(r.get("total_tokens", 0))
                        else:
                            errors += 1
                            by_model[model]["error"] += 1
                            by_lang[lang]["error"] += 1
                    except:
                        errors += 1

    print(f"Progress: {completed}/{total} completed, {errors} errors\n")
    print("By model:")
    for m in MODELS:
        d = by_model[m]
        avg_tok = sum(d["tokens"]) / len(d["tokens"]) if d["tokens"] else 0
        print(f"  {m:50s} {d['done']:3d}/{d['total']:3d} done, {d['error']:3d} errors, avg_tokens={avg_tok:.0f}")
    print("\nBy language:")
    for l in LANGUAGES:
        d = by_lang[l]
        avg_tok = sum(d["tokens"]) / len(d["tokens"]) if d["tokens"] else 0
        print(f"  {l:20s} {d['done']:3d}/{d['total']:3d} done, {d['error']:3d} errors, avg_tokens={avg_tok:.0f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--progress", action="store_true", help="Show progress")
    parser.add_argument("--models", nargs="*", help="Specific models to run")
    parser.add_argument("--languages", nargs="*", help="Specific languages to run")
    parser.add_argument("--reps", type=int, default=REPS, help="Number of repetitions")
    parser.add_argument("--max-workers", type=int, default=8, help="Max parallel workers")
    args = parser.parse_args()

    if args.progress:
        show_progress()
    else:
        schedule_all(
            models=args.models,
            languages=args.languages,
            reps=args.reps,
            max_workers=args.max_workers,
        )
