#!/usr/bin/env python3
"""
Coding agent with full MCP language server integration.
Uses isaacphi/mcp-language-server as a sidecar process providing:
  - diagnostics: compilation errors/warnings
  - hover: type info and documentation
  - definition: source code of definitions
"""
import argparse
import json
import os
import subprocess
import sys
import time
import threading
import traceback
import select

SPEC_PATH = os.environ.get("SPEC_PATH", os.path.join(os.path.dirname(__file__), "..", "eval", "spec.md"))
SPEC = open(SPEC_PATH).read()

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")

MCP_BIN = os.environ.get("MCP_BIN", "mcp-language-server")

LSP_CONFIGS = {
    "python": ("pyright-langserver", ["--stdio"]),
    "python-mypy": ("pyright-langserver", ["--stdio"]),
    "javascript": ("typescript-language-server", ["--stdio"]),
    "typescript": ("typescript-language-server", ["--stdio"]),
    "rust": ("rust-analyzer", []),
    "go": ("gopls", ["serve"]),
    "c": ("clangd", ["--log=error"]),
    "java": ("/opt/jdtls/bin/jdtls", []),
    "scala": ("metals", []),
    "haskell": ("haskell-language-server-9.10.3", ["--lsp"]),
}

DIAG_WAIT = {
    "python": 5, "python-mypy": 5,
    "javascript": 5, "typescript": 5,
    "rust": 10, "go": 5, "c": 5,
    "java": 15, "scala": 75, "haskell": 60,
}

LANGUAGE_INSTRUCTIONS = {
    "c": "You MUST implement this entirely in C. Use standard POSIX APIs. Compile with gcc. Create a run.sh that compiles and runs the binary. You may use any libraries available (install with apt if needed).",
    "python": "You MUST implement this entirely in Python 3. Use only the standard library or install packages with pip. Create a run.sh that runs the server with python3.",
    "javascript": "You MUST implement this entirely in JavaScript (Node.js). Use only built-in modules or install packages with npm. Create a run.sh that runs the server with node.",
    "python-mypy": "You MUST implement this entirely in Python 3 with FULL strict mypy type annotations. ALL code must pass `mypy --strict` with zero errors. Run mypy to verify before finishing. Create a run.sh that runs the server with python3.",
    "typescript": "You MUST implement this entirely in TypeScript. Compile with tsc or use tsx. Create a run.sh that compiles (if needed) and runs the server.",
    "java": "You MUST implement this entirely in Java. Use the standard library or download dependencies. Create a run.sh that compiles and runs the server with javac/java.",
    "scala": "You MUST implement this entirely in Scala. You can use scala-cli (install it if needed: curl -sSLf https://scala-cli.virtuslab.org/get | bash). Create a run.sh that builds and runs the server.",
    "rust": "You MUST implement this entirely in Rust. Use cargo to manage the project. Create a run.sh that builds with cargo and runs the resulting binary.",
    "go": "You MUST implement this entirely in Go. Use go modules for dependency management. Create a run.sh that builds with go build and runs the resulting binary.",
    "haskell": "You MUST implement this entirely in Haskell. Use cabal for dependency management. Create a run.sh that builds with cabal and runs the resulting binary. You may use any Hackage libraries (e.g. warp, scotty, servant, aeson). Install with cabal install if needed.",
}


