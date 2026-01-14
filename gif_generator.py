from PIL import Image, ImageDraw, ImageFont
import random
import os

# Race configuration
TRACK_WIDTH = 800
TRACK_HEIGHT = 400
LANE_HEIGHT = 50
HORSE_EMOJI = "🐴"
FINISH_LINE_X = 750

# Colors
COLORS = {
    "track": "#2d5016",
    "lane_light": "#3d6b1e",
    "lane_dark": "#2d5016",
    "finish": "#ffffff",
    "text": "#ffffff",
    "starting_gate": "#8B4513",
}

HORSE_COLORS = [
    "#e74c3c",  # red
    "#3498db",  # blue
    "#f1c40f",  # yellow
    "#9b59b6",  # purple
    "#1abc9c",  # teal
    "#e67e22",  # orange
]


def get_font(size: int):
    """Try to get a font, fall back to default if needed."""
    try:
        # Try common system fonts
        for font_path in [
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/SFNSText.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "arial.ttf",
        ]:
            if os.path.exists(font_path):
                return ImageFont.truetype(font_path, size)
    except:
        pass
    return ImageFont.load_default()


def draw_track(draw: ImageDraw, num_horses: int):
    """Draw the race track with lanes."""
    # Background
    draw.rectangle([0, 0, TRACK_WIDTH, TRACK_HEIGHT], fill=COLORS["track"])

    # Draw lanes
    for i in range(num_horses):
        y = 50 + i * LANE_HEIGHT
        color = COLORS["lane_light"] if i % 2 == 0 else COLORS["lane_dark"]
        draw.rectangle([0, y, TRACK_WIDTH, y + LANE_HEIGHT], fill=color)
        # Lane dividers
        draw.line([0, y, TRACK_WIDTH, y], fill="#1a3009", width=2)

    # Finish line
    for i in range(num_horses + 1):
        y = 50 + i * LANE_HEIGHT
        for j in range(8):
            color = "#ffffff" if j % 2 == 0 else "#000000"
            draw.rectangle([FINISH_LINE_X, y - LANE_HEIGHT + j * 6, FINISH_LINE_X + 10, y - LANE_HEIGHT + (j + 1) * 6], fill=color)


