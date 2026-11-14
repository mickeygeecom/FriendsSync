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

The eye left of the close button shows a slider that fades the window's background (drag or scroll, 0-100%);
text and buttons stay solid. Drag the corner grip to resize - size and position are remembered. Two tabs at the
bottom: **Friends** and **Settings**.

- **Left:** one card per synced friend - class icon, name with a level-gap badge on the right (`+2` orange = ahead
  of you, `-1` blue = behind), level, zone, XP bar and a badge (`Nearby`, `In sync`, `3 ahead`, `2 behind`, `Other guide`).
  Online friends come first; offline ones sit under a foldable **Offline (N)** row with their last level, zone and
  when they were seen. **Sort:** above the list changes the order (name, level, distance, last seen).
  Hover a card for details (realm, their FriendsSync version). **Right-click** a card for quick actions:
  Whisper, Invite, Set waypoint, Send meet-up pin, Match guide step, Show details, Hide from FriendsSync.
- **Right:** the selected friend, in sections:
  - **Tip** - the single most useful suggestion (e.g. "They're 3 steps ahead in the guide...")
  - **Level** - a ruler from the lower level to the higher: you (gold, above) and them (class colour, below),
    a tick per level, the gap coloured like the badge and rested XP as a faint blue tail
  - **Guide** - a track of the RestedXP guide: you (gold, above) and them (class colour, below).
    The stretch between you is orange if they're ahead, blue if you're ahead, green when in sync.
    Different guides show two progress bars. **Match step** switches your guide/step to theirs.
    Just one line when they don't use a guide.
  - **Quests** - foldable sections (click a header): You both have (ones you both still need first,
    "do it together"), You could pick up, Only you have, They have, you already did. Quests show their level and
    are coloured by difficulty for you; grey ones you could pick up are hidden (can be changed in Settings).
    Click a quest to put its link in chat (party chat if you're grouped with that friend) - or into the chat
    box you're already typing in. Right-click a quest in your own log to share it with your group.
  - Buttons: **Invite**, **Whisper**, **Waypoint** (TomTom if installed) and **Meet here** - sends your position;
    their FriendsSync sets a waypoint on it (both need 1.3.0 or newer). Hover any button for help - greyed-out
    buttons say why.
- **Bottom:** sync count and **Refresh** (re-discover friends now).

## Settings

On the window's **Settings** tab, `/fsync settings`, or Esc > Options > AddOns > FriendsSync:

- **Alerts:** master switch, and each kind on its own - comes online, levels up, nearby, new guide section;
  also on screen (raid-warning style), sound, and the nearby distance (50-500 yards).
- **Meeting up:** accept meet-up pins, version notices (when a friend's FriendsSync is newer or older than yours).
- **Friends list:** show offline friends, sort order, hide friends who've been offline for over N days.
- **Display:** world map dots, minimap button, button above the friends button, mini tracker (and lock it),
  level-gap badge, background opacity, window size (80-130%).
- **Quests:** hide grey quests you could pick up.
- **Friends:** reset window and tracker positions, unhide friends you hid.

## Mini tracker

An optional small, movable list of online synced friends - level, gap, and distance when nearby or their guide step.
Click a friend to open their details, right-click for the quick actions. Turn it on in Settings or with `/fsync tracker`.

## Friends button

A small FriendsSync button sits above the game's social (friends) button by the chat window, with the number of
synced friends online. Click to open the window, right-click for settings. Can be turned off in Settings.

## World map

Synced friends who are online show as class-coloured dots on your world map (same look as OpenMap's friend dots), on their zone and the
continent around it. Hover a dot for level, zone, coordinates and distance; click it to set a waypoint.
Works with OpenMap's stitched map too (and adds a "FriendsSync friends" switch to OpenMap's menu).
Friends already on the map are not drawn twice: group members keep the map's own party dot, and friends
OpenMap already shows (they share their location through OpenMap) keep OpenMap's dot.
Toggle in Settings or with `/fsync map`.

## Minimap button

- Left-click: open/close the window. Right-click: settings. Drag to move.
- Hover for online friends with level, gap and distance.
- Also available in the addon compartment menu. Hide it in Settings or with `/fsync minimap`.

## Alerts

You're told when a friend comes online with the addon, levels up, comes within the nearby distance (150 yards by
default) or starts a new guide section. Names are class-coloured and clickable (click to whisper).
Each kind can be turned off in Settings; `/fsync notify` toggles them all.

## Commands (`/fsync` or `/friendsync`)

| Command | Does |
| --- | --- |
| `/fsync` | open/close window |
| `/fsync settings` | open the Settings tab |
| `/fsync tracker` | show/hide the mini tracker |
| `/fsync ping` | re-discover friends now |
| `/fsync list` | print synced friends to chat |
| `/fsync status` | show who is reachable, sync count and the last error |
| `/fsync notify` | toggle all alerts |
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
