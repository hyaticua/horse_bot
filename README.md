# HorseBot

A World of Warcraft addon for running horse races that everyone nearby can bet on. It targets **WoW Forever**, which runs on the mainline (Midnight) client and its addon API. The same download also loads on Classic Era 1.15 (Era, Anniversary, Hardcore, SoD).

One player hosts a race and acts as the bookie. Everyone else with the addon sees it, places bets from their own client, and watches the same race unfold. The race plays out move for move on every screen. A shared ledger records who owes whom.

## Install

Copy the `HorseBot` folder into your client's `Interface/AddOns/` folder and reload:

| Client | Folder | Interface |
| --- | --- | --- |
| WoW Forever beta | `World of Warcraft/_classic_beta_/Interface/AddOns/` | 16001 |
| Classic Era | `World of Warcraft/_classic_era_/Interface/AddOns/` | 11509 |

The `.toc` lists both interface numbers. Forever's folder may be renamed at launch, and its interface number will rise with patches. If the addon shows as out of date, run `/dump select(4, GetBuildInfo())` in game and put that number on the `## Interface:` line.

## Using it

| Command | |
| --- | --- |
| `/hb` | Open the race book |
| `/hb host` | Set up a new race |
| `/hb ledger` | Balances with everyone you've bet with or taken bets from |
| `/hb refresh` | Ask nearby hosts to resend their open races |
| `/hb scope auto\|party\|raid\|guild\|channel` | Where new races are broadcast |
| `/hb channel <name>` | The shared channel used for races outside a group |
| `/hb models on\|off\|flip` | 3D horse models on the track (`flip` if they ever run backwards) |
| `/hb models mixed\|riding\|skeletal` | Which horses run |
| `/hb autojoin`, `/hb announce`, `/hb debug` | Toggles |

**Hosting:** pick the number of horses (2–8), the distance (5–12 furlongs), the bet limits, an optional house cut, and where to broadcast. Opening betting generates the field and its morning line. Use **Post odds** to put the field in chat for players without the addon. Then **Close bets** and **Start race**. You can cancel (every bet is refunded) or void a single bet at any point before the start.

**Betting:** select a race, enter a stake (`5`, `2.5`, `2g 50s`), and click **Bet** next to a horse. The host's client checks the bet and confirms it, or tells you why it was refused.

## How it works

### Communication

Everything travels over hidden addon messages (`C_ChatInfo.SendAddonMessage`, prefix `HorseBot`):

- **Broadcasts** from the host go to one of four places:
  - the group (`PARTY`/`RAID`, or `INSTANCE_CHAT` in an instance group),
  - the `GUILD`,
  - a custom chat `CHANNEL` (default `HorseBotRaces`) that every client joins automatically and hides from the chat frames.

  The channel is what lets players who aren't grouped (on the same realm and faction) take part in the same race. `AUTO` uses the group if you have one and the channel otherwise. It's fixed when the race opens, so a race doesn't lose its audience if the host joins a group later.
- **Direct messages** (bet requests, rejections, sync replies) go by `WHISPER`.
- **Throttling:** the server throttles addon messages, so sends go through a token bucket: a burst of 8, then 1 per second. Bets that arrive close together are batched into one broadcast. Lists are packed and split to fit the 255-byte limit.
- **The chat lockdown (Forever / mainline):** addons can't send addon messages or use chat channels during boss encounters, active Mythic+ runs or live PvP matches. Ordinary combat is fine. While the lockdown is on:
  - Outgoing messages wait in the queue and go out as soon as it lifts.
  - You can't bet, open a race or start one; the addon says why rather than letting the request time out.
  - A host who's locked down still takes bets that reach them and announces them afterwards.
  - Joining the shared channel waits until the lockdown ends.
  - Messages that arrive as secret values are ignored, and the resync fills the gap later.
- **Offline hosts:** a bet whispered to a host who isn't online fails at once and tells you so.
- **Starter and Veteran accounts** reportedly can't send addon messages on Forever. They get a warning at login and can still follow races.
- **Recovery:**
  - On login, and whenever you press Refresh, a client asks every reachable host for its races.
  - Hosts re-announce their open races every 60 seconds. Each announcement carries the bet count, so a client that missed messages notices the gap and asks for a full resync.
  - Races and bets are kept in saved variables, so a `/reload` loses nothing.

### The host is authoritative

Clients send bet *requests*. The host validates each one (betting still open, horse exists, stake within limits), numbers it, and broadcasts the accepted bet. Every client therefore holds the same book. Only the host can change its races: race IDs carry the host's name, and messages about a race from anyone else are ignored.

### Races are simulated, not streamed

