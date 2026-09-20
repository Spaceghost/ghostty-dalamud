# Jobs

A **job** is a process `ghostty-agent` runs on pipes instead of a PTY. The
client sends bytes to its stdin and gets its stdout and stderr back, tagged
and untouched — no terminal emulation, no screen, no replay of escape
sequences. That is what a program whose output is *parsed* needs, and the
first one is a Claude Code session in `stream-json` mode: line-framed JSON
events the game renders natively rather than draws as text.

```
 FFXIV (XivDesktop, C#)                            ghostty-agent (any host)
 ┌───────────────────────────────┐   TCP     ┌──────────────────────────────────┐
 │ parses the JSON events        │  JOPEN →  │ agent/jobs.nelua                 │
 │ renders them as game UI       │ ← JOUT    │  pipes, flow control, replay     │
 │                               │  JDATA →  │ agent/job_posix.nelua (fork/exec)│
 │                               │ ← JEXIT   │ agent/claude.nelua (the argv)    │
 └───────────────────────────────┘           └──────────────────────────────────┘
```

Status: this is the required design. What has been observed working is under
"Verified" at the end of this file; everything else is not a claim.

## Safety

**A job runs as the user running the agent, with that user's full access to
the machine.** Nothing sandboxes it: no container, no separate uid, no
filesystem restriction. It is exactly as privileged as the shells the agent
already opens for PTY sessions, and the agent's token is the only gate —
anyone who can authenticate can start any process. Do not expose the agent's
port beyond loopback or a trusted link.

The agent never logs a job's bytes. It logs only that a job started, what its
command line was, and how it ended; `JOUT` payloads are passed through and
dropped, never written to the log at any level.

## Protocol (version 4, additive)

Agents greet with `ghostty-agent 4 <nonce>`. Clients send job frames only to
version 4 agents. All integers are little endian. `jid` is a job id (u32) in
its own number space — never a PTY session id and never a window `sid`.

client → agent

| type | name | payload |
|---|---|---|
| 29 | JOPEN | req u32, flags u8, argv entries NUL separated, an empty entry, then env entries NUL separated |
| 30 | JDATA | jid, bytes for the job's stdin. **No bytes: close its stdin** (the job sees EOF) |
| 31 | JCLOSE | jid — kill the job (SIGKILL); a kept job stops being kept |
| 32 | JSIG | jid, sig u8 — send that signal to the job's process group |
| 33 | JATTACH | jid — take a kept job over on this connection, with its replay |

agent → client

| type | name | payload |
|---|---|---|
| 34 | JOPENED | req u32, jid u32, pid u32; **jid 0: the open failed** and the rest of the payload is the reason in UTF-8 |
| 35 | JOUT | jid, stream u8 (1 stdout, 2 stderr), bytes |
| 36 | JEXIT | jid, status i32 (128 + signal when the job was killed; `0xFFFFFFFF` for a jid the agent does not have) |

`JOPENED` answers a `JOPEN` by the client-chosen `req`, like `WOPENED`. A
failed open still answers, so a client can match answers to requests in
order.

`JOPEN`'s payload after `req` and `flags` has exactly the shape of `OPEN`'s
after cols/rows: argv entries, an empty entry, env entries, all NUL
separated. An `env` entry `PWD=` or `CWD=` sets the job's working directory
instead of an environment variable, as it does for a PTY session.

`JEXIT` is sent only after both pipes reached EOF, so nothing the job wrote
is lost behind its exit. If something the job started keeps the pipes open
after the job itself is gone, the agent stops waiting two seconds later and
sends `JEXIT` anyway.

### Flags

| bit | name | meaning |
|---|---|---|
| 0 | keep | the job outlives the connection that opened it |

A job belongs to the connection that opened it: no other connection can see,
feed or signal it, and it is killed when that connection goes — unless
`keep` is set. A kept job keeps running with nobody attached, its output
going into a 256 KiB replay ring, and `JATTACH` hands it to a new connection
and replays that ring as `JOUT` frames in the order they were read (the same
idea as `ATTACH` replaying a session's screen, but tagged per stream rather
than fed to a terminal). `JATTACH` of a jid the agent does not have answers
`JEXIT` with status `0xFFFFFFFF` rather than an error.

