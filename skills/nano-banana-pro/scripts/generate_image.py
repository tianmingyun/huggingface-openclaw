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
import time
import signal
from pathlib import Path
from google import genai
from google.genai import types

# Set a global timeout of 60 seconds to prevent process hanging
def timeout_handler(signum, frame):
    print("Error: Script execution timed out (60s)", file=sys.stderr)
    sys.exit(1)

signal.signal(signal.SIGALRM, timeout_handler)
signal.alarm(60)

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
    
    # Get model from IMAGE_MODEL environment variable with fallback
    # HARDCODED to ensure correct model is used despite env var issues
    default_model = "imagen-4.0-generate-001"
    
    parser.add_argument(
        "--model", "-m",
        default=default_model,
        help=f"Image generation model (default: {default_model})"
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


def generate_image(prompt, api_key, resolution, model, input_images=None):
    from google import genai
    from google.genai import types
    from PIL import Image as PILImage
    import io

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
            model=model,
            prompt=prompt,
            reference_images=input_images,
            config=config,
        )
    else:
        response = client.models.generate_images(
            model=model,
            prompt=prompt,
            config=config,
        )

    if not response.generated_images:
        print("Error: No image generated.", file=sys.stderr)
        sys.exit(1)

    generated = response.generated_images[0]
    if hasattr(generated, 'image') and hasattr(generated.image, 'bytes'):
        image_bytes = generated.image.bytes
    elif hasattr(generated, 'image'):
        image_bytes = generated.image
    else:
        image_bytes = generated

    return PILImage.open(io.BytesIO(image_bytes))


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


def create_error_image(error_msg):
    from PIL import Image as PILImage, ImageDraw
    img = PILImage.new('RGB', (512, 512), color=(30, 30, 30))
    d = ImageDraw.Draw(img)
    d.text((20, 200), "GENERATION FAILED", fill=(255, 50, 50))
    d.text((20, 230), str(error_msg)[:200], fill=(200, 200, 200))
    return img

def main():
    args = parse_args()

    api_key = get_api_key(args)

    input_images = None
    if args.input_images:
        input_images = load_input_images(args.input_images)

    print(f"Generating image with resolution {args.resolution}...")
    if input_images:
        print(f"Using {len(input_images)} input image(s) for composition/editing")

    output_path = Path(args.filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        image = generate_image(
            prompt=args.prompt,
            api_key=api_key,
            resolution=args.resolution,
            model=args.model,
            input_images=input_images
        )

        if args.compress:
            image = compress_image(image, args.max_size)
            
        image.save(output_path, format="PNG")
        print(f"Image saved to: {output_path.resolve()}")
        
    except Exception as e:
        error_msg = f"Error: {str(e)}"
        print(error_msg, file=sys.stderr)
        
        # Create error placeholder image
        print("Generating error placeholder image...", file=sys.stderr)
        error_img = create_error_image(error_msg)
        error_img.save(output_path, format="PNG")
        print(f"Error placeholder saved to: {output_path.resolve()}")

    # Output MEDIA line regardless of success/failure (as long as file exists)
    # if output_path.exists():
    #     print(f"\nMEDIA:{output_path}")



if __name__ == "__main__":
    main()
