# Incus MCP server

The remote build loop lives in Incus containers on other machines. An MCP
server lets the agent drive those containers over the Incus REST API instead
of shelling out to `incus`, so the container can be created, published,
re-launched somewhere else and driven through a build without leaving the
session.

Server: [`nikitatsym/incus-mcp`](https://github.com/nikitatsym/incus-mcp),
pinned at commit `b6a9afe53b988ff800ea918b7c23a017f6130717` (MIT).

It was chosen over the two other Incus MCP servers on offer because it is the
only one that covers the whole container lifecycle the build loop needs:
publish an image from an instance, launch a new instance from that image, exec
inside it, push and pull files, snapshot it, read its logs.
`fredmj/incus-mcp-server` is read-only by default and safer, but has no image,
file or snapshot operations; `nikkomiu/incus-mcp` wraps the CLI and handles
several remotes in one process, but cannot publish an image or transfer files,
and needs a Bun runtime.

## Install

No package is layered on the host. The server runs from a virtualenv under
`$HOME/.local/share`, with a launcher on `PATH`:

```sh
PIN=b6a9afe53b988ff800ea918b7c23a017f6130717
python3 -m venv "$HOME/.local/share/incus-mcp/venv"
"$HOME/.local/share/incus-mcp/venv/bin/pip" install \
    "git+https://github.com/nikitatsym/incus-mcp@$PIN" 'httpx==0.27.2'
install -m755 /dev/stdin "$HOME/.local/bin/incus-mcp" <<'EOF'
#!/usr/bin/env bash
exec "$HOME/.local/share/incus-mcp/venv/bin/incus-mcp" "$@"
EOF
```

`httpx==0.27.2` is not cosmetic. httpx 0.28 ignores the `cert=` argument when
`verify=` is a CA file path, so the client certificate is never sent and Incus
answers every request as an untrusted caller. Keep httpx below 0.28 until the
server passes an `ssl.SSLContext` instead.

## Registration

One server process speaks to one Incus endpoint, so each remote is registered
separately, at **user scope** — the build loop is driven from several worktrees
of this repository, and a user-scope server is available in all of them without
committing anything machine-specific here.

```sh
claude mcp add -s user "incus-<remote>" \
  -e "INCUS_URL=https://<remote-host>:8443" \
  -e "INCUS_CLIENT_CERT=$HOME/.config/incus/client.crt" \
  -e "INCUS_CLIENT_KEY=$HOME/.config/incus/client.key" \
  -e "INCUS_CA_CERT=$HOME/.config/incus/servercerts/<remote>.crt" \
  -e "INCUS_VERIFY_SSL=true" \
  -- "$HOME/.local/bin/incus-mcp"
```

It reuses the client certificate the `incus` CLI already has trusted on the
remote, and pins the remote's own certificate as the CA, so TLS verification
stays on. Pinning only works when the URL host matches a name in the server
certificate (the short host name, not a search-domain-qualified one); with a
name the certificate does not carry, verification fails and the only way
through would be `INCUS_VERIFY_SSL=false`, which gives up the pinning the CLI
does — don't.

A remote whose Incus daemon is not running, including a `local` remote on a
workstation that only acts as a client, has nothing to register: this server
speaks HTTPS only and has no unix-socket transport.

## Tools

Five tools, each a group dispatching by operation name. Call a group with
`operation="help"` (optionally `params={"search": "image"}`) to list its
operations, or `operation="schema", params={"op": "CreateInstance"}` for one
operation's JSON Schema.

| Group | Use in the build loop |
| --- | --- |
| `incus_read` | `ListInstances`, `GetInstanceState`, `ListImages`, `ListImageAliases`, `GetInstanceFile` (pull), `ListExecOutputs` / `GetExecOutput` (a command's stdout and stderr), `ListInstanceLogs` / `GetInstanceLog`, `ListSnapshots`, `WaitOperation` |
| `incus_write` | `CreateInstance` (from an image, an alias, or a same-host `copy`), `CreateImage` (publish from an instance or snapshot), `CreateImageAlias`, `UploadInstanceFile` (push), `CreateSnapshot`, `RenameInstance` |
| `incus_execute` | `StartInstance`, `StopInstance`, `RestartInstance`, `ExecInstance` |
| `incus_delete` | `DeleteInstance`, `DeleteImage`, `DeleteImageAlias`, `DeleteSnapshot`, and 30 more |
| `incus_admin` | server configuration and warnings |

Writes are asynchronous: they return an operation object, and `WaitOperation`
with its `id` blocks until it finishes. `ExecInstance` is not interactive — it
runs a command with output recording on, and the output is read afterwards with
`ListExecOutputs` and `GetExecOutput`.

### What it does not do

- **Copying or moving an instance between remotes.** There is no migration
  operation, and `CreateInstance` with a `copy` source only reaches instances
  on the same server. `incus copy <remote>:<name> <remote>:` and
  `incus move ...` stay manual CLI steps. Publishing an image on one host and
  launching from it on another is the supported path through the server, and
  works.
- **Restoring a snapshot.** Snapshots can be created, listed, renamed and
  deleted, but `incus restore <name> <snapshot>` has no operation.
- **Interactive shells, `incus console`, terminal attach.**

### Dangerous tools

The server offers no read-only mode and no way to disable a group, so treat
these as the sharp edges:

- `incus_delete` — every operation destroys something, irreversibly, with no
  confirmation argument: `DeleteInstance` (a running instance too, with
  `force`), `DeleteImage`, `DeleteSnapshot`, `DeleteVolume`, `DeleteProject`,
  `DeleteStoragePool`, `DeleteCertificate` (which can lock this machine out of
  the remote).
- `incus_admin` — `UpdateServerConfig` changes the daemon's own configuration
  for every client of that host.
- `incus_execute` — `ExecInstance` runs arbitrary commands as root inside a
  container; `StopInstance` with `force` kills a build in progress.
- `incus_write` — `UploadInstanceFile` overwrites any path in a container, and
  `RenameInstance` can break another session's references.

Every registered server is scoped to one remote, so a mistaken call can only
reach the host that server points at. Approve `incus_delete` and `incus_admin`
calls by hand.

## Verified

Against a live remote, through the server (a throwaway container, since the
build container was in use, then removed together with its image):

create instance from a cached image → start → exec and read stdout → push a
file → pull it back → snapshot → stop → publish an image from the instance →
alias it → list images and aliases → create a new instance from the published
alias → start it → exec in it, reading back the file that was pushed into the
original → same-host copy → delete both instances, the alias and the image.
Instance listings and state reads were also verified against a second remote.
