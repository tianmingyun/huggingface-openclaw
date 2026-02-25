#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "google-genai>=1.0.0",
#   "pillow>=10.0.0",
# ]
# ///
"""
Generate images using Google's Nano Banana Pro (Gemini 3 Pro Image) API.

Usage:
    uv run generate_image.py --prompt "your image description" --filename "output.png" [--resolution 1K|2K|4K] [--api-key KEY] [--compress] [--max-size MB]
"""

import argparse
import os
import sys
import base64
import tempfile
from pathlib import Path
from datetime import datetime


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate images using Nano Banana Pro (Gemini 3 Pro Image)"
    )
    parser.add_argument(
        "--prompt", "-p",
        required=True,
        help="Image description/prompt"
    )
    parser.add_argument(
        "--filename", "-f",
        required=True,
        help="Output filename (e.g., sunset-mountains.png)"
    )
    parser.add_argument(
        "--resolution", "-r",
        choices=["1K", "2K", "4K"],
        default="1K",
        help="Output resolution (default: 1K)"
    )
    parser.add_argument(
        "--api-key",
        help="Gemini API key (or set GEMINI_API_KEY env var)"
    )
    parser.add_argument(
        "--input-image", "-i",
        action="append",
        dest="input_images",
        help="Input image(s) for editing (can be used multiple times, up to 14)"
    )
    parser.add_argument(
        "--compress",
        action="store_true",
        help="Compress output image to reduce file size"
    )
    parser.add_argument(
        "--max-size",
        type=float,
        default=10.0,
        help="Max output size in MB when compressing (default: 10.0)"
    )
    return parser.parse_args()


def get_api_key(args):
    key = args.api_key or os.environ.get("GEMINI_API_KEY")
    if not key:
        print("Error: No API key provided.", file=sys.stderr)
        print("Set GEMINI_API_KEY environment variable or use --api-key", file=sys.stderr)
        sys.exit(1)
    return key


def load_input_images(image_paths):
    from PIL import Image as PILImage
    images = []
    for path in image_paths:
        if not os.path.exists(path):
            print(f"Error: Input image not found: {path}", file=sys.stderr)
            sys.exit(1)
        img = PILImage.open(path)
        images.append(img)
    return images


def generate_image(prompt, api_key, resolution, input_images=None):
    from google import genai
    from google.genai import types

    client = genai.Client(api_key=api_key)

    config = types.GenerateImagesConfig(
        number_of_images=1,
    )

    if resolution == "1K":
        pass
    elif resolution == "2K":
        pass
    elif resolution == "4K":
        pass

    if input_images:
        if len(input_images) > 14:
            print("Error: Maximum 14 input images allowed.", file=sys.stderr)
            sys.exit(1)

        response = client.models.generate_images(
            model="imagen-3.0-generate-002",
            prompt=prompt,
            reference_images=input_images,
            config=config,
        )
    else:
        response = client.models.generate_images(
            model="imagen-3.0-generate-002",
            prompt=prompt,
            config=config,
        )

    if not response.generated_images:
        print("Error: No image generated.", file=sys.stderr)
        sys.exit(1)

    return response.generated_images[0].image


def compress_image(image, max_size_mb=10.0):
    from PIL import Image as PILImage
    import io

    max_bytes = int(max_size_mb * 1024 * 1024)
    quality = 95

    while quality >= 10:
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", optimize=True)
        if buffer.tell() <= max_bytes:
            buffer.seek(0)
            return PILImage.open(buffer)
        quality -= 5

    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    buffer.seek(0)
    return PILImage.open(buffer)


def main():
    args = parse_args()

    api_key = get_api_key(args)

    input_images = None
    if args.input_images:
        input_images = load_input_images(args.input_images)

    print(f"Generating image with resolution {args.resolution}...")
    if input_images:
        print(f"Using {len(input_images)} input image(s) for composition/editing")

    image = generate_image(
        prompt=args.prompt,
        api_key=api_key,
        resolution=args.resolution,
        input_images=input_images
    )

    if args.compress:
        image = compress_image(image, args.max_size)

    output_path = Path(args.filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    image.save(output_path, format="PNG")

    abs_path = output_path.resolve()
    print(f"Image saved to: {abs_path}")


if __name__ == "__main__":
    main()
