# ghostty-agent

This is the host half of [Ghostty for Final Fantasy XIV](https://github.com/Spaceghost/ghostty-dalamud).
The plugin installs itself into the game from a Dalamud repository in one click;
this program is the only piece you fetch yourself. It runs on the machine whose
shells you want, as you, and it holds your terminals: they outlive the plugin
reloading, the game closing, and the machine the game runs on.

## Install it

From the RPM, on Fedora 44 or newer:

```sh
sudo dnf install ./ghostty-agent-<version>-1.fc44.x86_64.rpm
```

From the portable tarball, anywhere with glibc 2.36 or newer:

```sh
tar -xzf ghostty-agent-<version>-linux-x86_64.tar.gz
cd ghostty-agent-<version>-linux-x86_64
install -Dm0755 ghostty-agent ~/.local/bin/ghostty-agent
```

From source, with a C compiler and `make` and nothing else:

```sh
git clone https://github.com/Spaceghost/ghostty-dalamud
cd ghostty-dalamud
tools/fetch-vendor.sh agent     # only what the agent needs
tools/build-agent.sh            # build/dist/ghostty-agent
```

## Run it

```sh
ghostty-agent --listen 127.0.0.1:7777
```

The first start writes a token to `~/.config/ghostty-agent/token`, readable only
by you. The plugin reads that same file, so there is nothing to configure when
the game and the agent are on one machine.

Other flags: `--token-file PATH`, `--clipboard-file PATH`, `--replay-bytes N`,
`--term NAME`, `--windows NAME`. `ghostty-agent --help` lists them all.

When the game is on another machine, forward the port and copy the token:

```sh
ssh -L 7777:127.0.0.1:7777 that-machine
```

The protocol is authenticated by that token but it is not encrypted. Keep it on
loopback, inside an `ssh -L` tunnel, or on a private network.

## Start it with your session

From the RPM:

```sh
systemctl --user enable --now ghostty-agent
```

From the tarball:

```sh
install -Dm0644 ghostty-agent.service ~/.config/systemd/user/ghostty-agent.service
systemctl --user daemon-reload
systemctl --user enable --now ghostty-agent
```

`loginctl enable-linger "$USER"` keeps your shells alive after you log out.
`journalctl --user -u ghostty-agent -f` is its log. If the clipboard helpers
cannot see your desktop session, hand them the environment once with
`systemctl --user import-environment WAYLAND_DISPLAY DISPLAY`.

## Which build you have

The `.fc44` package carries the Wayland compositor backend: the agent is a
headless Wayland compositor of its own, so apps started into it — a browser, an
editor — become screens in the game, and X11 apps work there through Xwayland.
It links wlroots 0.20, which is why that package installs on Fedora 44 and newer
and not on Fedora 43.

The `.fc43` package and the portable tarball have no compositor backend:
terminals, jobs and clips work, remote desktop windows do not. The agent says
which it is when it starts.

## Optional helpers

None of these is needed to start. The agent looks for each on `$PATH` the first
time it needs one, and does without politely when it is not there.

| Program | What stops working without it |
|---|---|
| `wl-clipboard`, or `xclip` on X11 | copying between the game's terminals and your desktop |
| `ffmpeg` (`ffmpeg-free` on Fedora) | `/term clip`, the short screen recordings |
| `Xwayland` | X11-only apps inside the agent's compositor |
| `xdg-open` (`xdg-utils`) | opening a link in your desktop browser |
| `rsvg-convert`, or ImageMagick | SVG icons for the apps the compositor lists |
| `tmux` | nothing; it is just a shell you may want |

## Licence

MIT. See `LICENSE`.
