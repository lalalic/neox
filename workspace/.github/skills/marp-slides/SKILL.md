---
name: marp-slides
description: Create slide presentations from Markdown. Use when the user wants to make slides, a presentation, a deck, or a slideshow. Outputs Markdown files that can be rendered as slides.
---

# Marp Slides

Create slide presentations using Markdown syntax. Each slide is separated by `---`.

## Slide Format

```markdown
---
marp: true
theme: default
paginate: true
---

# Title Slide

Your presentation subtitle

---

## Second Slide

- Point one
- Point two
- Point three

---

## Slide with Image

![bg right:40%](image-url.jpg)

Content on the left side

---

## Slide with Table

| Feature | Status |
|---------|--------|
| Login   | Done   |
| Profile | WIP    |

---

# Thank You!

Questions?
```

## Key Syntax

### Slide Separation
Use `---` on its own line to start a new slide.

### Background Images
```markdown
![bg](image.jpg)              # Full background
![bg right:40%](image.jpg)    # Right side, 40% width
![bg left:50%](image.jpg)     # Left side, 50% width
![bg contain](image.jpg)      # Fit inside slide
![bg cover](image.jpg)        # Cover entire slide
```

### Text Styling
```markdown
**Bold text**
*Italic text*
~~Strikethrough~~
`inline code`
```

### Themes
Set in frontmatter: `theme: default`, `theme: gaia`, or `theme: uncover`

### Pagination
`paginate: true` adds page numbers to all slides.

### Custom Styles
```markdown
---
marp: true
style: |
  section {
    font-family: 'Arial', sans-serif;
    background: #1a1a2e;
    color: #eee;
  }
  h1 { color: #e94560; }
---
```

## Tips

1. Keep slides simple — one idea per slide
2. Use bullet points, not long paragraphs
3. Add images for visual impact
4. Limit to 5-7 words per bullet point
5. Save as `.md` file in the project

## Output

Save the slide markdown as `slides.md` or `presentation.md` in the project folder.

**On-device preview:** Open the saved `.md` file — Marp syntax renders natively in the markdown viewer as formatted slide content (headings, bullets, images). Each `---` separator marks a new slide.

**For full slide rendering (PDF/PPTX/HTML):** Use the `make-app` skill to create a project with Marp CLI, or share the `.md` file to a computer and run `npx @marp-team/marp-cli slides.md --pdf`.
