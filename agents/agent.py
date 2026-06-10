#!/usr/bin/env python3
"""
Coding agent that implements a todo server in a specified language.
Supports Anthropic, OpenAI, and OpenRouter APIs.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import traceback

SPEC_PATH = os.environ.get("SPEC_PATH", os.path.join(os.path.dirname(__file__), "..", "eval", "spec.md"))
SPEC = open(SPEC_PATH).read()

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")

LANGUAGE_INSTRUCTIONS = {
    "assembly": "You MUST implement this entirely in x86_64 NASM assembly. Use Linux syscalls directly for networking. Compile with: nasm -f elf64 and link with ld. Create a run.sh that builds and runs the binary.",
    "c": "You MUST implement this entirely in C. Use standard POSIX APIs. Compile with gcc. Create a run.sh that compiles and runs the binary. You may use any libraries available (install with apt if needed).",
    "python": "You MUST implement this entirely in Python 3. Use only the standard library or install packages with pip. Create a run.sh that runs the server with python3.",
    "javascript": "You MUST implement this entirely in JavaScript (Node.js). Use only built-in modules or install packages with npm. Create a run.sh that runs the server with node.",
    "python-mypy": "You MUST implement this entirely in Python 3 with FULL strict mypy type annotations. ALL code must pass `mypy --strict` with zero errors. Run mypy to verify before finishing. Create a run.sh that runs the server with python3.",
    "typescript": "You MUST implement this entirely in TypeScript. Compile with tsc or use tsx. Create a run.sh that compiles (if needed) and runs the server.",
    "java": "You MUST implement this entirely in Java. Use the standard library or download dependencies. Create a run.sh that compiles and runs the server with javac/java.",
    "scala": "You MUST implement this entirely in Scala. You can use scala-cli (install it if needed: curl -sSLf https://scala-cli.virtuslab.org/get | bash). Create a run.sh that builds and runs the server.",
    "rust": "You MUST implement this entirely in Rust. Use cargo to manage the project. Create a run.sh that builds with cargo and runs the resulting binary.",
    "lean": "You MUST implement this entirely in Lean 4. Use Lake for project management. Create a run.sh that builds with lake and runs the resulting binary. You may need to add HTTP server dependencies.",
    "haskell": "You MUST implement this entirely in Haskell. Use cabal for dependency management. Create a run.sh that builds with cabal and runs the resulting binary. You may use any Hackage libraries (e.g. warp, scotty, servant, aeson). Install with cabal install if needed.",
}

TOOLS_ANTHROPIC = [
    {
        "name": "write_file",
        "description": "Write content to a file (creates directories as needed)",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File path (relative to working directory)"},
                "content": {"type": "string", "description": "File content to write"},
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "execute",
        "description": "Execute a bash command and return stdout+stderr. Timeout: 120s.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Bash command to run"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "read_file",
        "description": "Read a file's content",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File path (relative to working directory)"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "list_files",
        "description": "List files in a directory recursively",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Directory path (default: current dir)", "default": "."},
            },
        },
    },
    {
        "name": "done",
        "description": "Signal that you have finished implementing the server. Call this when your implementation is complete and run.sh is ready.",
        "input_schema": {
            "type": "object",
            "properties": {
                "summary": {"type": "string", "description": "Brief summary of what you built"},
            },
            "required": ["summary"],
        },
    },
]

TOOLS_OPENAI = [
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write content to a file (creates directories as needed)",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path (relative to working directory)"},
                    "content": {"type": "string", "description": "File content to write"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "execute",
            "description": "Execute a bash command and return stdout+stderr. Timeout: 120s.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Bash command to run"},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a file's content",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path (relative to working directory)"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files in a directory recursively",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory path (default: current dir)"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "done",
            "description": "Signal that you have finished implementing the server. Call this when your implementation is complete and run.sh is ready.",
            "parameters": {
                "type": "object",
                "properties": {
                    "summary": {"type": "string", "description": "Brief summary of what you built"},
                },
                "required": ["summary"],
            },
        },
    },
]


def execute_tool(name: str, args: dict, workdir: str) -> str:
    if name == "write_file":
        path = os.path.join(workdir, args["path"])
        os.makedirs(os.path.dirname(path) or workdir, exist_ok=True)
        with open(path, "w") as f:
            f.write(args["content"])
        return f"File written: {args['path']} ({len(args['content'])} bytes)"

    elif name == "execute":
        try:
            result = subprocess.run(
                args["command"],
                shell=True,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=workdir,
                env={**os.environ, "HOME": "/root", "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin") + ":/root/.local/bin:/root/.local/share/coursier/bin:/root/.cargo/bin:/root/.elan/bin"},
            )
            output = ""
            if result.stdout:
                output += result.stdout
            if result.stderr:
                output += ("\n" if output else "") + result.stderr
            if not output:
                output = "(no output)"
            output += f"\n[exit code: {result.returncode}]"
            # Truncate very long outputs
            if len(output) > 15000:
                output = output[:7000] + "\n\n... (truncated) ...\n\n" + output[-7000:]
            return output
        except subprocess.TimeoutExpired:
            return "[command timed out after 120s]"
        except Exception as e:
            return f"[error: {e}]"

    elif name == "read_file":
        path = os.path.join(workdir, args["path"])
        try:
            with open(path) as f:
                content = f.read()
            if len(content) > 15000:
                content = content[:7000] + "\n\n... (truncated) ...\n\n" + content[-7000:]
            return content
        except FileNotFoundError:
            return f"[file not found: {args['path']}]"
        except Exception as e:
            return f"[error reading file: {e}]"

    elif name == "list_files":
        target = os.path.join(workdir, args.get("path", "."))
        try:
            files = []
            for root, dirs, filenames in os.walk(target):
                # Skip hidden dirs and common build dirs
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "target", "__pycache__", ".git")]
                for fn in filenames:
                    rel = os.path.relpath(os.path.join(root, fn), workdir)
                    files.append(rel)
            return "\n".join(sorted(files)[:200]) or "(empty)"
        except Exception as e:
            return f"[error: {e}]"

    elif name == "done":
        return "DONE"

    return f"[unknown tool: {name}]"


def get_provider(model_id: str):
    """Determine provider from model ID."""
    if model_id.startswith("openrouter/"):
        return "openrouter"
    else:
        # All non-openrouter models go to OpenAI (including gpt-*, o3-*, gpt-4.1-*)
        return "openai"


def resolve_model(model_id: str):
    """Resolve model aliases to full model IDs for API calls."""
    if model_id.startswith("openrouter/"):
        return model_id[len("openrouter/"):]
    return model_id


def run_anthropic(model_id: str, language: str, workdir: str, max_turns: int = 200):
    import anthropic

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
    resolved = resolve_model(model_id)

    system_prompt = f"""You are a coding agent implementing a REST API server. You have tools to write files, execute bash commands, read files, and list files.

