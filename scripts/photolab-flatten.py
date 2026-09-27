#!/usr/bin/env python3
"""Build a flat folder of symlinks to every image under a folder tree.

DxO PhotoLab's folder browser only lists images at the top level of a folder
(Filesystem.bundle enumerates with NSDirectoryEnumerationSkipsSubdirectoryDescendants).
It does follow symlinks, so pointing it at a flat folder of links shows the
whole tree in one grid.

Link names encode the relative path so they stay unique and sort by folder:
    2024/Iceland/IMG_0001.CR3  ->  2024__Iceland__IMG_0001.CR3

Re-running is safe: existing correct links are kept, and with --prune, links
whose target has disappeared are removed. Real files in the destination are
never touched.

For RAW+JPEG shooting, --skip-paired-jpegs leaves out each camera JPEG that
has a RAW of the same name in the same folder, so every shot appears once.
"""
import argparse
import os
import sys
from pathlib import Path

JPEG_EXTS = {"jpg", "jpeg", "jpe"}
RAW_EXTS = {
    "dng", "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "orf",
    "raf", "rw2", "rwl", "pef", "srw", "3fr", "fff", "iiq", "erf", "mef",
    "mos", "mrw", "x3f", "gpr",
}
IMAGE_EXTS = JPEG_EXTS | {"tif", "tiff", "heic", "heif", "png"} | RAW_EXTS
SEP = "__"


def split_ext(name: str) -> tuple[str, str]:
    stem, _, ext = name.rpartition(".")
    return stem.lower(), ext.lower()


def iter_images(root: Path, exts: set[str], dest: Path, skip_paired: bool, stats: dict):
    for dirpath, dirnames, filenames in os.walk(root):
        here = Path(dirpath)
        # Match PhotoLab: skip hidden entries and package contents; never recurse into dest.
        dirnames[:] = sorted(
            d for d in dirnames
            if not d.startswith(".")
            and not d.endswith((".app", ".photoslibrary", ".bundle"))
            and (here / d).resolve() != dest
        )
        # A camera JPEG is "paired" when a RAW with the same stem sits in the same folder.
        raw_stems = {split_ext(f)[0] for f in filenames if split_ext(f)[1] in RAW_EXTS} if skip_paired else set()
        for name in sorted(filenames):
            # Skip links too, so an earlier flat folder inside the tree isn't re-linked.
            if name.startswith(".") or "." not in name or (here / name).is_symlink():
                continue
            stem, ext = split_ext(name)
            if ext not in exts:
                continue
            if ext in JPEG_EXTS and stem in raw_stems:
                stats["paired"] += 1
                continue
            yield here / name


def link_name(src: Path, root: Path) -> str:
    return SEP.join(src.relative_to(root).parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("source", type=Path, help="folder tree containing images")
    ap.add_argument("dest", type=Path, help="flat folder to fill with symlinks (created if missing)")
    ap.add_argument("-n", "--dry-run", action="store_true", help="show what would change, change nothing")
    ap.add_argument("--prune", action="store_true", help="remove links in dest whose target no longer exists")
    ap.add_argument("--ext", action="append", metavar="EXT",
                    help="only link these extensions (repeatable), e.g. --ext cr3 --ext jpg")
    ap.add_argument("--skip-paired-jpegs", action="store_true",
                    help="leave out a JPEG when a RAW of the same name is beside it (RAW+JPEG shooting)")
    args = ap.parse_args()

    root = args.source.expanduser().resolve()
    dest = args.dest.expanduser().resolve()
    exts = {e.lower().lstrip(".") for e in args.ext} if args.ext else IMAGE_EXTS

    if not root.is_dir():
        ap.error(f"source is not a folder: {root}")
    if dest == root:
        ap.error("dest must differ from source")
    if not args.dry_run:
        dest.mkdir(parents=True, exist_ok=True)

    created = kept = skipped = pruned = 0
    wanted = set()
    stats = {"paired": 0}

    for src in iter_images(root, exts, dest, args.skip_paired_jpegs, stats):
        name = link_name(src, root)
        wanted.add(name)
        link = dest / name
        if link.is_symlink():
            if Path(os.readlink(link)) == src:
                kept += 1
                continue
            print(f"skip (link exists, points elsewhere): {name}", file=sys.stderr)
            skipped += 1
            continue
        if link.exists():
            print(f"skip (real file in the way): {name}", file=sys.stderr)
            skipped += 1
            continue
        print(f"link  {name}")
        if not args.dry_run:
            link.symlink_to(src)
        created += 1

    if args.prune and dest.is_dir():
        for entry in sorted(dest.iterdir()):
            if entry.is_symlink() and entry.name not in wanted and not entry.exists():
                print(f"prune {entry.name}")
                if not args.dry_run:
                    entry.unlink()
                pruned += 1

    verb = "would create" if args.dry_run else "created"
    paired = f", left out {stats['paired']} paired JPEGs" if args.skip_paired_jpegs else ""
    print(f"\n{verb} {created}, kept {kept}, skipped {skipped}, pruned {pruned}{paired}  ->  {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
