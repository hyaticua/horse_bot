import discord
from discord import app_commands
from discord.ext import commands
import asyncio
import os
from typing import Literal
from dataclasses import dataclass, field

from gif_generator import generate_betting_gif, generate_race_gif

# Bot configuration
BETTING_TIME = 300  # 5 minutes in seconds
HORSES = ["whorse", "thundercunt", "horsemasheen", "gluestick", "neigh_sayer", "sarah_jessica_trotter"]

# Temp directory for generated GIFs
GIF_DIR = "temp_gifs"
os.makedirs(GIF_DIR, exist_ok=True)

@dataclass
class Bet:
    user_id: int
    user_name: str
    horse: str
    bet_type: Literal["win", "place", "show"]
    amount: int

@dataclass
class Race:
    active: bool = False
    betting_open: bool = False
    bets: list[Bet] = field(default_factory=list)
    channel_id: int | None = None

class HorseRacingBot(commands.Bot):
    def __init__(self):
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(command_prefix="!", intents=intents)
        self.race = Race()
        self.user_balances: dict[int, int] = {}  # user_id -> balance
        self.default_balance = 1000

    async def setup_hook(self):
        await self.tree.sync()

bot = HorseRacingBot()

def get_balance(user_id: int) -> int:
    if user_id not in bot.user_balances:
        bot.user_balances[user_id] = bot.default_balance
    return bot.user_balances[user_id]

def update_balance(user_id: int, amount: int):
    if user_id not in bot.user_balances:
        bot.user_balances[user_id] = bot.default_balance
    bot.user_balances[user_id] += amount

@bot.event
async def on_ready():
    print(f"{bot.user} has connected to Discord!")
    print(f"Bot is in {len(bot.guilds)} guilds")

@bot.tree.command(name="start_race", description="Start a new horse race with betting")
async def start_race(interaction: discord.Interaction):
    if bot.race.active:
        await interaction.response.send_message("A race is already in progress!", ephemeral=True)
        return

    bot.race = Race(active=True, betting_open=True, channel_id=interaction.channel_id)

    # Generate betting GIF
    race_id = interaction.id
    betting_gif_path = os.path.join(GIF_DIR, f"betting_{race_id}.gif")
    generate_betting_gif(HORSES, betting_gif_path)

    # Create horse list embed
    horse_list = "\n".join([f"🐴 **{i+1}.** {horse}" for i, horse in enumerate(HORSES)])

    embed = discord.Embed(
        title="🏇 HORSE RACE - BETTING OPEN 🏇",
        description=f"Use `/bet_horse` to wager (win/place/show). You have 5 min.\n\n**Horses:**\n{horse_list}",
        color=discord.Color.gold()
    )
    embed.add_field(name="Bet Types", value="**win** - Horse finishes 1st (3x payout)\n**place** - Horse finishes 1st or 2nd (2x payout)\n**show** - Horse finishes 1st, 2nd, or 3rd (1.5x payout)", inline=False)

    await interaction.response.send_message(embed=embed, file=discord.File(betting_gif_path))

    # Clean up betting GIF
    os.remove(betting_gif_path)

    # Wait for betting period
    await asyncio.sleep(BETTING_TIME)

    if not bot.race.active:
        return

    bot.race.betting_open = False

    # Run the race
    await run_race(interaction.channel)

async def run_race(channel: discord.TextChannel):
    # Close betting announcement
    await channel.send("🚫 **BETTING CLOSED!** 🚫\n\n🏁 And they're off! 🏁")

    # Generate race GIF - this determines the winner!
    race_gif_path = os.path.join(GIF_DIR, f"race_{channel.id}.gif")
    results = generate_race_gif(HORSES, race_gif_path)

    # Send racing GIF
    await channel.send(file=discord.File(race_gif_path))

    # Clean up race GIF
    os.remove(race_gif_path)

    # Small delay for dramatic effect (let users watch the race)
    await asyncio.sleep(8)

    # Display results
    results_embed = discord.Embed(
        title="🏁 RACE RESULTS 🏁",
        description=f"🥇 {results[0]}\n🥈 {results[1]}\n🥉 {results[2]}",
        color=discord.Color.green()
    )

    # Calculate winnings
    winnings_text = []
    for bet in bot.race.bets:
        payout = calculate_payout(bet, results)
        if payout > 0:
            update_balance(bet.user_id, payout)
            winnings_text.append(f"💰 **{bet.user_name}** won **${payout}** ({bet.bet_type} on {bet.horse})")
        else:
            winnings_text.append(f"😢 **{bet.user_name}** lost **${bet.amount}** ({bet.bet_type} on {bet.horse})")

    if winnings_text:
        results_embed.add_field(name="Betting Results", value="\n".join(winnings_text), inline=False)
    else:
        results_embed.add_field(name="Betting Results", value="No bets were placed!", inline=False)

    await channel.send(embed=results_embed)

    # Reset race state
    bot.race = Race()

