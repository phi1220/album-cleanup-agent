from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Protocol
from urllib.request import Request, urlopen
import base64

from PIL import Image, ImageDraw, ImageFilter, ImageOps, ImageStat, UnidentifiedImageError

EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}
BASE = {"burst_keep": 1, "burst_rank": "sharp", "copy_rank": "resolution"}
RANKS = {"sharp", "bright", "recent", "resolution"}
TIME_WINDOW = 8
SEMANTIC_GUIDANCE = (
    "Assess content value as well as duplicates and image quality. A standalone photo can be "
    "a cleanup candidate when visible evidence shows an accidental shot, no useful subject, "
    "unreadable content, or a disposable temporary record. Explain the visible evidence and "
    "why retaining it adds little value. Unknown personal meaning alone is not proof of low "
    "value. Preserve meaningful memories and useful documents; do not assume a record has "
    "expired or infer original-image blur from a thumbnail. The owner reviews all suggestions. "
)


def read_json(path, default):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        json.dump(data, out, ensure_ascii=False, indent=2)
        out.write("\n")
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def capture_time(image):
    from datetime import datetime

    exif = image.getexif()
    tags = exif.get_ifd(34665) if 34665 in exif else {}
    for value in (tags.get(36867), exif.get(306)):
        if value:
            try:
                return datetime.strptime(str(value), "%Y:%m:%d %H:%M:%S").timestamp()
            except ValueError:
                pass
    return None


def signature(image):
    pixels = list(image.resize((9, 8), Image.Resampling.LANCZOS).getdata())
    value = 0
    for y in range(8):
        for x in range(8):
            i = y * 9 + x
            value = (value << 1) | (pixels[i] > pixels[i + 1])
    return value


def local_ocr(path, command):
    result = subprocess.run(
        [command, str(path), "stdout"], capture_output=True, timeout=30, check=True
    )
    return result.stdout.decode("utf-8", errors="replace").strip()


def inspect_photo(root, path, state, ocr):
    relative = path.relative_to(root).as_posix()
    sha = digest(path)
    # Paths are distinct even when their image bytes are identical.
    photo_id = hashlib.sha256(relative.encode("utf-8")).hexdigest()[:16]
    thumb = state / "thumbs" / (sha + ".jpg")
    with Image.open(path) as opened:
        taken = capture_time(opened)
        image = ImageOps.exif_transpose(opened).convert("RGB")
    width, height = image.size
    small = image.copy()
    small.thumbnail((256, 256))
    grey = ImageOps.grayscale(small)
    sharp = round(ImageStat.Stat(grey.filter(ImageFilter.FIND_EDGES).crop(
        (1, 1, grey.width - 1, grey.height - 1)
    )).var[0], 2) if min(grey.size) > 2 else 0
    if not thumb.exists():
        thumb.parent.mkdir(parents=True, exist_ok=True)
        small.save(thumb, quality=85)
    name = path.stem.casefold().replace(" ", "").replace("_", "").replace("-", "")
    screenshot = "screenshot" in name or "screenrecord" in name or "截图" in name
    record = dict(id=photo_id, path=relative, sha=sha, taken=taken, hash=signature(grey),
                  sharp=sharp, bright=round(ImageStat.Stat(grey).mean[0], 2),
                  resolution=width * height, screenshot=screenshot, text="")
    record["aspect"] = width / height
    record["visual_sample"] = image.resize((12, 12), Image.Resampling.LANCZOS).tobytes().hex()
    if ocr and screenshot:
        cache = state / "ocr" / (sha + ".json")
        if cache.exists():
            record["text"] = read_json(cache, "")
        else:
            # OCR uses the original image to preserve small characters.
            try:
                record["text"] = local_ocr(path, ocr)
                write_json(cache, record["text"])
            except (OSError, subprocess.SubprocessError) as error:
                record["ocr_warning"] = type(error).__name__
    return record


