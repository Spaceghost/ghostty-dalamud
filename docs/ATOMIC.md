# ghostty-agent on an atomic desktop

Silverblue, Kinoite, Sway Atomic and Bazzite keep the system image read-only.
You could layer the agent's RPM with `rpm-ostree install`, but then every
update carries a layer. Run the agent as a container instead: nothing is
layered, it updates on its own schedule, and it starts with your session as a
Podman quadlet. The four desktops use the same steps.

## What you get

The same agent as the Fedora 44 RPM, because the image is built from that
package. It has the Wayland compositor backend, so apps become screens in the
game, and it has netlab. It runs as you, with your home directory at the same
path. It listens on your desktop's own `127.0.0.1:7777` and writes its token to
`~/.config/ghostty-agent/token`, which is where the plugin looks.

The difference from the RPM: your shells run inside the container. They see
your files, but the programs available are the image's. The image is Fedora,
so `dnf` works in it. To add tools permanently, see *Your own tools* below.

## Install

1. Build the image. It takes a few minutes, and all you need is `git` and
   Podman, which every atomic desktop already has:

   ```sh
   git clone https://github.com/Spaceghost/ghostty-dalamud
   cd ghostty-dalamud
   podman run --rm -v "$PWD:/w:z" -w /w registry.fedoraproject.org/fedora:44 sh -c \
     'dnf -y -q install git rust cargo python3 tar gzip make gcc >/dev/null &&
      SKIP_WAYLAND=1 NETLAB_SOURCE_ONLY=1 RUST_SYSTEM=1 tools/fetch-vendor.sh agent &&
      tools/package-agent.sh --out build/container'
   podman build -f packaging/container/Containerfile -t ghostty-agent build/container
   ```

   The first command packs the agent's source into a tarball inside a
   throwaway container, and the second builds the image from that tarball. The
   compile inside the image build runs with networking switched off.

   Once a published image exists, you can skip this step and use
   `podman pull ghcr.io/spaceghost/ghostty-agent:latest` instead.

2. Install the quadlet and start it:

   ```sh
   install -Dm0644 packaging/container/ghostty-agent.container \
     ~/.config/containers/systemd/ghostty-agent.container
   systemctl --user daemon-reload
   systemctl --user start ghostty-agent
   ```

   From now on it starts with your session. To keep your shells alive after you
   log out, run `loginctl enable-linger "$USER"`.

3. Check that it is running:

   ```sh
   systemctl --user status ghostty-agent
   journalctl --user -u ghostty-agent -f
   ```

## Per desktop

| Desktop | Notes |
|---|---|
| Silverblue (GNOME) | Nothing extra. GNOME puts `WAYLAND_DISPLAY` in the user manager, so the clipboard works. |
| Kinoite (KDE Plasma) | Nothing extra. Plasma does the same. |
| Sway Atomic | Fedora's sway config imports the session environment into systemd (`/etc/sway/config.d/50-systemd-user.conf`). If you replaced that config, add `exec systemctl --user import-environment WAYLAND_DISPLAY` to yours. |
| Bazzite | The game and the agent are on the same machine. Start the agent before the game and the plugin finds the token on its own. |

## Update

Pull the source again, repeat step 1, then run
`systemctl --user restart ghostty-agent`.

Restarting ends every open terminal, just as restarting the RPM's service does,
so choose your moment. The agent never restarts itself on an update.

## Your own tools

The shells run in the image, so add what you use to the image:

```Dockerfile
FROM localhost/ghostty-agent:latest
RUN dnf -y install tmux neovim ripgrep && dnf clean all
```

Build this with `podman build -t ghostty-agent-mine .` and point `Image=` in the
quadlet at it. For a fuller shell out of the box, build with
`--build-arg BASE=registry.fedoraproject.org/fedora-toolbox:44`.

## Remove

```sh
systemctl --user stop ghostty-agent
rm ~/.config/containers/systemd/ghostty-agent.container
systemctl --user daemon-reload
podman rmi ghostty-agent
```

Your token and settings stay in `~/.config/ghostty-agent`.

## Why each line of the quadlet is there

- `UserNS=keep-id` and `Volume=%h:%h`: you and your files, at the same paths.
- `SecurityLabelDisable=true`: your home is not relabelled for the container.
- `Network=host`: `127.0.0.1` means your desktop's loopback.
- `Volume=%t:%t` and the `--env` lines: your clipboard and your display.
- `AddDevice=-/dev/dri` and `GroupAdd=keep-groups`: a GPU for the compositor
  when you have one.
- `Restart=on-failure`: a crash brings the agent back, and nothing else
  restarts it.

The protocol uses a token but no encryption. Keep it on loopback, as the
quadlet does. To reach the agent from another machine, use `ssh -L`
(see [the agent's README](../packaging/README-agent.md)).
