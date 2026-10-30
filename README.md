# HorseBot

A World of Warcraft Classic Era addon (1.15.x: Era, Anniversary, Hardcore, SoD) for running horse races that everyone nearby can bet on.

One player hosts a race and acts as the bookie. Everyone else with the addon sees it, places bets from their own client, and watches the same race unfold. The race plays out move for move on every screen. A shared ledger records who owes whom.

## Install

Copy the `HorseBot` folder into `World of Warcraft/_classic_era_/Interface/AddOns/` and reload.

## Using it

| Command | |
| --- | --- |
| `/hb` | Open the race book |
| `/hb host` | Set up a new race |
| `/hb ledger` | Balances with everyone you've bet with or taken bets from |
| `/hb refresh` | Ask nearby hosts to resend their open races |
| `/hb scope auto\|party\|raid\|guild\|channel` | Where new races are broadcast |
| `/hb channel <name>` | The shared channel used for races outside a group |
| `/hb autojoin`, `/hb announce`, `/hb debug` | Toggles |

**Hosting:** pick the number of horses (2–8), the distance (5–12 furlongs), the bet limits, an optional house cut, and where to broadcast. Opening betting generates the field and its morning line. Use **Post odds** to put the field in chat for players without the addon. Then **Close bets** and **Start race**. You can cancel (every bet is refunded) or void a single bet at any point before the start.

**Betting:** select a race, enter a stake (`5`, `2.5`, `2g 50s`), and click **Bet** next to a horse. The host's client checks the bet and confirms it, or tells you why it was refused.

## How it works

### Communication

Everything travels over hidden addon messages (`C_ChatInfo.SendAddonMessage`, prefix `HorseBot`):

- **Broadcasts** from the host go to one of four places:
  - the group (`PARTY`/`RAID`),
  - the `GUILD`,
  - a custom chat `CHANNEL` (default `HorseBotRaces`) that every client joins automatically and hides from the chat frames.

  The channel is what lets players who aren't grouped (on the same realm and faction) take part in the same race. `AUTO` uses the group if you have one and the channel otherwise. It's fixed when the race opens, so a race doesn't lose its audience if the host joins a group later.
- **Direct messages** (bet requests, rejections, sync replies) go by `WHISPER`.
- **Throttling:** the server throttles addon messages, so sends go through a token bucket: a burst of 8, then 1 per second. Bets that arrive close together are batched into one broadcast. Lists are packed and split to fit the 255-byte limit.
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

## Development

The tests run outside the game. `tests/wow_sim.lua` stubs just enough of the WoW API to run several copies of the addon side by side, each with its own globals and saved variables. They talk over a fake message bus that enforces the 255-byte limit and models party, guild, channel and whisper delivery. The suite covers:

- the simulation's determinism and balance,
- pari-mutuel maths,
- multi-client betting over channel, party and guild,
- late joiners, packet loss and resync,
- `/reload` mid-race,
- cancels, voids, trade booking, throttle compliance and spoofed messages,
- a UI smoke test.

```sh
lua5.1 tests/run.lua
```

Bump `ns.PROTOCOL` in `Core.lua` whenever the wire format or the simulation changes.
