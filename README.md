# Civ5 Crossplay Fix

Play multiplayer *Sid Meier's Civilization V* between the Mac version (Aspyr, from Steam) and the Windows version, without desyncs.

Out of the box the two versions can't play together:

1. **They don't see each other's games.** The Mac build reports its version as `1.0.3.279 (180925)` and Windows reports `1.0.3.279 (403694)`. The game only shows games from a matching version.
2. **When forced to connect, they desync from the first turn.** The Mac converts Lua numbers to whole numbers by truncating them, while Windows rounds them. Map scripts give the engine fractional values, so the two computers generate different maps.

This tool fixes both with two small, reversible changes to your Mac copy of the game. **Windows players don't need to change anything.**

## Requirements

- Civilization V from Steam on macOS. This is Aspyr's build 1.4.2 (180925), the current and final Mac release. Both Apple Silicon and Intel Macs work.
- Brave New World, with the same DLC as the people you play with. This is normal Civ V multiplayer behaviour.
- Windows players on the stock Steam version.

## Install

1. Quit Civilization V.
2. Download this repository: green **Code** button → **Download ZIP**. Unzip it.
3. Open **Terminal** (Applications → Utilities), type `bash ` (with a space after it), drag `crossplay.sh` from the unzipped folder into the Terminal window, type ` install` and press Return. It looks like this:

   ```
   bash ~/Downloads/civ5-crossplay-fix-main/crossplay.sh install
   ```

The tool finds the game in any of your Steam libraries. If the game is somewhere else, add `--app "/path/to/Civilization V.app"`.

Before changing anything, the tool checks that your game files are exactly the version it knows about. If they aren't, it stops and changes nothing. It keeps backups of the originals in `~/Library/Application Support/civ5-crossplay-fix/`.

## Check status

```
bash crossplay.sh status
```

This reports whether the fix is installed, not installed, or only partly installed.

## Uninstall

```
bash crossplay.sh uninstall
```

This puts back Aspyr's original executable from the backup and resets the version line. Steam's **Properties → Installed Files → Verify integrity of game files** also restores everything.

## After a Steam update or "Verify integrity"

Either one can put the original files back. Run `status` to check, and `install` again if needed. It is safe to run `install` any number of times.

## What was tested

- Apple Silicon Mac against a Windows 11 PC over **LAN**, Brave New World, standard rules, several full sessions of 15–19 turns:
  - no desyncs;
  - in-game random number logs identical on both machines, turn by turn.
- **Online (Steam lobby) games:** not tested yet. Reports are welcome; please open an issue.

## Mods

Mods made only of XML, SQL or Lua work the same way they do between two Windows PCs. Everyone needs the same mods.

Some mods replace the game's core DLL (for example LekMod, Vox Populi and Community Patch). These need a separately built Mac version of that DLL, because a Windows DLL can't run on a Mac. **Mac support for LekMod is in progress.**

## Does it change single player?

Only in one way: Lua code (map scripts and some UI) now rounds numbers the way the Windows version always has. Maps from a given seed come out the same as on Windows.

## How it works

**Executable.** Lua's number-to-integer conversion (`lua_tointeger` and `luaL_optinteger`) is compiled differently on each platform:

| Build | Instruction | Behaviour |
|---|---|---|
| Windows (`lua51_Win32.dll`) | x87 `fistp` | rounds to nearest |
| Mac (64-bit) | SSE `cvttsd2si` | truncates |

The tool changes one byte in each of these two functions (`0F 2C` → `0F 2D`). That turns `cvttsd2si` into `cvtsd2si`, which rounds to nearest exactly like the Windows build. The patched sites are at file offsets `0xB47645` and `0xB4D2E4`.

The tool checks the 16 surrounding bytes before writing anything. Because the executable has changed, its code signature is replaced with an ad-hoc one so macOS still runs it.

**Version string.** In `Contents/AspyrAssets/global/String/App.json`, `App.WinFileVersionStr` is changed so the Mac reports the Windows build number:

| | `App.WinFileVersionStr` |
|---|---|
| Before | `{App.WinFileVersion} ({App.Build})` |
| After | `{App.WinFileVersion} (403694)` |

**Tests.** `tests/run.sh` checks the tool against stand-in game folders. GitHub Actions runs these checks on every change. To also run a full install and uninstall round trip on copies of your real game files, give it their paths:

```
tests/run.sh "/path/to/original/Civilization V" "/path/to/original/App.json"
```

## Is this AI-made?

Yes. I drove the strategy for comparison between game versions, reverse-engineering, test-bench setup and testing. Claude acted upon the strategy, wrote the tests, and wrote the code. Testing in multiplayer settings was done by me, on two LAN-connected machines (one Apple Silicon Mac, one Windows 11 PC).

## Credits

Built by me, with a lot of help from [Claude](https://claude.ai) (Anthropic), from the reverse engineering through to the tests.

Not affiliated with or endorsed by Firaxis, 2K or Aspyr. Civilization is a trademark of Take-Two Interactive. This repository contains no game files.

Licensed under the [MIT License](LICENSE).
