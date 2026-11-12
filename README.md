# FriendsSync

A World of Warcraft addon for **WoW Forever** (Interface 16001) that shares levelling progress with friends who also run FriendsSync - no group needed.

## Who it syncs with

- Online characters on your WoW friends list (hidden addon whispers).
- Battle.net friends playing the same game version, even on other realms.

Only messages from people on your friends lists are accepted. Both sides need the addon.

## What is shared

- Level, XP %, rested XP, class
- Zone/subzone and position (distance in yards, map coords for waypoints)
- Quest log: quest IDs and objective progress
- RestedXP guide + current step (if RXPGuides is loaded)

## Window (`/fsync`, or click the minimap button)

- **Left:** one card per synced friend - class icon, name, level, zone, XP bar and a badge
  (`Nearby`, `In sync`, `3 ahead`, `2 behind`, `Other guide`). Hover a card for details.
- **Right:** the selected friend, in sections:
  - **Tip** - the single most useful suggestion (e.g. "They're 3 steps ahead in the guide...")
  - **Level** - your XP bar next to theirs
  - **Guide** - a track of the RestedXP guide: you (gold, above) and them (class colour, below).
    The stretch between you is orange if they're ahead, blue if you're ahead, green when in sync.
    Different guides show two progress bars. **Match step** switches your guide/step to theirs.
  - **Quests** - You both have / You could pick up / Only you have / They have, you already did
  - Buttons: **Invite**, **Whisper**, **Waypoint** (TomTom if installed). Hover any button for help.
- **Bottom:** Chat alerts and World map checkboxes, sync count, **Refresh** (re-discover friends now).

## World map

Synced friends who are online show as class-coloured dots with their name on your world map, on their zone and the
continent around it. Hover a dot for level, zone, coordinates and distance; click it to set a waypoint.
Works with OpenMap's stitched map too (and adds a "FriendsSync friends" switch to OpenMap's menu).
Friends already on the map are not drawn twice: group members keep the map's own party dot, and friends
OpenMap already shows (they share their location through OpenMap) keep OpenMap's dot.
Toggle with the checkbox or `/fsync map`.

## Minimap button

- Left-click: open/close the window. Right-click: toggle chat alerts. Drag to move.
- Also available in the addon compartment menu. Hide it with `/fsync minimap`.

## Chat alerts

Toggle with the checkbox, right-clicking the minimap button, or `/fsync notify`.
You're told when a friend comes online with the addon, levels up, or comes within 150 yards.
Names are class-coloured and clickable (click to whisper).

## Commands (`/fsync` or `/friendsync`)

| Command | Does |
| --- | --- |
| `/fsync` | open/close window |
| `/fsync ping` | re-discover friends now |
| `/fsync list` | print synced friends to chat |
| `/fsync status` | show who is reachable, sync count and the last error |
| `/fsync notify` | toggle chat alerts |
| `/fsync map` | show/hide friends on the world map |
| `/fsync minimap` | show/hide the minimap button |
| `/fsync forget Name` | remove a saved friend |
| `/fsync debug` | print raw sync messages |

## Notes

- Cross-faction sync only works via Battle.net friends; WoW friends are same faction.
- Traffic is throttled: status every ~30s (sooner on changes/movement), quests and guide only when they change.
- Last-known data for offline friends is kept in SavedVariables (`FriendsSyncDB`).

## License

MIT - see [LICENSE](LICENSE).