class MCPSidecar:
    """Manages a persistent mcp-language-server process."""

    def __init__(self, workspace, language):
        self.workspace = workspace
        self.language = language
        self.proc = None
        self.req_id = 0
        self.buf = b""
        self.alive = False
        self.started = False

    def start(self):
        config = LSP_CONFIGS.get(self.language)
        if not config:
            return False

        lsp_cmd, lsp_args = config
        env = os.environ.copy()
        env["PATH"] = ":".join([
            os.path.expanduser("~/go/bin"),
            os.path.expanduser("~/.cargo/bin"),
            os.path.expanduser("~/.ghcup/bin"),
            os.path.expanduser("~/.local/share/coursier/bin"),
            "/usr/local/bin", "/usr/bin", "/bin",
            env.get("PATH", ""),
        ])
        env["LSP_DIAG_WAIT_SECONDS"] = str(DIAG_WAIT.get(self.language, 5))

        if self.language == "scala":
            bsp_dir = os.path.join(self.workspace, ".bsp")
            if not os.path.isdir(bsp_dir):
                subprocess.run(
                    ["scala-cli", "setup-ide", "--power", "."],
                    cwd=self.workspace, env=env, capture_output=True, timeout=60
                )

        cmd = [MCP_BIN, "--workspace", self.workspace, "--lsp", lsp_cmd]
        if lsp_args:
            cmd.append("--")
            cmd.extend(lsp_args)

        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=env
            )
            threading.Thread(target=self._drain_stderr, daemon=True).start()
            self.alive = True

            resp = self._call("initialize", {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "agent", "version": "1.0"}
            }, timeout=30)
            if resp and "result" in resp:
                self._notify("notifications/initialized")
                time.sleep(1)
                self.started = True
                return True
        except Exception as e:
            print(f"  [mcp] failed to start: {e}", file=sys.stderr)
        return False

    def _drain_stderr(self):
        try:
            while self.alive:
                line = self.proc.stderr.readline()
                if not line:
                    break
        except:
            pass

    def _send(self, method, params=None, is_notification=False):
        if not self.alive:
            return None
        if is_notification:
            msg = {"jsonrpc": "2.0", "method": method}
        else:
            self.req_id += 1
            msg = {"jsonrpc": "2.0", "id": self.req_id, "method": method}
        if params is not None:
            msg["params"] = params
        try:
            line = json.dumps(msg) + "\n"
            self.proc.stdin.write(line.encode())
            self.proc.stdin.flush()
        except:
            self.alive = False
        return self.req_id if not is_notification else None

    def _notify(self, method, params=None):
        self._send(method, params, is_notification=True)

    def _recv(self, expected_id, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = deadline - time.time()
            ready, _, _ = select.select([self.proc.stdout], [], [], min(remaining, 0.5))
            if ready:
                try:
                    chunk = os.read(self.proc.stdout.fileno(), 8192)
                    if not chunk:
                        self.alive = False
                        return None
                    self.buf += chunk
                except:
                    self.alive = False
                    return None
                while b"\n" in self.buf:
                    line, self.buf = self.buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                        if msg.get("id") == expected_id:
                            return msg
                    except:
                        pass
        return None

    def _call(self, method, params=None, timeout=90):
        rid = self._send(method, params)
        if rid is None:
            return None
        return self._recv(rid, timeout=timeout)

    def call_tool(self, tool_name, arguments, timeout=None):
        if not self.alive or not self.started:
            return "[LSP not available]"
        if timeout is None:
            timeout = DIAG_WAIT.get(self.language, 5) + 15
        resp = self._call("tools/call", {
            "name": tool_name,
            "arguments": arguments,
        }, timeout=timeout)
        if resp and "result" in resp:
            content = resp["result"].get("content", [])
            if content:
                return content[0].get("text", "(empty)")
            return "(no content)"
        elif resp and "error" in resp:
            return f"[LSP error: {resp['error'].get('message', 'unknown')}]"
        return "[LSP timeout]"

    def stop(self):
        self.alive = False
        if self.proc:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except:
                try:
                    self.proc.kill()
                except:
                    pass


TOOLS_OPENAI = [
    {"type": "function", "function": {
        "name": "write_file",
        "description": "Write content to a file (creates directories as needed)",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "File path relative to working directory"},
            "content": {"type": "string", "description": "File content to write"},
        }, "required": ["path", "content"]},
    }},
    {"type": "function", "function": {
        "name": "execute",
        "description": "Execute a bash command and return stdout+stderr. Timeout: 120s.",
        "parameters": {"type": "object", "properties": {
            "command": {"type": "string", "description": "Bash command to run"},
        }, "required": ["command"]},
    }},
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read a file's content",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "File path relative to working directory"},
        }, "required": ["path"]},
    }},
    {"type": "function", "function": {
        "name": "list_files",
        "description": "List files in a directory recursively",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Directory path (default: current dir)"},
        }},
    }},
    {"type": "function", "function": {
        "name": "diagnostics",
        "description": "Get compilation errors and warnings for a source file from the language server. Returns error messages with line numbers. Use after writing code to check for type errors, missing imports, or syntax issues.",
        "parameters": {"type": "object", "properties": {
            "filePath": {"type": "string", "description": "Relative path to the source file to check"},
        }, "required": ["filePath"]},
    }},
    {"type": "function", "function": {
        "name": "hover",
        "description": "Get type information and documentation for a symbol at a specific position.",
        "parameters": {"type": "object", "properties": {
            "filePath": {"type": "string", "description": "Relative path to the source file"},
            "line": {"type": "number", "description": "Line number (1-indexed)"},
            "column": {"type": "number", "description": "Column number (1-indexed)"},
        }, "required": ["filePath", "line", "column"]},
    }},
    {"type": "function", "function": {
        "name": "definition",
        "description": "Read the source code definition of a symbol by name.",
        "parameters": {"type": "object", "properties": {
            "symbolName": {"type": "string", "description": "The name of the symbol to find (e.g. 'MyFunction', 'MyType.method')"},
        }, "required": ["symbolName"]},
    }},
    {"type": "function", "function": {
        "name": "done",
        "description": "Signal that you have finished implementing the server. Call this when your implementation is complete and run.sh is ready.",
        "parameters": {"type": "object", "properties": {
            "summary": {"type": "string", "description": "Brief summary of what you built"},
        }, "required": ["summary"]},
    }},
]