CRITICAL REQUIREMENTS:
- {LANGUAGE_INSTRUCTIONS[language]}
- Create a `run.sh` at the project root. It MUST accept `--port PORT` as arguments and start the server on that port.
- run.sh should be executable (chmod +x).
- The server must bind to 0.0.0.0:PORT.
- Implement ALL endpoints from the specification - do not skip any.
- When done, call the `done` tool.

Work in the current directory. You can install packages as needed."""

    user_msg = f"Implement this server specification in {language}:\n\n{SPEC}"

    messages = [{"role": "user", "content": user_msg}]
    total_input = 0
    total_output = 0
    total_cache_read = 0
    total_cache_create = 0
    turn = 0

    while turn < max_turns:
        turn += 1
        try:
            resp = client.messages.create(
                model=resolved,
                max_tokens=16384,
                system=system_prompt,
                tools=TOOLS_ANTHROPIC,
                messages=messages,
            )
        except Exception as e:
            print(f"[turn {turn}] API error: {e}", file=sys.stderr)
            if "rate" in str(e).lower() or "overloaded" in str(e).lower():
                time.sleep(30)
                continue
            raise

        total_input += resp.usage.input_tokens
        total_output += resp.usage.output_tokens
        if hasattr(resp.usage, 'cache_read_input_tokens'):
            total_cache_read += resp.usage.cache_read_input_tokens or 0
        if hasattr(resp.usage, 'cache_creation_input_tokens'):
            total_cache_create += resp.usage.cache_creation_input_tokens or 0

        # Process response
        assistant_content = resp.content
        messages.append({"role": "assistant", "content": assistant_content})

        if resp.stop_reason == "end_turn":
            break

        # Process tool calls
        tool_results = []
        done = False
        for block in assistant_content:
            if block.type == "tool_use":
                print(f"  [turn {turn}] tool: {block.name}({json.dumps({k: v[:80] + '...' if isinstance(v, str) and len(v) > 80 else v for k, v in block.input.items()}) if block.input else ''})", file=sys.stderr)
                result = execute_tool(block.name, block.input, workdir)
                if result == "DONE":
                    done = True
                    result = "Implementation complete. Good work!"
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result,
                })

        if tool_results:
            messages.append({"role": "user", "content": tool_results})

        if done:
            break

    return {
        "input_tokens": total_input,
        "output_tokens": total_output,
        "cache_read_tokens": total_cache_read,
        "cache_creation_tokens": total_cache_create,
        "total_tokens": total_input + total_output,
        "turns": turn,
    }


def run_openai(model_id: str, language: str, workdir: str, max_turns: int = 200):
    import openai

    provider = get_provider(model_id)
    resolved = resolve_model(model_id)

    if provider == "openrouter":
        client = openai.OpenAI(
            api_key=OPENROUTER_API_KEY,
            base_url="https://openrouter.ai/api/v1",
        )
    else:
        client = openai.OpenAI(api_key=OPENAI_API_KEY)

    system_prompt = f"""You are a coding agent implementing a REST API server. You have tools to write files, execute bash commands, read files, and list files.