At the start the host broadcasts a random seed. Each client runs the same deterministic simulation from that seed, using a Park–Miller PRNG and integer arithmetic only, so the race is identical on every client. That's one small message instead of hundreds of position updates the throttle wouldn't allow. The host also broadcasts the finishing order and pool totals at the end. If a client's replay ever disagreed (for example, a different addon version), the client uses the host's result and shows a warning. Protocol versions are checked, and clients warn when someone is running a newer version.

The simulation:

- **Speed** sets cruising pace.
- **Stamina** is a distance a horse can cover before it tires. Sprints favour speed, and 10–12 furlong races favour stamina.
- **Consistency** controls how far a horse's form on the day, and its stride-to-stride variation, can swing.
- **Running style** changes when a horse makes its effort:
  - front-runners break fast and spend their stamina early,
  - stalkers run evenly,
  - closers come late.

  The test suite checks that no style or single stat dominates.

### On the track

Runners are the game's own horse models, drawn in `PlayerModel` frames.
- **The field:** a mix of riding horses and Forsaken skeletal horses. Each horse's breed and coat come from its name, so a horse looks the same every time and on every client. `/hb models riding` or `/hb models skeletal` gives a single-breed field; `/hb models mixed` goes back to the mix.
- **Animation:** horses stand in the gate during the countdown, use the run animation during the race, and ease past the finish line to a walk and then a halt.
- **Telling horses apart:** each horse carries a saddle cloth in its lane colour with its number.
- **Depth:** model frames are taller than their lanes and nearer lanes draw on top, so the field overlaps as if seen from the stands.

**Coats are checked before they're used.** A wrong display ID renders some other creature, so the IDs in `Models.lua` come in two kinds:

| Breed | Verified against the mount tables | Candidates, checked in the client |
| --- | --- | --- |
| Riding horse | 2404 Brown Horse, 2402 Black Stallion, 2409 Pinto | 2405, 2408, 2410 |
| Skeletal horse | 5228 Skeletal Horse | 10670, 10671, 10672 |

Every coat of a breed is the same model file with a different skin. A few seconds after login, the addon loads each ID in an invisible model frame. It keeps a candidate only if the candidate loads the same model file as its breed's verified horse, so a wrong guess is dropped and never shown. If the client can't report model files at all, only the verified IDs are used. A lane whose model fails to load during a race falls back to the riding-horse icon, and `/hb models off` uses icons throughout.

### Odds and payouts

- **Morning line (ML):** a fair price from 250 simulated runs of the actual field.
- **Tote:** live pari-mutuel odds from the money bet so far.
- **Payouts are pari-mutuel.** Winners split the pool, less the house cut, in proportion to their stakes. If nobody backed the winner, every bet is refunded. Rounding is down to the copper, and the host keeps the fractions.

### The ledger and gold

An addon can't move gold, so HorseBot keeps the books and players settle by trade. Each counterparty has one balance (*owes you* / *you owe*):

- Bets, payouts, voids and refunds update it on both sides.
- When you complete a trade with someone in the ledger, the gold exchanged is booked automatically.
- **Settle** zeroes a balance by hand.

## Limitations

- Bets work on trust. The host can void bets from players who don't pay before the race starts.
- The host is trusted with the seed. Bettors can't predict the outcome, because the seed is generated only when betting has closed. But nothing stops a dishonest host from trying seeds before broadcasting one. Bet with people you'd lend gold to.
- The shared channel works within one realm (and its connected realms) and one faction. Whispers have the same reach.
- Win bets only for now. Place/show and exotics would fit the same pool model.
- The Forever details (lockdown triggers, the separate custom-channel throttle, Starter account limits) come from community research rather than official documentation, and haven't been tested in game yet.

## Development

The tests run outside the game. `tests/wow_sim.lua` stubs just enough of the WoW API to run several copies of the addon side by side, each with its own globals and saved variables. They talk over a fake message bus that enforces the 255-byte limit and models party, instance, guild, channel and whisper delivery. Every test runs twice: once against a Classic Era client, and once against a Forever client with the mainline API (chat lockdown, secret values, the newer send results, `C_ChatInfo.SendChatMessage`, no global `ChatFrame_RemoveChannel`). The suite covers:

- the simulation's determinism and balance,
- pari-mutuel maths,
- multi-client betting over channel, party and guild,
- the horse models: the in-client coat check, breeds, facing, animations and icon fallback,
- late joiners, packet loss and resync,
- `/reload` mid-race,
- cancels, voids, trade booking, throttle compliance and spoofed messages,
- the Forever lockdown (reported on time and late), offline hosts, secret values, Starter account warnings, instance groups,
- a UI smoke test.

```sh
lua5.1 tests/run.lua           # both clients
lua5.1 tests/run.lua forever   # one client: classic | forever
```

Bump `ns.PROTOCOL` in `Core.lua` whenever the wire format or the simulation changes.
