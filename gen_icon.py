from PIL import Image, ImageDraw, ImageFont
import math

size = 1024
img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Background: near-black with subtle blue undertone
for y in range(size):
    t = y / size
    r = int(8 + 4 * t)
    g = int(8 + 4 * t)
    b = int(16 + 8 * t)
    draw.line([(0, y), (size - 1, y)], fill=(r, g, b))

# Neon glow center — magenta/purple
for radius in range(350, 0, -1):
    alpha = int(25 * (1 - radius / 350))
    cx, cy = 512, 460
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(180, 0, 255, alpha)
    )

# Secondary glow — electric cyan offset
for radius in range(200, 0, -1):
    alpha = int(15 * (1 - radius / 200))
    cx, cy = 520, 430
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(0, 255, 240, alpha)
    )

# Draw a stylized "N" — the Neo mark
def draw_thick_line(draw, x1, y1, x2, y2, width, fill):
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

# Neon N — electric cyan with magenta shadow
n_cyan = (0, 255, 240, 255)
n_magenta = (255, 0, 180, 100)
n_glow_cyan = (0, 255, 240, 40)
n_glow_magenta = (255, 0, 180, 30)
w = 56

# Magenta shadow (offset down-right)
off = 8
draw_thick_line(draw, 310+off, 690+off, 310+off, 260+off, w, n_magenta)
draw_thick_line(draw, 310+off, 260+off, 710+off, 690+off, w, n_magenta)
draw_thick_line(draw, 710+off, 690+off, 710+off, 260+off, w, n_magenta)

# Outer glow (cyan, wide)
draw_thick_line(draw, 310, 690, 310, 260, w + 40, n_glow_cyan)
draw_thick_line(draw, 310, 260, 710, 690, w + 40, n_glow_cyan)
draw_thick_line(draw, 710, 690, 710, 260, w + 40, n_glow_cyan)

# Inner glow
draw_thick_line(draw, 310, 690, 310, 260, w + 16, n_glow_magenta)
draw_thick_line(draw, 310, 260, 710, 690, w + 16, n_glow_magenta)
draw_thick_line(draw, 710, 690, 710, 260, w + 16, n_glow_magenta)

# Main N strokes — bright cyan
draw_thick_line(draw, 310, 690, 310, 260, w, n_cyan)
draw_thick_line(draw, 310, 260, 710, 690, w, n_cyan)
draw_thick_line(draw, 710, 690, 710, 260, w, n_cyan)

# Neon dot accents — small glowing orbs
dots = [
    (180, 180, 8, (255, 0, 180, 200)),
    (840, 170, 6, (0, 255, 240, 180)),
    (170, 830, 5, (0, 255, 240, 160)),
    (850, 840, 7, (255, 0, 180, 180)),
    (140, 480, 4, (255, 0, 180, 140)),
    (880, 500, 5, (0, 255, 240, 140)),
    (500, 140, 6, (255, 0, 180, 160)),
    (500, 880, 5, (0, 255, 240, 150)),
]
for cx, cy, r, color in dots:
    # Glow halo
    for gr in range(r * 4, 0, -1):
        a = int(color[3] * 0.15 * (1 - gr / (r * 4)))
        draw.ellipse([cx-gr, cy-gr, cx+gr, cy+gr], fill=(color[0], color[1], color[2], a))
    # Core dot
    draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=color)

# Thin neon lines connecting dots to N
line_colors = [(0, 255, 240, 30), (255, 0, 180, 30)]
draw.line([(180, 180), (310, 260)], fill=line_colors[0], width=1)
draw.line([(840, 170), (710, 260)], fill=line_colors[1], width=1)
draw.line([(170, 830), (310, 690)], fill=line_colors[0], width=1)
draw.line([(850, 840), (710, 690)], fill=line_colors[1], width=1)

# Save
out_dir = "/Users/chengli/Workspace/free2/neox/Neox/Assets.xcassets/AppIcon.appiconset"
import os
os.makedirs(out_dir, exist_ok=True)
img.save(f"{out_dir}/AppIcon.png")
print(f"Icon saved to {out_dir}/AppIcon.png")
