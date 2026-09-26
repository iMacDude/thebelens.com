#!/usr/bin/env python3
"""Self-host Google Fonts: download woff2 files and emit local @font-face CSS.

- Keeps only the latin + latin-ext subsets.
- DEDUPES by content hash. Google serves one variable-font file across several
  weights, so a naive download writes the same bytes several times.
- Preserves Google's exact family/style/weight -> file mapping, so rendering is
  identical to the hosted version. Only the host changes.

After running, the site makes ZERO runtime requests to Google.
"""
import re, sys, pathlib, urllib.request, hashlib

KEEP = {"latin", "latin-ext"}
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36")

def fetch(url, binary=False):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read() if binary else r.read().decode("utf-8")

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def main(css_url, out_dir, css_out, web_prefix):
    out = pathlib.Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.woff2"):
        old.unlink()

    blocks = re.findall(r"/\*\s*([a-z0-9-]+)\s*\*/\s*(@font-face\s*\{.*?\})",
                        fetch(css_url), re.S)
    if not blocks:
        sys.exit("ERROR: no @font-face blocks parsed — CSS format may have changed")

    by_hash, faces, downloaded = {}, [], {}
    for subset, block in blocks:
        if subset not in KEEP:
            continue
        fam   = re.search(r"font-family:\s*'([^']+)'", block).group(1)
        style = re.search(r"font-style:\s*(\S+?);", block).group(1)
        wt    = re.search(r"font-weight:\s*([^;]+);", block).group(1).strip()
        url   = re.search(r"url\((https://fonts\.gstatic\.com/[^)]+)\)", block).group(1)
        urange= re.search(r"unicode-range:\s*([^;]+);", block)

        if url not in downloaded:
            downloaded[url] = fetch(url, binary=True)
        data = downloaded[url]
        h = hashlib.sha256(data).hexdigest()[:8]

        if h not in by_hash:
            name = f"{slug(fam)}-{style}-{subset}-{h}.woff2"
            (out / name).write_bytes(data)
            by_hash[h] = name
            print(f"  + {name:<48} {len(data):>7} bytes")
        else:
            print(f"    (reuses {by_hash[h]} for weight {wt})")

        faces.append(
            "@font-face {\n"
            f"  font-family: '{fam}';\n"
            f"  font-style: {style};\n"
            f"  font-weight: {wt};\n"
            "  font-display: swap;\n"
            f"  src: url('{web_prefix}/{by_hash[h]}') format('woff2');\n"
            + (f"  unicode-range: {urange.group(1)};\n" if urange else "")
            + "}\n")

    header = (
        "/* Self-hosted fonts — GENERATED, do not hand-edit.\n"
        "   Regenerate: scripts/selfhost-fonts.py\n"
        f"   Upstream:   {css_url}\n"
        "   Subsets:    latin + latin-ext only (cyrillic/vietnamese dropped).\n"
        "   Deduped:    Google serves one variable file across several weights,\n"
        "               so several @font-face rules point at the same file.\n"
        "   Why:        the site must make NO runtime request to Google.\n"
        "   Licence:    fonts remain under their original SIL Open Font License. */\n\n")
    co = pathlib.Path(css_out); co.parent.mkdir(parents=True, exist_ok=True)
    co.write_text(header + "\n".join(faces))
    print(f"  -> {len(faces)} faces over {len(by_hash)} files -> {css_out}")

if __name__ == "__main__":
    main(*sys.argv[1:])
