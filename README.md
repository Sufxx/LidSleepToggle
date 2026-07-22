# LidSleepToggle

A macOS menubar app that decides when your Mac is allowed to sleep with the lid closed.

Close the lid and walk away while Claude Code, a build, or a training run finishes — then let the Mac sleep on its own once the work is done. A safety governor watches battery and temperature the whole time, so a long run never ends in a hard shutdown or a cooked laptop.

No subscription, no account, no telemetry. Single Swift binary, ~2 MB.

## Why

macOS only sleeps-on-lid-close as an all-or-nothing setting (`pmset disablesleep`). You either babysit the screen or you flip a global switch and hope you remember to flip it back. This does it per-workload:

```
Auto Mode → awake while work runs → work finishes → Mac sleeps
```

## Features

**Three modes**
- **Sleep on Lid Close** — normal macOS behaviour
- **Keep Awake** — stays awake with the lid shut until you stop it
- **Auto Mode** — awake only while tracked work is actually running

**Workload detection**
- Claude Code is tracked by session-file activity, not CPU, so it survives long silent thinking pauses
- An **adaptive idle window** learns the pauses your agent actually takes: steady work sleeps ~2 min after it finishes, bursty work with 4-minute gaps widens the window so a normal pause is never mistaken for "done"
- Everything else (Cursor, Codex, Ollama, Docker, npm, Python, Xcode, ffmpeg, cargo, Blender) is detected by process + CPU threshold, each individually toggleable, plus your own custom rules

**Safety governor** — overrides any mode, always
| Guard | Behaviour |
|---|---|
| Battery floor (default 20%) | Releases the hold |
| Battery critical (default 10%) | Releases **and sleeps the Mac**, so a long run never ends in a hard shutdown |
| Thermal | Drops the hold at critical thermal pressure, or when the hottest sensor passes 95 °C |
| Charging only | Hold only while on AC |
| Session timer | 1/2/4/8 h auto-stop |
| Offline + idle | On battery, off-network, nothing running → sleep |
| Hard cap | No single hold lasts more than 8 h |

**Also**
- **Awake Radar** — parses `pmset -g assertions` to show what *else* is blocking sleep
- **Watchdog** — pings you when an agent has been silent for 20 min but is still running (usually waiting on input, not working)
- **Lid-close display dimming** — with the lid shut the internal panel is set to brightness 0 (it doesn't switch off by itself in clamshell-awake mode), and restored on open
- **Alerts** — local notifications, plus optional phone push via [ntfy.sh](https://ntfy.sh) and/or a webhook
- **Dashboard** — session history, total awake time, longest run
- **Crash guard** — if the app dies holding the Mac awake, the next launch restores normal sleep
- Live chips: battery, real CPU °C, system CPU, lid state

## `lidkeep` — hold awake for one command

```bash
lidkeep -- npm run build
lidkeep --sleep -- python train.py   # sleep the Mac when it finishes
```

Works in any mode, including "Sleep on Lid Close". Install it from **Settings → General**.

## Install

Requires macOS 13+. Build from source (no Xcode needed, just the command line tools):

```bash
git clone https://github.com/Sufxx/LidSleepToggle.git
cd LidSleepToggle
./build.sh
```

`build.sh` compiles the app, installs a login item, and adds a **narrowly scoped** sudoers rule:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Those two exact commands and nothing else — validated with `visudo -c` before install. It's what makes the toggle instant instead of prompting for your password every time. To rebuild the app without touching sudoers or launchd: `./build.sh --app-only`.

### Uninstall

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.sufwan.lidsleeptoggle.plist
rm -f ~/Library/LaunchAgents/com.sufwan.lidsleeptoggle.plist
sudo rm -f /etc/sudoers.d/lidsleeptoggle
rm -rf ~/Library/Application\ Support/LidSleepToggle
defaults delete com.sufwan.lidsleeptoggle
sudo pmset -a disablesleep 0   # make sure normal sleep is restored
```

## Configuration

Most settings live in the Settings window. The rest are `defaults`:

```bash
defaults write com.sufwan.lidsleeptoggle idleWindowSeconds -int 600   # fixed window, disables adaptive learning
defaults write com.sufwan.lidsleeptoggle idleFloorSeconds  -int 120   # never sleep sooner than this
defaults write com.sufwan.lidsleeptoggle idleCeilSeconds   -int 1200  # ceiling on the learned window
defaults write com.sufwan.lidsleeptoggle cpuThreshold      -int 40    # %CPU that counts as "working"
defaults write com.sufwan.lidsleeptoggle maxAwakeHours     -int 8
defaults write com.sufwan.lidsleeptoggle batteryCritical   -int 10
defaults write com.sufwan.lidsleeptoggle tempCeiling       -int 95
defaults write com.sufwan.lidsleeptoggle offlineMinutes    -int 15
```

Settings read at launch are re-read on relaunch; anything changed in the Settings window applies immediately.

## How it works

| Concern | Approach |
|---|---|
| Lid-close sleep | `pmset -a disablesleep 0\|1` via the scoped sudoers rule |
| Reading the state | `pmset -g` reports it as **`SleepDisabled`**, *not* `disablesleep` — that key only appears under `pmset -g custom` |
| Claude activity | `claude-active.py` reads mtimes of `~/.claude/projects/**/*.jsonl` (covers subagents and multiple sessions) |
| Other workloads | One `ps -Ao pid=,pcpu=,args=` sweep, matched against rule patterns |
| CPU temperature | Private `IOHIDEventSystemClient` (usage page `0xff00`/`0x0005`), resolved by `dlsym` — no root |
| System CPU | `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas |
| Thermal pressure | `ProcessInfo.thermalState` |
| Display brightness | Private `DisplayServices` `Get/SetBrightness`, resolved by `dlsym` |
| Display sleep | Public `IOPMAssertionCreateWithName` |
| Lid state | `ioreg -k AppleClamshellState` |
| CLI holds | PID sentinel files under Application Support, swept with `kill(pid, 0)` |

Private APIs are all resolved at runtime and fail soft — if a lookup fails the feature just reports unavailable.

## Notes and gotchas

- **The keyboard backlight is deliberately never dimmed.** An earlier build used `KeyboardBrightnessClient`, which leaves the backlight in a stuck `isBacklightSuppressedOnKeyboard` state that a plain restore doesn't clear. The app now self-heals that state at launch and never touches it again. It's under 1 W anyway.
- **Running lid-closed traps heat.** Keep the Mac in open air, ideally plugged in. Don't do it in a bag. The thermal guard is on by default for a reason.
- **`pmset -g` vs `pmset -g custom`** use different key names for the same setting. Parsing the wrong one silently reports "off" forever.
- The app is ad-hoc signed. macOS may warn on first launch; it's built from the source in this repo.

## License

MIT — see [LICENSE](LICENSE).