CRITICAL REQUIREMENTS:
- {LANGUAGE_INSTRUCTIONS[language]}
- Create a `run.sh` at the project root. It MUST accept `--port PORT` as arguments and start the server on that port.
- run.sh should be executable (chmod +x).
- The server must bind to 0.0.0.0:PORT.
- Implement ALL endpoints from the specification - do not skip any.
- When done, call the `done` tool.

Work in the current directory. You can install packages as needed."""

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": f"Implement this server specification in {language}:\n\n{SPEC}"},
    ]

    total_input = 0
    total_output = 0
    turn = 0

    while turn < max_turns:
        turn += 1
        try:
            kwargs = dict(
                model=resolved,
                messages=messages,
                tools=TOOLS_OPENAI,
                max_tokens=16384,
            )
            # Reasoning models and GPT-5+ use max_completion_tokens
            if "o3" in resolved or "o1" in resolved or "o4" in resolved or "gpt-5" in resolved:
                kwargs.pop("max_tokens", None)
                kwargs["max_completion_tokens"] = 16384
            resp = client.chat.completions.create(**kwargs)
        except Exception as e:
            err_str = str(e).lower()
            print(f"[turn {turn}] API error: {e}", file=sys.stderr)
            if "rate" in err_str or "429" in str(e) or "overloaded" in err_str or "503" in str(e):
                time.sleep(30)
                continue
            if "401" in str(e) or "auth" in err_str:
                time.sleep(10)
                continue
            raise

        usage = resp.usage
        if usage:
            total_input += usage.prompt_tokens or 0
            total_output += usage.completion_tokens or 0

        choice = resp.choices[0]
        msg = choice.message
        messages.append(msg)

        if choice.finish_reason == "stop" or not msg.tool_calls:
            break

        # Process tool calls
        done = False
        for tc in msg.tool_calls:
            fname = tc.function.name
            try:
                fargs = json.loads(tc.function.arguments)
            except (json.JSONDecodeError, TypeError):
                fargs = {}
            try:
                truncated = {k: (v[:80] + '...' if isinstance(v, str) and len(v) > 80 else v) for k, v in fargs.items()} if fargs else {}
                print(f"  [turn {turn}] tool: {fname}({json.dumps(truncated)})", file=sys.stderr)
            except Exception:
                print(f"  [turn {turn}] tool: {fname}(...)", file=sys.stderr)
            try:
                result = execute_tool(fname, fargs, workdir)
            except Exception as e:
                result = f"[tool error: {e}]"
            if result == "DONE":
                done = True
                result = "Implementation complete. Good work!"
            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": result,
            })

        if done:
            break

    return {
        "input_tokens": total_input,
        "output_tokens": total_output,
        "cache_read_tokens": 0,
        "cache_creation_tokens": 0,
        "total_tokens": total_input + total_output,
        "turns": turn,
    }


def run_agent(model_id: str, language: str, workdir: str, max_turns: int = 200):
    os.makedirs(workdir, exist_ok=True)
    # All models use the OpenAI-compatible API (direct OpenAI or OpenRouter)
    return run_openai(model_id, language, workdir, max_turns)


def main():
    parser = argparse.ArgumentParser(description="Run coding agent experiment")
    parser.add_argument("--model", required=True, help="Model ID (e.g., sonnet, gpt-4o-mini, openrouter/qwen/...)")
    parser.add_argument("--language", required=True, choices=list(LANGUAGE_INSTRUCTIONS.keys()))
    parser.add_argument("--workdir", required=True, help="Working directory for the experiment")
    parser.add_argument("--max-turns", type=int, default=200, help="Maximum agent turns")
    parser.add_argument("--output", required=True, help="Output JSON file for results")
    args = parser.parse_args()

    print(f"Starting agent: model={args.model} language={args.language} workdir={args.workdir}", file=sys.stderr)
    start = time.time()

    try:
        result = run_agent(args.model, args.language, args.workdir, args.max_turns)
        result["status"] = "completed"
    except Exception as e:
        result = {
            "status": "error",
            "error": str(e),
            "traceback": traceback.format_exc(),
            "input_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0,
            "turns": 0,
        }

    result["model"] = args.model
    result["language"] = args.language
    result["duration_seconds"] = time.time() - start

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(result, f, indent=2)

    print(f"Done: {result['status']} tokens={result.get('total_tokens', 0)} turns={result.get('turns', 0)} duration={result['duration_seconds']:.0f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