def calculate_payout(bet: Bet, results: list[str]) -> int:
    horse_position = results.index(bet.horse) if bet.horse in results else -1

    if bet.bet_type == "win" and horse_position == 0:
        return bet.amount * 3  # 3x payout for win
    elif bet.bet_type == "place" and horse_position in [0, 1]:
        return bet.amount * 2  # 2x payout for place
    elif bet.bet_type == "show" and horse_position in [0, 1, 2]:
        return int(bet.amount * 1.5)  # 1.5x payout for show
    return 0

@bot.tree.command(name="bet_horse", description="Place a bet on a horse")
@app_commands.describe(
    horse="The horse to bet on",
    bet_type="Type of bet: win (1st), place (1st/2nd), or show (1st/2nd/3rd)",
    amount="Amount to bet"
)
@app_commands.choices(horse=[
    app_commands.Choice(name=horse, value=horse) for horse in HORSES
])
@app_commands.choices(bet_type=[
    app_commands.Choice(name="win (1st place - 3x payout)", value="win"),
    app_commands.Choice(name="place (top 2 - 2x payout)", value="place"),
    app_commands.Choice(name="show (top 3 - 1.5x payout)", value="show"),
])
async def bet_horse(
    interaction: discord.Interaction,
    horse: str,
    bet_type: Literal["win", "place", "show"],
    amount: int
):
    if not bot.race.active or not bot.race.betting_open:
        await interaction.response.send_message("No active race or betting is closed!", ephemeral=True)
        return

    if amount <= 0:
        await interaction.response.send_message("Bet amount must be positive!", ephemeral=True)
        return

    balance = get_balance(interaction.user.id)
    if amount > balance:
        await interaction.response.send_message(f"Insufficient funds! You have ${balance}.", ephemeral=True)
        return

    # Deduct bet amount
    update_balance(interaction.user.id, -amount)

    # Record bet
    bet = Bet(
        user_id=interaction.user.id,
        user_name=interaction.user.display_name,
        horse=horse,
        bet_type=bet_type,
        amount=amount
    )
    bot.race.bets.append(bet)

    await interaction.response.send_message(
        f"🎰 **Bet placed!** ${amount} on **{horse}** to {bet_type}.\n"
        f"Remaining balance: ${get_balance(interaction.user.id)}",
        ephemeral=True
    )

@bot.tree.command(name="balance", description="Check your current balance")
async def balance(interaction: discord.Interaction):
    bal = get_balance(interaction.user.id)
    await interaction.response.send_message(f"💰 Your balance: **${bal}**", ephemeral=True)

@bot.tree.command(name="cancel_race", description="Cancel the current race (admin only)")
async def cancel_race(interaction: discord.Interaction):
    if not interaction.user.guild_permissions.administrator:
        await interaction.response.send_message("Only admins can cancel races!", ephemeral=True)
        return

    if not bot.race.active:
        await interaction.response.send_message("No active race to cancel!", ephemeral=True)
        return

    # Refund all bets
    for bet in bot.race.bets:
        update_balance(bet.user_id, bet.amount)

    bot.race = Race()
    await interaction.response.send_message("🚫 Race cancelled! All bets have been refunded.")

if __name__ == "__main__":
    import os
    token = os.getenv("DISCORD_BOT_TOKEN")
    if not token:
        print("Error: DISCORD_BOT_TOKEN environment variable not set!")
        print("Set it with: export DISCORD_BOT_TOKEN='your_token_here'")
        exit(1)
    bot.run(token)