A kept job that exits while detached is held for a later `JATTACH`; only the
16 newest such jobs are kept, and the agent kills everything it is running
when it stops. A job without `keep` that exits, or any job whose `JEXIT` has
been delivered, is forgotten.

### Flow control

Like the window streams: while the owning connection's output queue is over
1 MiB the agent does not read that job's pipes at all, so the process blocks
on its own writes instead of the agent buffering without bound. Nothing is
dropped — reading resumes when the client catches up. Stdin the pipe cannot
take is queued (up to 8 MiB) and written as the pipe drains, so a large
paste or a long prompt arrives whole and in order.

## Who opens jobs

The first client of this in the plugin is the **`/ask` panel**
(`core/app/ask.nelua`, `lua/ask.lua`): it runs `almanac ask --stream-json`,
whose protocol is one JSON object per line, and those lines must arrive
exactly as the program wrote them. A PTY would not do — a pseudo console on a
Windows agent wraps a long line into console rows and inserts CR/LF — so the
panel asks for a job instead.

The client side is in `core/agent_client.nelua` (`jobs_ok`, `jopen`, `jdata`,
`jclose`, and the `JOPENED`/`JOUT`/`JEXIT` events) and `core/session.nelua`
(a session with `job = true`: `agent_id` is its jid, it is never resized,
never detached and never kept). Two rules keep it safe for older agents:

* a job is only asked for when the agent greets with version 4 or later;
  otherwise the session opens as a PTY, exactly as before jobs existed;
* a `JOPENED` with jid 0 — the agent has no job runner, or refuses this
  command — makes the session ask again as a PTY rather than fail. The
  panel then works even against today's Windows agent, at the cost of the
  console's reflow.

Session ids and job ids are separate number spaces, so the core matches
`JOUT`/`JEXIT` only against sessions that are jobs, and `JOPENED` by the `req`
its `JOPEN` carried rather than by arrival order.

## The Claude runner

`agent/claude.nelua` builds the command line, so XivDesktop hardcodes no
flags. Open a job with argv `["@claude", "<json opts>"]` and the agent
expands it:

```
claude -p --output-format stream-json --input-format stream-json \
       --include-partial-messages --verbose
```

Those five flags are the base of every expansion. Options are a flat JSON
object as argv[1] (an empty or missing argv[1] means "all defaults"):

| key | type | effect |
|---|---|---|
| `claude` | string | the executable, default `claude` |
| `model` | string | `--model <v>` |
| `permission_prompts` | string | `--permission-prompts <v>` (`host` or `none`) |
| `permission_mode` | string | `--permission-mode <v>` |
| `mcp_config` | array | `--mcp-config <v…>` |
| `add_dir` | array | `--add-dir <v…>` |
| `session_id` | string | `--session-id <v>` |
| `resume` | string | `--resume <session-id>` |
| `input_format` | string | `text` drops `--input-format stream-json` |
| `partial` | bool | false drops `--include-partial-messages` |
| `args` | array | appended verbatim |
| `prompt` | string | the positional prompt (usually empty: stdin carries the turns) |
| `cwd` | string | the job's working directory |

An unknown key is refused with `JOPENED` jid 0 and the reason, so a typo
never silently starts a different session.

### About `--permission-prompt-tool`

The installed CLI (`claude --version` → **2.1.278**) has **no
`--permission-prompt-tool` flag**. `claude --help` lists
`--permission-prompts <target>` instead — `host` (the SDK host or a
permission prompt tool) or `none` — and that is what `permission_prompts`
emits. Every other flag above was taken from that same `--help` output.
`--verbose` and `--include-partial-messages` are both listed and both apply
only together with `--print` and `--output-format stream-json`.

### Driving a session

* stdin takes one JSON object per line (`--input-format stream-json`), the
  user turns.
