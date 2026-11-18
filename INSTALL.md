# Installing FFXIPort 1.2.0

FFXIPort has two parts and both are needed: the **server module** (installed
once on the XI: Forever Offline server) and the **Ashita addon** (installed by
each player). Install both from the same release.

## Installation via XI: Forever Offline launcher

FFXIPort is available in the XI: Forever Offline launcher's **OTHER** tab.
Find **FFXIPort**, choose **Install** or **Reinstall / update**, then enable
it under **ADDONS → Addons to load**. The launcher indicates that the
server-side component ships with XI: Forever Offline.

The launcher may offer a different version from this GitHub release. For
manual installations, updates to a custom server, or a specific version,
follow the instructions below and use matching client and server files.

## 1. Server module

You need access to the server's files (the folder that contains `modules/`,
`scripts/` and `settings/`).

1. **Stop the map server.**
2. **Disable the previous FFXIPort server module**, if installed. It is usually
   `modules/custom/late/ffxiport.lua` with the command `!ffxip`.
   First check how `modules/init.txt` loads it, because a listed **folder**
   loads every module file inside it:

   * **`init.txt` lists the file itself** (a line such as
     `custom/late/ffxiport.lua`): remove that line or comment it out with `#`.
   * **`init.txt` lists a folder that contains it** (for example
     `custom/late/`, `custom/late`, `custom/` or `custom`): commenting out or
     deleting a file line is **not enough**, because the folder entry still
     loads the file. **Move `ffxiport.lua` out of the `modules/` tree** (for
     example to a backup folder outside the server's `modules/` directory) or
     delete it.

   If you are unsure, moving the file out of `modules/` works in both cases.
   The old and new modules use different files, names and commands, so having
   both loaded causes no conflict. But FFXIPort 1.1.0 and later cannot use the old one,
   so keeping it serves no purpose.
3. **Copy** `server/modules/custom/late/fpxport.lua` from this package to the
   server's `modules/custom/late/fpxport.lua`.
4. **Enable it** in `modules/init.txt` by adding this line (skip if the
   `custom/late/` folder is already listed there):

   ```
   custom/late/fpxport.lua
   ```

5. **Start the map server** and check its log for errors mentioning
   `fpxport`. The module changes no SQL, no core files and no other scripts.
6. Optional: change the prices in the `SERVER ADMINISTRATORS: TRAVEL PRICES`
   block at the top of `fpxport.lua` (`M.config.prices`, `sameCityFree`),
   then restart the map server. The defaults are 1,000 gil or 100 Conquest Points
   (Home Points, Survival Guides, Gate Crystals) and 1,000 gil or 100
   Imperial Standing (Runic Portals); same-city travel is free. Invalid values
   are logged as `[fpxport] CONFIG ERROR` and the category keeps its default.
   Full rules: `docs/SERVER-MODULE.md` -> *Changing prices*.

   **Updating from 1.1.0:** if you changed prices in 1.1.0's `fpxport.lua`,
   copy your values into the same block of the new file before replacing it.

Operators: after testing, search the map-server log for `CURRENCY INCIDENT`.
There should be none. Each such line identifies a trip whose payment outcome
the server could not confirm (see `docs/SERVER-MODULE.md`).

## 2. Ashita addon (each player)

1. In game: `/addon unload FFXIPort` (if an older version is loaded).
2. Close the game, or keep it running with the addon unloaded.
3. In your Ashita folder, **back up and then delete** the old
   `addons/FFXIPort` folder. Do not copy over it: older versions contained
   `ffxiport/protocol.lua`, which must not remain.
4. Copy the `FFXIPort` folder from this package's `client/` folder to
   `Ashita/addons/`. You should now have `Ashita/addons/FFXIPort/FFXIPort.lua`.
5. In game: `/addon load FFXIPort`. You should see
   `FFXIPort 1.2.0 loaded. /port opens the window, /port sync synchronizes.`
6. To load it automatically, add `/addon load FFXIPort` to your Ashita
   startup script (for example `Ashita/scripts/default.txt`).

Your per-character settings and favourites (Ashita settings alias
`ffxiport_independent`, stored by Ashita's settings library under its
configuration folder, not inside the addon folder) are kept across the update.
1.2.0 adds a theme and an expansion filter setting; existing characters start
with Classic, 100 % scale, all expansions and no floating button, exactly as
before.

## 3. Check that it works

1. About 2 seconds after login the window's status shows **Synchronized.**
   (open it with `/port`).
2. `/port status` shows "frames" above 0, "responses" above 0 and "foreign: 0".
3. Travel to an unlocked Home Point in the same city: it is free.

If something does not work, see *Troubleshooting* in README.md.

## Uninstalling

* Client: `/addon unload FFXIPort` and delete `Ashita/addons/FFXIPort`.
* Server: stop the map server, then:
  * if `modules/init.txt` lists `custom/late/fpxport.lua` itself, remove that
    line (or comment it out with `#`);
  * if it lists a folder that contains the file (for example `custom/late/`
    or `custom/`), removing a file line is not enough. Move `fpxport.lua` out
    of the `modules/` tree, or delete it.

  Then start the map server again. Moving the file out of `modules/` works in
  both cases.
