# Dundun Finder

A small World of Warcraft (Midnight) addon for finding Dundun in delves.

## What it does

- **One key to target and mark him.** A button and a keybind that target
  Dundun and put a triangle on him in one press. Press it as you move through
  the delve.
- **Shows what the press did.** The panel reads "Dundun marked" with a
  raid-warning style alert and a sound the first time it works, or "not in
  range yet" when he's still too far away.
- **Quiet nudge.** Until he's found, the panel text pulses every 30 seconds
  (adjustable) as a silent reminder.
- **Settings page** under Options > AddOns > Dundun Finder, or `/dundun config`.
  Includes a panel preview for positioning, lock, scale, and hide-once-found.

## Install

From CurseForge, or manually: unzip so that `DundunFinder\` sits inside
`World of Warcraft\_retail_\Interface\AddOns\`.

Then set a keybind: Options > Keybindings > AddOns > Dundun Finder > Target Dundun.

## Commands

| Command | Effect |
|---|---|
| `/dundun` | Show settings and help |
| `/dundun config` | Open the settings page |
| `/dundun toggle` | Enable or disable the addon |
| `/dundun mark <1-8 or name>` | Raid icon to use, e.g. `4` or `triangle` |
| `/dundun sound` | Toggle the alert sound |
| `/dundun announce` | Toggle the chat and on-screen announcement |
| `/dundun panel` | Show or hide the on-screen panel |
| `/dundun nudge [on / off / seconds]` | Toggle the nudge or set its interval (10 to 120 seconds) |
| `/dundun lock` | Lock or unlock the panel position |
| `/dundun scale <60-160>` | Panel size in percent |
| `/dundun reset` | Reset the panel position |

To see the panel outside a delve, use the Preview button on the settings page.

## Files

- `DundunFinder.toc` - addon manifest (Interface 120100 = 12.1.0)
- `DundunFinder.lua` - all the logic
- `Bindings.xml` - registers the keybind
- `CHANGELOG.md` - release notes
- `LICENSE` - all rights reserved

## Notes on the WoW API

- Targeting and, as of Midnight, setting raid markers are both protected.
  Neither can be done from addon code, so the button is a
  `SecureActionButtonTemplate` whose macro does the work from your click:
  `/cleartarget [nocombat]`, `/target Dundun`, `/tm [exists] 4`. Out of combat
  the target is cleared first so a failed `/target` can't mark something else,
  and in combat the current target is kept.
- Dundun is a neutral elite, and Midnight hands addons "secret" values for
  units like that, so his name, GUID, and marker can't be read back reliably
  and the addon doesn't try to. Out of combat the macro clears the target
  first, so any target after the press can only be him. In combat it only
  counts a target that visibly changed, and otherwise leaves the status alone.
- Delves are detected by `C_PartyInfo.IsDelveInProgress()` with a fallback to
  difficulty ID 208.