def draw_horse(draw: ImageDraw, x: int, y: int, color: str, name: str, font):
    """Draw a horse at the given position."""
    # Horse body (simple rectangle/oval representation)
    horse_width = 40
    horse_height = 25

    # Body
    draw.ellipse([x, y - horse_height//2, x + horse_width, y + horse_height//2], fill=color)

    # Head
    draw.ellipse([x + horse_width - 5, y - 15, x + horse_width + 15, y + 5], fill=color)

    # Legs (animated based on x position for galloping effect)
    leg_offset = (x // 10) % 4
    leg_positions = [
        [(0, 0), (10, 15)],   # back legs
        [(25, 0), (35, 15)],  # front legs
    ]

    for i, (leg1, leg2) in enumerate(leg_positions):
        offset = 5 if (leg_offset + i) % 2 == 0 else -5
        draw.line([x + leg1[0] + 5, y + 10, x + leg1[0] + 5 + offset, y + 22], fill=color, width=3)
        draw.line([x + leg2[0] + 5, y + 10, x + leg2[0] + 5 - offset, y + 22], fill=color, width=3)

    # Eye
    draw.ellipse([x + horse_width + 5, y - 10, x + horse_width + 9, y - 6], fill="white")

    # Name label
    draw.text((x + 5, y - 35), name[:10], fill="white", font=font)


def draw_starting_gate(draw: ImageDraw, num_horses: int):
    """Draw starting gates."""
    gate_x = 30
    for i in range(num_horses):
        y = 50 + i * LANE_HEIGHT + LANE_HEIGHT // 2
        # Gate frame
        draw.rectangle([gate_x, y - 20, gate_x + 50, y + 20], outline=COLORS["starting_gate"], width=3)
        # Gate bars
        for j in range(5):
            bar_x = gate_x + 10 + j * 8
            draw.line([bar_x, y - 20, bar_x, y + 20], fill=COLORS["starting_gate"], width=2)


def generate_betting_gif(horses: list[str], output_path: str = "betting.gif"):
    """Generate a GIF showing horses at the starting gate."""
    frames = []
    font = get_font(12)
    title_font = get_font(24)

    num_horses = len(horses)

    for frame_num in range(20):
        img = Image.new("RGB", (TRACK_WIDTH, TRACK_HEIGHT), COLORS["track"])
        draw = ImageDraw.Draw(img)

        draw_track(draw, num_horses)
        draw_starting_gate(draw, num_horses)

        # Draw horses at starting position with slight movement
        for i, horse in enumerate(horses):
            y = 50 + i * LANE_HEIGHT + LANE_HEIGHT // 2
            x = 85 + random.randint(-2, 2)  # Slight jitter
            draw_horse(draw, x, y, HORSE_COLORS[i % len(HORSE_COLORS)], horse, font)

        # Title with blinking effect
        if frame_num % 4 < 2:
            draw.text((250, 10), "PLACE YOUR BETS!", fill="#ffff00", font=title_font)
        else:
            draw.text((250, 10), "PLACE YOUR BETS!", fill="#ff9900", font=title_font)

        frames.append(img)

    frames[0].save(output_path, save_all=True, append_images=frames[1:], duration=150, loop=0)
    return output_path


def generate_race_gif(horses: list[str], output_path: str = "race.gif") -> list[str]:
    """Generate a race GIF with random winner. Returns finishing order."""
    frames = []
    font = get_font(12)
    title_font = get_font(20)

    num_horses = len(horses)
    num_frames = 60

    # Generate random speeds for each horse (determines final positions)
    # Add some randomness but also variation throughout the race
    base_speeds = [random.uniform(8, 12) for _ in range(num_horses)]

    # Track positions
    positions = [85.0] * num_horses

    for frame_num in range(num_frames):
        img = Image.new("RGB", (TRACK_WIDTH, TRACK_HEIGHT), COLORS["track"])
        draw = ImageDraw.Draw(img)

        draw_track(draw, num_horses)

        # Update positions with varying speeds
        for i in range(num_horses):
            # Add variation to speed throughout race
            speed = base_speeds[i] + random.uniform(-2, 2)
            # Burst of speed near the end for excitement
            if frame_num > 45:
                speed += random.uniform(0, 3)
            positions[i] += speed

            # Cap at finish line
            positions[i] = min(positions[i], FINISH_LINE_X - 30)

        # Draw horses
        for i, horse in enumerate(horses):
            y = 50 + i * LANE_HEIGHT + LANE_HEIGHT // 2
            draw_horse(draw, int(positions[i]), y, HORSE_COLORS[i % len(HORSE_COLORS)], horse, font)

        # Race status
        if frame_num < 5:
            draw.text((300, 10), "AND THEY'RE OFF!", fill="#ffff00", font=title_font)
        elif frame_num > 50:
            draw.text((280, 10), "FINAL STRETCH!", fill="#ff0000", font=title_font)

        frames.append(img)

    # Final frame - show finishing positions
    final_positions = [(positions[i], horses[i]) for i in range(num_horses)]
    final_positions.sort(key=lambda x: x[0], reverse=True)
    finishing_order = [horse for _, horse in final_positions]

    # Add a few frames showing the finish
    for _ in range(15):
        img = Image.new("RGB", (TRACK_WIDTH, TRACK_HEIGHT), COLORS["track"])
        draw = ImageDraw.Draw(img)
        draw_track(draw, num_horses)

        for i, horse in enumerate(horses):
            y = 50 + i * LANE_HEIGHT + LANE_HEIGHT // 2
            draw_horse(draw, int(positions[i]), y, HORSE_COLORS[i % len(HORSE_COLORS)], horse, font)

        draw.text((300, 10), "RACE FINISHED!", fill="#00ff00", font=title_font)
        frames.append(img)

    frames[0].save(output_path, save_all=True, append_images=frames[1:], duration=80, loop=0)
    return finishing_order


if __name__ == "__main__":
    # Test the generators
    test_horses = ["whorse", "thundercunt", "horsemasheen", "gluestick", "neigh_sayer", "trotter"]

    print("Generating betting GIF...")
    generate_betting_gif(test_horses, "test_betting.gif")

    print("Generating race GIF...")
    results = generate_race_gif(test_horses, "test_race.gif")
    print(f"Race results: {results}")
