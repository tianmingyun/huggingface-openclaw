---
name: nano-banana-pro
description: Generate or edit images via Gemini 3 Pro Image (Nano Banana Pro).
homepage: https://ai.google.dev/
metadata:
  openclaw:
    emoji: "🍌"
    requires:
      bins:
        - uv
      env:
        - GEMINI_API_KEY
    primaryEnv: GEMINI_API_KEY
    triggers:
      - generate an image
      - create an image
      - edit an image
      - draw me
      - make a picture
---

# Nano Banana Pro (Gemini 3 Pro Image)

Use the bundled script to generate or edit images.

## Generate

```bash
uv run {baseDir}/scripts/generate_image.py --prompt "your image description" --filename "output.png" --resolution 1K
```

## Edit (single image)

```bash
uv run {baseDir}/scripts/generate_image.py --prompt "edit instructions" --filename "output.png" -i "/path/in.png" --resolution 2K
```

## Multi-image composition (up to 14 images)

```bash
uv run {baseDir}/scripts/generate_image.py --prompt "combine these into one scene" --filename "output.png" -i img1.png -i img2.png -i img3.png
```

## API key

- `GEMINI_API_KEY` env var
- Or set `skills."nano-banana-pro".apiKey` / `skills."nano-banana-pro".env.GEMINI_API_KEY` in `~/.openclaw/openclaw.json`

## Output Format (IMPORTANT)

After generating an image, you MUST output a `MEDIA:` line to send the image to the chat:

```
MEDIA:./output.png
```

**Rules:**
- Use **relative path** starting with `./` (e.g., `MEDIA:./image.png`)
- The path is relative to your workspace directory
- NEVER use absolute paths like `/home/node/...`
- Output this line on its own line after describing the generated image

## Notes

- Resolutions: `1K` (default), `2K`, `4K`.
- Use timestamps in filenames: `yyyy-mm-dd-hh-mm-ss-name.png`.
- Start with 1K for fast iteration, then switch to 2K or 4K for final outputs.
- Always output `MEDIA:./filename.png` to send the image to the chat.