def execute_tool(name, args, workdir, mcp_sidecar=None):
    if name == "write_file":
        path = os.path.join(workdir, args["path"])
        os.makedirs(os.path.dirname(path) or workdir, exist_ok=True)
        with open(path, "w") as f:
            f.write(args["content"])
        return f"File written: {args['path']} ({len(args['content'])} bytes)"

    elif name == "execute":
        try:
            # Wrap command with memory limit (1.5GB) to prevent OOM
            wrapped = f"ulimit -v 1572864 2>/dev/null; {args['command']}"
            result = subprocess.run(
                wrapped, shell=True, capture_output=True, text=True,
                timeout=120, cwd=workdir,
                env={**os.environ, "HOME": "/root",
                     "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin") +
                     ":/root/.local/bin:/root/.local/share/coursier/bin:/root/.cargo/bin:/root/.elan/bin:/root/.ghcup/bin"},
            )
            output = ""
            if result.stdout:
                output += result.stdout
            if result.stderr:
                output += ("\n" if output else "") + result.stderr
            if not output:
                output = "(no output)"
            output += f"\n[exit code: {result.returncode}]"
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
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in
                           ("node_modules", "target", "__pycache__", ".git", "dist-newstyle", ".metals", ".bloop")]
                for fn in filenames:
                    rel = os.path.relpath(os.path.join(root, fn), workdir)
                    files.append(rel)
            return "\n".join(sorted(files)[:200]) or "(empty)"
        except Exception as e:
            return f"[error: {e}]"

    elif name in ("diagnostics", "hover", "definition", "references"):
        if not mcp_sidecar or not mcp_sidecar.started:
            return "[LSP not available]"
        return mcp_sidecar.call_tool(name, args)

    elif name == "done":
        return "DONE"

    return f"[unknown tool: {name}]"


def get_provider(model_id):
    if model_id.startswith("openrouter/"):
        return "openrouter"
    return "openai"


def resolve_model(model_id):
    if model_id.startswith("openrouter/"):
        return model_id[len("openrouter/"):]
    return model_id


def run_openai(model_id, language, workdir, max_turns=200, mcp_sidecar=None):
    import openai

    provider = get_provider(model_id)
    resolved = resolve_model(model_id)

    if provider == "openrouter":
        client = openai.OpenAI(api_key=OPENROUTER_API_KEY, base_url="https://openrouter.ai/api/v1")
    else:
        client = openai.OpenAI(api_key=OPENAI_API_KEY)

    system_prompt = f"""You are a coding agent implementing a REST API server. You have tools to write files, execute bash commands, read files, and list files.

You also have language server tools that provide IDE-like intelligence:
- `diagnostics`: Check a file for compilation errors and warnings (use after writing code)
- `hover`: Get type information for a symbol at a position
- `definition`: Read the source code of a symbol's definition

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
            kwargs = dict(model=resolved, messages=messages, tools=TOOLS_OPENAI, max_tokens=16384)
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

        done = False
        for tc in msg.tool_calls:
            fname = tc.function.name
            try:
                fargs = json.loads(tc.function.arguments)
            except (json.JSONDecodeError, TypeError):
                fargs = {}
            try:
                truncated = {k: (v[:80] + "..." if isinstance(v, str) and len(v) > 80 else v) for k, v in fargs.items()} if fargs else {}
                print(f"  [turn {turn}] tool: {fname}({json.dumps(truncated)})", file=sys.stderr)
            except Exception:
                print(f"  [turn {turn}] tool: {fname}(...)", file=sys.stderr)
            try:
                result = execute_tool(fname, fargs, workdir, mcp_sidecar)
            except Exception as e:
                result = f"[tool error: {e}]"
            if result == "DONE":
                done = True
                result = "Implementation complete. Good work!"
            messages.append({"role": "tool", "tool_call_id": tc.id, "content": result})

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


def run_agent(model_id, language, workdir, max_turns=200):
    os.makedirs(workdir, exist_ok=True)

    mcp = MCPSidecar(workdir, language)
    started = mcp.start()
    if started:
        print(f"  [mcp] LSP sidecar started for {language}", file=sys.stderr)
    else:
        print(f"  [mcp] LSP sidecar NOT available for {language}", file=sys.stderr)

    try:
        return run_openai(model_id, language, workdir, max_turns, mcp if started else None)
    finally:
        mcp.stop()


def main():
    parser = argparse.ArgumentParser(description="Run coding agent with MCP LSP")
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", required=True, choices=list(LANGUAGE_INSTRUCTIONS.keys()))
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--max-turns", type=int, default=200)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    print(f"Starting agent: model={args.model} language={args.language} workdir={args.workdir}", file=sys.stderr)
    start = time.time()

    try:
        result = run_agent(args.model, args.language, args.workdir, args.max_turns)
        result["status"] = "completed"
    except Exception as e:
        result = {
            "status": "error", "error": str(e), "traceback": traceback.format_exc(),
            "input_tokens": 0, "output_tokens": 0, "total_tokens": 0, "turns": 0,
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