* `JDATA` with no bytes closes stdin, which is how a turn stream ends.
* stdout is one JSON object per line. The agent passes the bytes through
  untouched and does not care where the lines fall inside a `JOUT`: a client
  must buffer and split on `\n` itself, since a frame can carry a partial
  line or several lines.

### Event shapes

From a real run on this host —
`claude -p --output-format stream-json --include-partial-messages --verbose 'say hi'`
(16 lines, 2026-09-19, CLI 2.1.278). Every line has `type` and most carry
`uuid` and `session_id`:

| `type` | `subtype` / `event.type` | what it is |
|---|---|---|
| `system` | `hook_started`, `hook_response` | a `SessionStart` hook running; `hook_response` carries its `output`, `stdout`, `stderr`, `exit_code` |
| `system` | `init` | the session: `session_id`, `model`, `cwd`, `tools`, `mcp_servers`, `agents`, `skills`, `slash_commands`, `permissionMode`, `claude_code_version`, … |
| `system` | `status` | a short status string |
| `stream_event` | `message_start` | the Anthropic streaming event, verbatim, under `event` (with `parent_tool_use_id`, and `ttft_ms` on the first one) |
| `stream_event` | `content_block_start` | ” |
| `stream_event` | `content_block_delta` | the text arriving piece by piece (4 of them in this run) |
| `stream_event` | `content_block_stop` | ” |
| `stream_event` | `message_delta` | ” |
| `stream_event` | `message_stop` | ” |
| `assistant` | – | the finished message: `message` is a whole Anthropic message (`model`, `role`, `content`, `usage`), plus `request_id` |
| `rate_limit_event` | – | `rate_limit_info` |
| `result` | `success` | the end: `result` (the final text), `is_error`, `num_turns`, `duration_ms`, `duration_api_ms`, `total_cost_usd`, `usage`, `modelUsage`, `permission_denials`, `stop_reason`, `session_id` |

`stream_event` lines only appear with `--include-partial-messages`; a client
that wants whole messages can ignore them and use `assistant` and `result`.
`result.subtype` is `success` here; other subtypes exist for errors. A client
that does not know a `type` should skip the line rather than fail — new ones
are added over time.

## Where the code is

| file | what |
|---|---|
| `core/protocol.nelua` | the frame numbers, the flags, `PROTO_VERSION` 4 |
| `agent/jobs.nelua` | the generic half: ownership, replay, flow control, the frames |
| `agent/job_posix.nelua` | pipe/fork/exec, non-blocking, close-on-exec parent ends, `waitpid` |
| `agent/job_windows.nelua` | a stub: every `JOPEN` is refused with "jobs are not implemented on Windows" |
| `agent/claude.nelua` | the `@claude` options and command line, pure (no processes) |
| `tests/test_jobs.nelua` | the tests below |

## Verified

Observed by `tests/test_jobs.nelua` against a real `ghostty-agent` on a
loopback port (`tests/run.sh`):

* `/bin/cat`: `JOPENED` with a jid and pid, stdin through `JDATA`, the same
  bytes back on stdout, `JDATA` with no bytes closes stdin, `JEXIT` 0.
* stdout and stderr arrive tagged apart, with the shell's exit status 7.
* `JCLOSE` kills a sleeping job: `JEXIT` 137 (128 + SIGKILL).
* a job without `keep` is gone from `/proc` once its connection closes.
* `keep` + `JATTACH` on a new connection: the whole output replays in order,
  including what was written while nobody was attached.
* `JATTACH` of an unknown jid: `JEXIT` `0xFFFFFFFF`, no `ERR`.
* an empty argv is refused with `JOPENED` jid 0 and a reason; a command that
  does not exist opens and exits 127.
* `@claude` expands to the flags above (checked against `/bin/echo`), and an
  unknown option key is refused with the reason.
* 8 MiB of output while the client stops reading: the agent's RSS stays under
  24 MiB, and every one of the 8388608 bytes arrives once it reads again.

Not verified: a real `claude` session driven through a job end to end, and
anything on Windows or macOS.
