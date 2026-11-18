"""Transcribe a selected region or detect formula and plot regions in a page."""

import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from mlx_vlm import load, stream_generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_model
from PIL import Image


def as_markdown(text, kind):
    if not text:
        raise ValueError("No text returned")
    if kind == "formula":
        for left, right in (("\\[", "\\]"), ("$$", "$$"), ("\\(", "\\)")):
            if text.startswith(left) and text.endswith(right):
                text = text[len(left):-len(right)].strip()
                break
        if not text:
            raise ValueError("Empty formula")
        return "$$\n" + text + "\n$$"

    rows = []
    for line in text.splitlines():
        if "|" not in line:
            continue
        cells = [value.strip() for value in line.strip().strip("|").split("|")]
        if len(cells) == 2 and all(cells) and all(set(cell) <= {"-", ":"} for cell in cells):
            continue
        if len(cells) == 2 and all(cells):
            rows.append([cell.replace("<", "&lt;").replace(">", "&gt;") for cell in cells])
    if len(rows) < 2:
        raise ValueError("No chart data table returned")
    rows.insert(1, ["---", "---"])
    return "\n".join("| " + " | ".join(row) + " |" for row in rows)


def transcribe(model, processor, image, kind):
    task = "Formula Recognition:" if kind == "formula" else "Chart Recognition:"
    prompt = apply_chat_template(processor, model.config, task, num_images=1)
    chunks = stream_generate(model, processor, prompt, image=[image], max_tokens=512, temperature=0.0)
    return as_markdown("".join(chunk.text for chunk in chunks).strip(), kind)


def has_plot_axes(crop):
    """Require roughly perpendicular axes before treating a detected chart as data."""
    width, height = crop.size
    grey = np.array(crop.convert("L"))
    edges = cv2.Canny(grey, 45, 135)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, 24,
                           minLineLength=max(20, round(min(width, height) * 0.28)), maxLineGap=14)
    if lines is None:
        return False
    _, ink = cv2.threshold(grey, 0, 255, cv2.THRESH_BINARY_INV | cv2.THRESH_OTSU)
    ink = cv2.dilate(ink, np.ones((1, max(3, round(width * 0.012))), dtype=np.uint8))
    for x0, y0, x1, y1 in lines.reshape(-1, 4):
        left, bottom = min(x0, x1), round((y0 + y1) / 2)
        if abs(x1 - x0) < width * 0.42 or abs(y1 - y0) > height * 0.08 or bottom < height * 0.50:
            continue
        reach = round(width * 0.13)
        run = ink[max(0, bottom - round(height * 0.60)):bottom, max(0, left - reach):left + reach + 1]
        if run.size and np.count_nonzero(run, axis=0).max() >= height * 0.37:
            return True
    return False


def automatic_regions(model_path, input_path):
    detector = load_model(model_path.parent / "pp-doclayout-v3")
    detector.eval()
    with Image.open(input_path) as source:
        image = source.convert("RGB")
    width, height = image.size
    targets = []
    types = {"display_formula": "formula", "formula": "formula", "chart": "chart"}
    for detection in detector.detect(image, conf=0.55):
        kind = types.get(detection["label"])
        if not kind:
            continue
        top, left, bottom, right = [min(1000, max(0, value)) / 1000 for value in detection["bbox"]]
        bounds = (round(left * width), round(top * height), round(right * width), round(bottom * height))
        if bounds[2] - bounds[0] < 32 or bounds[3] - bounds[1] < 32:
            continue
        fraction = 0.14 if kind == "chart" else 0.06
        padding = max(4, round(min(bounds[2] - bounds[0], bounds[3] - bounds[1]) * fraction))
        crop = image.crop((max(0, bounds[0] - padding), max(0, bounds[1] - padding),
                           min(width, bounds[2] + padding), min(height, bounds[3] + padding)))
        if kind == "chart" and not has_plot_axes(crop):
            continue
        targets.append((kind, crop, left, top, right, bottom))
    if not targets:
        return []
    model, processor = load(model_path, trust_remote_code=False)
    recognized = []
    for kind, crop, left, top, right, bottom in targets:
        try:
            markdown = transcribe(model, processor, crop, kind)
            recognized.append({"x": left, "y": top, "width": right - left, "height": bottom - top,
                               "markdown": markdown})
        except ValueError:
            continue
    return recognized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    parser.add_argument("image", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("kind", choices=["formula", "chart", "auto"])
    args = parser.parse_args()
    if args.kind == "auto":
        result = automatic_regions(args.model, args.image)
    else:
        model, processor = load(args.model, trust_remote_code=False)
        result = {"markdown": transcribe(model, processor, str(args.image), args.kind)}
    args.output.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
