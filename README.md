# DaBlox Bridge

Remote-loaded Luau bridge for the DaBlox Fleet Manager.

## How it works

1. `autoexec.luau` runs automatically when Roblox launches (via Arceus X autoexec)
2. It fetches `bridge.luau` from this repo via `game:HttpGet()`
3. The bridge runs a 20Hz state/command loop using file I/O
4. The Python fleet manager reads state and sends commands via ADB

## Files

- `bridge.luau` — The full bridge (fetched by autoexec on every game join)

## Raw URL

```
https://raw.githubusercontent.com/YOURUSERNAME/dablox-bridge/main/bridge.luau
```

Set this URL in `autoexec.luau` line 7.

## Updating

Edit `bridge.luau` here → push to GitHub → every instance gets the new code on next game join. No ADB push needed.
