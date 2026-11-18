# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26,<3", "opencv-python-headless>=4.10,<5", "Pillow>=11,<14", "pillow-heif>=1,<2"]
# ///
"""Prepare a color scan for handwriting and diagram recognition."""

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener


def order_corners(points):
    center = points.mean(axis=0)
    angles = np.arctan2(points[:, 1] - center[1], points[:, 0] - center[0])
    ordered = points[np.argsort(angles)]
    return np.roll(ordered, -int(np.argmin(ordered.sum(axis=1))), axis=0)


def contour_candidates(gray):
    local = cv2.createCLAHE(clipLimit=2.4, tileGridSize=(8, 8)).apply(gray)
    low_edges = cv2.Canny(gray, 22, 76)
    local_edges = cv2.Canny(local, 40, 116)
    _, light = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)
    kernel = np.ones((5, 5), np.uint8)
    masks = (
        cv2.morphologyEx(low_edges, cv2.MORPH_CLOSE, kernel),
        cv2.morphologyEx(local_edges, cv2.MORPH_CLOSE, kernel),
        cv2.morphologyEx(light, cv2.MORPH_CLOSE, kernel),
        cv2.morphologyEx(cv2.bitwise_not(light), cv2.MORPH_CLOSE, kernel),
    )
    for mask in masks:
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:28]:
            if cv2.contourArea(contour) < gray.size * 0.095:
                break
            perimeter = cv2.arcLength(contour, True)
            for epsilon in (0.012, 0.022, 0.031):
                quad = cv2.approxPolyDP(contour, epsilon * perimeter, True)
                if len(quad) == 4 and cv2.isContourConvex(quad):
                    yield order_corners(quad.reshape(4, 2).astype(np.float32))
                    break


def gradient_support(lab, corners, length_scale):
    """Measure sustained color changes across each side, outside printed ink."""
    height, width = lab.shape[:2]
    sample_distance = max(5, length_scale * 0.012)
    scores = []
    for start, end in zip(corners, np.roll(corners, -1, axis=0)):
        side = end - start
        length = np.linalg.norm(side)
        direction = np.array([-side[1], side[0]]) / length
        samples = start + np.linspace(0.12, 0.88, 24)[:, None] * side
        inner = np.rint(samples + direction * sample_distance).astype(int)
        outer = np.rint(samples - direction * sample_distance).astype(int)
        valid = ((inner >= 0) & (inner < [width, height]) &
                 (outer >= 0) & (outer < [width, height])).all(axis=1)
        if valid.sum() < 12:
            scores.append(0.0)
            continue
        inner, outer = inner[valid], outer[valid]
        difference = lab[inner[:, 1], inner[:, 0]] - lab[outer[:, 1], outer[:, 0]]
        strength = np.linalg.norm(difference, axis=1)
        # Compare neighborhoods behind the stroke so figure borders do not look like sheet edges.
        scores.append(float(np.mean(np.clip((strength - 5) / 23, 0, 1))))
    return scores


def score_page(lab, corners, is_document, confidence):
    height, width = lab.shape[:2]
    smaller = min(height, width)
    area = cv2.contourArea(corners) / (width * height)
    if not 0.095 <= area <= 0.94 or not cv2.isContourConvex(corners):
        return None

    sides = np.linalg.norm(np.roll(corners, -1, axis=0) - corners, axis=1)
    if sides.min() < 0.20 * smaller:
        return None
    short, long = sorted(((sides[0] + sides[2]) * 0.5, (sides[1] + sides[3]) * 0.5))
    if short / long < 0.37:
        return None

    # Reject frame edges: a missing paper corner cannot be recovered reliably.
    margin = max(3, smaller * 0.007)
    if (corners < margin).any() or (corners > [width - margin, height - margin]).any():
        return None

    evidence = gradient_support(lab, corners, smaller)
    supported = sum(strength >= 0.28 for strength in evidence)
    if supported < (2 if is_document else 3):
        return None

    location = corners.mean(axis=0) / [width, height]
    centered = max(0, 1 - np.linalg.norm(location - [0.5, 0.55]) * 2)
    border = 0.66 * np.mean(sorted(evidence)[1:]) + 0.34 * np.mean(evidence)
    size_bonus = min(area / 0.48, 1)
    # Sample the interior to distinguish a sheet from a contour wrapping unrelated objects.
    axis = np.linspace(0.13, 0.87, 9)
    across, down = np.meshgrid(axis, axis)
    top = corners[0] + across.reshape(-1, 1) * (corners[1] - corners[0])
    bottom = corners[3] + across.reshape(-1, 1) * (corners[2] - corners[3])
    sample = np.rint(top + down.reshape(-1, 1) * (bottom - top)).astype(int)
    lightness = lab[sample[:, 1], sample[:, 0], 0]
    spread = np.percentile(lightness, 88) - np.percentile(lightness, 12)
    varied_surface = np.clip((spread - 36) / 100, 0, 1)
    sheet_proportion = 1 - min(abs((short / long) - 0.72) / 0.45, 1)
    score = 0.65 * border + 0.18 * centered + 0.06 * size_bonus + 0.05 * sheet_proportion
    score -= 0.25 * varied_surface
    # A semantic candidate can resolve a weak binding edge, but still needs border support.
    if is_document:
        score += 0.16 * confidence
    credible = supported >= 3 and varied_surface < 0.85 and (border >= 0.54 or (is_document and border >= 0.44))
    return score, credible


