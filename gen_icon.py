from PIL import Image, ImageDraw, ImageFont
import math

size = 1024
img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Background: dark teal → deep navy gradient (AI citizen, futuristic)
for y in range(size):
    t = y / size
    r = int(10 + (15 - 10) * t)
    g = int(25 + (20 - 25) * t)
    b = int(50 + (70 - 50) * t)
    draw.line([(0, y), (size - 1, y)], fill=(r, g, b))

# Subtle radial glow in center
for radius in range(300, 0, -1):
    alpha = int(40 * (1 - radius / 300))
    cx, cy = 512, 450
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(0, 200, 180, alpha)
    )

# Draw a stylized "N" — the Neo mark
# Using thick geometric lines for a clean, modern look
def draw_thick_line(draw, x1, y1, x2, y2, width, fill):
    """Draw a line with given width using polygon."""
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx*dx + dy*dy)
    if length == 0:
        return
    nx = -dy / length * width / 2
    ny = dx / length * width / 2
    points = [
        (x1 + nx, y1 + ny),
        (x1 - nx, y1 - ny),
        (x2 - nx, y2 - ny),
        (x2 + nx, y2 + ny),
    ]
    draw.polygon(points, fill=fill)

# "N" letter — geometric, bold
n_color = (0, 240, 210, 240)  # Cyan/teal
n_glow = (0, 200, 180, 60)
w = 60  # stroke width

# Left vertical
draw_thick_line(draw, 300, 680, 300, 250, w, n_color)
# Diagonal
draw_thick_line(draw, 300, 250, 700, 680, w, n_color)
# Right vertical
draw_thick_line(draw, 700, 680, 700, 250, w, n_color)

# Glow effect behind the N (thicker, semi-transparent)
draw_thick_line(draw, 300, 680, 300, 250, w + 30, n_glow)
draw_thick_line(draw, 300, 250, 700, 680, w + 30, n_glow)
draw_thick_line(draw, 700, 680, 700, 250, w + 30, n_glow)

# Re-draw the N on top of glow
draw_thick_line(draw, 300, 680, 300, 250, w, n_color)
draw_thick_line(draw, 300, 250, 700, 680, w, n_color)
draw_thick_line(draw, 700, 680, 700, 250, w, n_color)

# Small circuit/dot accents — AI feel
dot_color = (0, 240, 210, 180)
for cx, cy, r in [(200, 200, 6), (820, 180, 5), (180, 800, 4),
                   (830, 820, 7), (150, 500, 3), (870, 500, 4),
                   (500, 150, 5), (500, 870, 4)]:
    draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=dot_color)

# Thin circuit lines connecting some dots
line_color = (0, 200, 180, 40)
draw.line([(200, 200), (300, 250)], fill=line_color, width=2)
draw.line([(820, 180), (700, 250)], fill=line_color, width=2)
draw.line([(180, 800), (300, 680)], fill=line_color, width=2)
draw.line([(830, 820), (700, 680)], fill=line_color, width=2)

# Small "neo" text at bottom
try:
    small_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 48)
except:
    small_font = ImageFont.load_default()

draw.text((512, 820), "NEO", fill=(0, 240, 210, 120), font=small_font, anchor="mm")

# Save full-size (iOS handles rounding)
out_dir = "/Users/chengli/Workspace/free2/neox/Neox/Assets.xcassets/AppIcon.appiconset"
import os
os.makedirs(out_dir, exist_ok=True)
img.save(f"{out_dir}/AppIcon.png")
print(f"Icon saved to {out_dir}/AppIcon.png")