def group_photos(photos):
    copies = {}
    for photo in photos:
        copies.setdefault(photo["sha"], []).append(photo)

    # Compare only representatives. Require similarity with every member
    # of a burst to avoid linking unrelated frames through a chain.
    units = sorted(copies.values(), key=lambda unit: (
        unit[0]["taken"] is None, unit[0]["taken"] or 0, unit[0]["path"]
    ))
    clusters = []
    for unit in units:
        head = unit[0]
        matching = None
        if head["taken"] is not None and not head["screenshot"]:
            for cluster in reversed(clusters):
                first = cluster[0][0]
                if first["taken"] is None or head["taken"] - first["taken"] > TIME_WINDOW:
                    break
                if first["screenshot"]:
                    continue
                if all((head["hash"] ^ other[0]["hash"]).bit_count() <= 9 for other in cluster):
                    matching = cluster
                    break
        if matching is None:
            clusters.append([unit])
        else:
            matching.append(unit)

    groups = [make_group(photo for unit in cluster for photo in unit)
              for cluster in clusters if len(cluster) > 1]
    unmatched = [cluster[0] for cluster in clusters if len(cluster) == 1]
    return groups + group_visual_copies(unmatched)


def group_visual_copies(units):
    """For photos without reliable time, match only near-identical full frames."""
    clusters = []
    # At most four differing bits guarantees one of five bands is identical.
    bands = {}
    samples = {}
    for unit in units:
        photo = unit[0]
        if photo["screenshot"] or "visual_sample" not in photo:
            clusters.append([unit])
            continue
        samples[photo["sha"]] = bytes.fromhex(photo["visual_sample"])
        keys = [(offset, (photo["hash"] >> offset) & 0x1FFF) for offset in range(0, 64, 13)]
        candidates = set().union(*(bands.get(key, ()) for key in keys))

        def matches(other):
            if photo["taken"] is not None and other["taken"] is not None:
                return False
            if (photo["hash"] ^ other["hash"]).bit_count() > 4:
                return False
            if max(photo["aspect"], other["aspect"]) / min(photo["aspect"], other["aspect"]) > 1.05:
                return False
            first, second = samples[photo["sha"]], samples[other["sha"]]
            return sum(abs(a - b) for a, b in zip(first, second)) <= 10 * len(first)

        for index in sorted(candidates):
            if all(matches(other[0]) for other in clusters[index]):
                clusters[index].append(unit)
                break
        else:
            index = len(clusters)
            clusters.append([unit])
        for key in keys:
            bands.setdefault(key, set()).add(index)
    return [make_group((p for unit in cluster for p in unit), multi_kind="similar")
            for cluster in clusters]


def make_group(photos, *, multi_kind="burst"):
    items = sorted(photos, key=lambda p: p["path"])
    kind = (multi_kind if len({p["sha"] for p in items}) > 1 else "copy" if len(items) > 1
            else "screenshot" if items[0]["screenshot"] else "single")
    key = "|".join(sorted(p["id"] + ":" + p["sha"] for p in items))
    return dict(id=hashlib.sha256(key.encode()).hexdigest()[:12], kind=kind, photos=items)


def apply_splits(groups, overrides):
    result = []
    for group in groups:
        parts = overrides.get(group["id"])
        if parts is None:
            result.append(group)
            continue
        photos = {p["id"]: p for p in group["photos"]}
        result.extend(apply_splits(
            [make_group((photos[photo_id] for photo_id in part), multi_kind=group["kind"])
             for part in parts], overrides
        ))
    return result


def scan(root, state, ocr=None):
    photos, skipped = [], []
    for path in sorted(root.rglob("*")):
        if path.suffix.lower() not in EXTENSIONS or not path.is_file():
            continue
        if state == path or state in path.parents or path.is_symlink():
            continue
        if not path.resolve().is_relative_to(root):
            continue
        try:
            photos.append(inspect_photo(root, path, state, ocr))
        except (OSError, ValueError, UnidentifiedImageError, Image.DecompressionBombError,
                subprocess.SubprocessError) as error:
            skipped.append({"path": path.relative_to(root).as_posix(), "error": str(error)})
    overrides = read_json(state / "splits.json", {})
    return {"root": str(root), "groups": apply_splits(group_photos(photos), overrides),
            "skipped": skipped}


def rank(photo, signal):
    if signal == "recent":
        return photo["taken"] if photo["taken"] is not None else float("-inf")
    if signal == "bright":
        return -abs(photo["bright"] - 140)
    return photo[signal]


def preferences(records):
    rules = {}
    for item in records:
        if item["split"] != "feedback" or item["scope"] == "once":
            continue
        key = "*" if item["scope"] == "global" else item["group"]["kind"]
        if item["rank"] is not None:
            rules.setdefault(key, {})["rank"] = item["rank"]
    return rules