def find_pages(rgb, seeds=()):
    height, width = rgb.shape[:2]
    scale = min(1.0, 1150 / max(height, width))
    preview = cv2.resize(rgb, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    h, w = preview.shape[:2]
    gray = cv2.GaussianBlur(cv2.cvtColor(preview, cv2.COLOR_RGB2GRAY), (5, 5), 0)
    lab = cv2.GaussianBlur(cv2.cvtColor(preview, cv2.COLOR_RGB2LAB), (5, 5), 0).astype(np.float32)
    raw = [(corners, False, 0) for corners in contour_candidates(gray)]
    for seed in seeds:
        points = np.asarray(seed["points"], dtype=np.float32)
        if points.shape == (4, 2) and np.isfinite(points).all() and (points >= 0).all() and (points <= 1).all():
            corners = order_corners((points * [w - 1, h - 1]).astype(np.float32))
            raw.append((corners, seed["document"], seed["confidence"]))

    ranked = []
    for corners, document, confidence in raw:
        score = score_page(lab, corners, document, confidence)
        if score is not None:
            ranked.append((score[0], score[1], corners))
    ranked.sort(key=lambda item: item[0], reverse=True)

    unique = []
    for score, credible, corners in ranked:
        if any(np.linalg.norm(corners - previous[2], axis=1).mean() < min(h, w) * 0.037
               for previous in unique):
            continue
        unique.append((score, credible, corners))
        if len(unique) == 3:
            break

    resize = [(width - 1) / (w - 1), (height - 1) / (h - 1)]
    choices = [(item[2] * resize).astype(np.float32) for item in unique]
    # Leave the full frame when two distinct, similarly plausible surfaces compete.
    best = None
    if unique and unique[0][1] and (len(unique) < 2 or unique[0][0] - unique[1][0] >= 0.085):
        best = choices[0]
    return best, choices


def rectify(rgb, corners, *, with_margin=False):
    top_left, top_right, bottom_right, bottom_left = corners
    width = round(max(np.linalg.norm(top_right - top_left),
                      np.linalg.norm(bottom_right - bottom_left))) + 1
    height = round(max(np.linalg.norm(bottom_left - top_left),
                       np.linalg.norm(bottom_right - top_right))) + 1
    margin = max(3, round(min(width, height) * 0.01))
    target = np.float32([[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]])
    transform = cv2.getPerspectiveTransform(corners, target + margin)
    page = cv2.warpPerspective(rgb, transform, (width + 2 * margin, height + 2 * margin),
                               flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    return (page, margin) if with_margin else page


def boost_contrast(rgb):
    lightness, a, b = cv2.split(cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB))
    adjusted = cv2.createCLAHE(clipLimit=1.7, tileGridSize=(8, 8)).apply(lightness)
    blended = cv2.addWeighted(lightness, 0.65, adjusted, 0.35, 0)
    return cv2.cvtColor(cv2.merge((blended, a, b)), cv2.COLOR_LAB2RGB)


def blank_margin_bounds(rgb):
    """Find substantial, uniform light margins while leaving room around every mark."""
    height, width = rgb.shape[:2]
    sample = max(4, round(min(height, width) * 0.025))
    corners = np.concatenate([
        rgb[:sample, :sample].reshape(-1, 3), rgb[:sample, -sample:].reshape(-1, 3),
        rgb[-sample:, :sample].reshape(-1, 3), rgb[-sample:, -sample:].reshape(-1, 3),
    ])
    paper = np.rint(np.median(corners, axis=0)).astype(int)
    if paper.min() < 210 or np.ptp(paper) > 32:
        return None

    lower = tuple(int(value) for value in np.maximum(paper - 3, 0))
    upper = tuple(int(value) for value in np.minimum(paper + 3, 255))
    marks = cv2.bitwise_not(cv2.inRange(rgb, lower, upper))
    if cv2.countNonZero(marks) < 12:
        return None
    x, y, content_width, content_height = cv2.boundingRect(marks)
    padding = max(18, round(min(height, width) * 0.035))
    left, top = max(0, x - padding), max(0, y - padding)
    right = min(width, x + content_width + padding)
    bottom = min(height, y + content_height + padding)
    if (right - left) * (bottom - top) > 0.88 * width * height:
        return None
    return {"left": left, "top": top, "right": right, "bottom": bottom}


def prepare(source, straighten=True, enhance=False, manual_corners=None, *, with_corners=False,
            with_report=False, vision_seeds=(), trim=False, detect_only=False):
    register_heif_opener()
    with Image.open(source) as original:
        rgb = np.array(ImageOps.exif_transpose(original).convert("RGB"))
    if min(rgb.shape[:2]) < 32:
        raise ValueError("图像宽和高都需要至少 32 像素。")

    height, width = rgb.shape[:2]
    scale = np.array([width - 1, height - 1])
    corners = None
    choices = []
    if manual_corners is not None:
        normalized = np.array(manual_corners, dtype=np.float32).reshape(4, 2)
        if not np.isfinite(normalized).all() or (normalized < 0).any() or (normalized > 1).any():
            raise ValueError("角点坐标必须在 0 到 1 之间。")
        corners = (normalized * scale).astype(np.float32)
        if not cv2.isContourConvex(corners) or cv2.contourArea(corners, oriented=True) < width * height * 0.004:
            raise ValueError("四个角点需要按顺时针排列且不能交叉。")
    elif straighten:
        corners, choices = find_pages(rgb, vision_seeds)
    corner_report = (np.clip(corners / scale, 0, 1).tolist() if corners is not None else None)
    margin = 0
    if corners is not None and not detect_only:
        rgb, margin = rectify(rgb, corners, with_margin=True)
    bounds = None
    if trim and not detect_only and (corners is not None or not straighten):
        # Context pixels added by the perspective transform are outside the selected paper.
        paper = rgb[margin:-margin, margin:-margin] if margin else rgb
        bounds = blank_margin_bounds(paper)
        if bounds is not None:
            bounds = {edge: value + margin for edge, value in bounds.items()}
            rgb = rgb[bounds["top"]:bounds["bottom"], bounds["left"]:bounds["right"]]
    if enhance and not detect_only:
        rgb = boost_contrast(rgb)
    photo = None if detect_only else Image.fromarray(rgb)
    if with_report:
        return photo, {"corners": corner_report,
                       "trimBounds": bounds,
                       "suggestions": [np.clip(choice / scale, 0, 1).tolist() for choice in choices]}
    return photo, corner_report if with_corners else corners is not None


def save_png(photo, output, *, compress_level=6):
    with output.open("xb") as target:
        try:
            photo.save(target, format="PNG", compress_level=compress_level)
        except OSError:
            target.close()
            output.unlink(missing_ok=True)
            raise


def prepare_batch(manifest):
    results = []
    for job in json.loads(manifest.read_text()):
        try:
            photo, report = prepare(Path(job["source"]), straighten=job["straighten"],
                                    enhance=job["enhance"], manual_corners=job.get("corners"),
                                    with_report=True, trim=job["trim"], detect_only=job["detectOnly"])
            if photo is not None and (report["corners"] is not None or report["trimBounds"] or job["enhance"]):
                save_png(photo, Path(job["output"]), compress_level=2)
            results.append(report)
        except (OSError, ValueError, cv2.error) as error:
            results.append({"error": str(error)})
    return results


def main():
    parser = argparse.ArgumentParser(description="对纸稿照片进行本地裁正，输出彩色 PNG。")
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--batch", type=Path, help="按输入清单批量处理纸稿，输出每页的 JSON 结果")
    parser.add_argument("--no-rectify", action="store_true", help="保留完整画面，适合已扫描的页面")
    parser.add_argument("--enhance", action="store_true", help="轻调局部亮度对比度")
    parser.add_argument("--trim", action="store_true", help="裁掉明显的外围留白")
    parser.add_argument("--corners", type=float, nargs=8,
                        help="左上、右上、右下、左下的归一化 x y 坐标")
    parser.add_argument("--report", action="store_true", help="输出归一化角点 JSON")
    parser.add_argument("--vision-seeds", type=Path, help="读取本地文稿检测的角点建议")
    parser.add_argument("--crop", type=int, nargs=4, metavar=("L", "T", "R", "B"),
                        help="在裁正后的页面中按像素坐标裁取局部")
    args = parser.parse_args()
    if args.batch:
        if args.source or args.output:
            parser.error("--batch 不能与单张输入和输出同时使用。")
        try:
            print(json.dumps(prepare_batch(args.batch)))
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0
    if args.source is None or args.output is None:
        parser.error("单张处理需要指定输入和输出文件。")
    if args.output.suffix.lower() != ".png":
        parser.error("输出文件需要使用 .png 后缀。")
    if args.output.exists():
        parser.error("输出文件已存在，请指定另一个文件名。")
    if args.no_rectify and args.corners:
        parser.error("--no-rectify 和 --corners 只能选一项。")
    try:
        seeds = json.loads(args.vision_seeds.read_text()) if args.vision_seeds else ()
        photo, report = prepare(args.source, not args.no_rectify, args.enhance, args.corners,
                                with_report=True, vision_seeds=seeds, trim=args.trim)
        if args.crop:
            left, top, right, bottom = args.crop
            if not (0 <= left < right <= photo.width and 0 <= top < bottom <= photo.height):
                raise ValueError("局部裁剪坐标超出了页面范围。")
            photo = photo.crop(tuple(args.crop))
        save_png(photo, args.output)
    except (OSError, ValueError, cv2.error) as error:
        print(error, file=sys.stderr)
        return 1

    if args.report:
        print(json.dumps(report))
    else:
        result = "rectified" if report["corners"] is not None else ("trimmed" if report["trimBounds"] else "full-frame")
        print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