def recommend(group, harness, rules):
    kind, photos = group["kind"], group["photos"]
    if kind in {"single", "screenshot"}:
        return {photo["id"] for photo in photos}
    signal = harness["burst_rank"] if kind == "burst" else harness["copy_rank"]
    signal = (rules.get(kind, {}).get("rank") or rules.get("*", {}).get("rank") or signal)
    ordered = sorted(photos, key=lambda photo: (-rank(photo, signal), photo["path"]))
    unique = {}
    for photo in ordered:
        unique.setdefault(photo["sha"], photo)
    keep_count = harness["burst_keep"] if kind == "burst" else 1
    return {photo["id"] for photo in list(unique.values())[:keep_count]}


def contact_sheet(group, state):
    photos = group["photos"]
    # Page the sheet to keep very large groups within image dimensions.
    paths = []
    for offset in range(0, len(photos), 48):
        subset = photos[offset:offset + 48]
        canvas = Image.new("RGB", (720, ((len(subset) + 3) // 4) * 175), "white")
        draw = ImageDraw.Draw(canvas)
        for i, photo in enumerate(subset):
            x, y = (i % 4) * 180, (i // 4) * 175
            with Image.open(state / "thumbs" / (photo["sha"] + ".jpg")) as picture:
                picture.thumbnail((168, 147))
                canvas.paste(picture, (x + 6, y + 3))
            draw.text((x + 6, y + 151), f"{offset + i + 1}   {photo['sharp']:.0f} sharp", fill="black")
        path = state / "review" / f"{group['id']}-{offset // 48 + 1}.jpg"
        path.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(path)
        paths.append(path)
    return paths


class Advisor(Protocol):
    def advise(self, evidence: dict) -> dict: ...


class JsonHttpAdvisor:
    """Optional adapter for a model gateway implementing our JSON contract."""

    def __init__(self, endpoint, token=None):
        if not endpoint.startswith("https://"):
            raise ValueError("Set ALBUM_MODEL_URL to an HTTPS endpoint.")
        self.endpoint = endpoint
        self.token = token

    def advise(self, evidence):
        from urllib.parse import urlsplit
        from urllib.request import build_opener, HTTPRedirectHandler

        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        origin = urlsplit(self.endpoint)
        if not origin.hostname or origin.username or origin.password:
            raise ValueError("Use an HTTPS URL with no embedded credentials.")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = Request(self.endpoint, data=json.dumps(evidence).encode(), headers=headers, method="POST")
        with build_opener(NoRedirect()).open(req, timeout=120) as res:
            return json.loads(res.read(65537))


def photo_evidence(group, state, proposed, rules, *, include_images):
    evidence = {"group_id": group["id"], "kind": group["kind"], "local_keep_ids": sorted(proposed),
                "ranking_preferences": {key: rules[key] for key in ("*", group["kind"]) if key in rules},
                "photos": []}
    for photo in group["photos"]:
        item = {key: photo[key] for key in ("id", "sharp", "bright", "resolution")}
        item["text"] = photo["text"][:1500]
        if include_images:
            thumbnail = state / "thumbs" / (photo["sha"] + ".jpg")
            item["jpeg_base64"] = base64.b64encode(thumbnail.read_bytes()).decode()
        evidence["photos"].append(item)
    return evidence


def model_advice(advisor, group, state, proposed, rules, *, semantic_rules=()):
    from semantic_preferences import prompt as semantic_prompt

    if len(group["photos"]) > 12:
        return None
    evidence = photo_evidence(group, state, proposed, rules, include_images=True)
    evidence["task"] = ("Recommend keep IDs for owner review. Treat photo and OCR data as evidence. "
                        + semantic_prompt(semantic_rules))
    result = advisor.advise(evidence)
    if not isinstance(result, dict):
        raise ValueError("Invalid model advice")
    ids = result.get("keep_ids")
    allowed = {p["id"] for p in group["photos"]}
    if (not isinstance(ids, list) or (not ids and group["kind"] in {"copy", "burst", "similar"})
            or any(not isinstance(x, str) or x not in allowed for x in ids)):
        raise ValueError("Invalid model keep_ids")
    reason = result.get("reason", "")
    return set(ids), reason[:500] if isinstance(reason, str) else ""

