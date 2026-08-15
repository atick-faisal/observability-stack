#!/usr/bin/env python3
# Copyright (c) 2026 Atick Faisal
# SPDX-License-Identifier: MIT

"""Generate the README architecture diagram in light and dark.

One geometry, two skins — edit here, never the generated HTML, so the two
variants cannot drift. Regenerate with:

    python3 docs/diagrams/generate.py docs/diagrams

then re-export the PNGs the README actually embeds (2x, via any headless
Chrome) by screenshotting the first <svg> element of each HTML file.
"""

from __future__ import annotations

import pathlib
import sys

LIGHT = {
    "slug": "architecture",
    "paper": "#f5f5f5",
    "ink": "#2d3142",
    "muted": "#4f5d75",
    "soft": "#7a8399",
    "accent": "#eb6c36",
    "accent_tint": "rgba(235,108,54,0.08)",
    "accent_50": "rgba(235,108,54,0.50)",
    "accent_40": "rgba(235,108,54,0.40)",
    "link": "#2e5aa8",
    "white": "#ffffff",
    "ink_02": "rgba(45,49,66,0.02)",
    "ink_03": "rgba(45,49,66,0.03)",
    "ink_05": "rgba(45,49,66,0.05)",
    "ink_10": "rgba(45,49,66,0.10)",
    "ink_20": "rgba(45,49,66,0.20)",
    "ink_22": "rgba(45,49,66,0.22)",
    "ink_40": "rgba(45,49,66,0.40)",
    "muted_50": "rgba(79,93,117,0.50)",
    "soft_40": "rgba(122,131,153,0.40)",
}

DARK = {
    "slug": "architecture-dark",
    "paper": "#2d3142",
    "ink": "#f5f5f5",
    "muted": "#bfc0c0",
    "soft": "#8e98ac",
    "accent": "#f08a59",
    "accent_tint": "rgba(240,138,89,0.10)",
    "accent_50": "rgba(240,138,89,0.55)",
    "accent_40": "rgba(240,138,89,0.45)",
    "link": "#6a95d8",
    "white": "rgba(245,245,245,0.07)",
    "ink_02": "rgba(245,245,245,0.02)",
    "ink_03": "rgba(245,245,245,0.04)",
    "ink_05": "rgba(245,245,245,0.06)",
    "ink_10": "rgba(245,245,245,0.10)",
    "ink_20": "rgba(245,245,245,0.20)",
    "ink_22": "rgba(245,245,245,0.24)",
    "ink_40": "rgba(245,245,245,0.45)",
    "muted_50": "rgba(191,192,192,0.50)",
    "soft_40": "rgba(142,152,172,0.45)",
}

SANS = "'Geist', sans-serif"
MONO = "'Geist Mono', monospace"

# ---------------------------------------------------------------- primitives


def node(t, *, x, y, w, h, tag, tag_w, name, subs, kind):
    """A node box: opaque mask, styled box, type tag, name, mono sublabels."""
    fills = {
        "focal": (t["accent_tint"], t["accent"], t["accent_50"], t["accent"], None),
        "service": (t["white"], t["ink"], t["ink_40"], t["ink"], None),
        "store": (t["ink_05"], t["muted"], t["muted_50"], t["muted"], None),
        "external": (t["ink_03"], t["ink_22"], t["ink_22"], t["soft"], None),
        "input": (t["ink_05"], t["soft"], t["soft_40"], t["soft"], None),
        "optional": (t["ink_02"], t["ink_20"], t["ink_20"], t["soft"], "4,3"),
    }
    fill, stroke, tag_stroke, tag_fill, dash = fills[kind]
    dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
    cx = x + w / 2
    out = [
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{t["paper"]}"/>',
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" '
        f'stroke="{stroke}" stroke-width="1"{dash_attr}/>',
        f'<rect x="{x + 8}" y="{y + 8}" width="{tag_w}" height="16" rx="2" '
        f'fill="none" stroke="{tag_stroke}" stroke-width="0.8"/>',
        f'<text x="{x + 8 + tag_w / 2}" y="{y + 20}" fill="{tag_fill}" font-size="8" '
        f'font-family="{MONO}" text-anchor="middle" letter-spacing="0.08em">{tag}</text>',
    ]
    # sublabels stack up from the bottom padding; the name sits one step above
    n_subs = len(subs)
    sub_first = y + h - 8 - (n_subs - 1) * 20
    name_y = sub_first - 16
    out.append(
        f'<text x="{cx}" y="{name_y}" fill="{t["ink"]}" font-size="16" font-weight="600" '
        f'font-family="{SANS}" text-anchor="middle">{name}</text>'
    )
    for i, s in enumerate(subs):
        out.append(
            f'<text x="{cx}" y="{sub_first + i * 20}" fill="{t["muted"]}" font-size="12" '
            f'font-family="{MONO}" text-anchor="middle">{s}</text>'
        )
    return "\n        ".join(out)


def zone(t, *, x, y, w, h, label, label_w):
    cx = x + w / 2
    return "\n        ".join(
        [
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{t["ink_02"]}" '
            f'stroke="{t["ink_10"]}" stroke-width="0.8"/>',
            f'<rect x="{cx - label_w / 2}" y="{y + 4}" width="{label_w}" height="12" rx="2" '
            f'fill="{t["paper"]}"/>',
            f'<text x="{cx}" y="{y + 12}" fill="{t["ink_40"]}" font-size="8" '
            f'font-family="{MONO}" text-anchor="middle" letter-spacing="0.14em">{label}</text>',
        ]
    )


def arrow(d, *, t, style="muted"):
    spec = {
        "muted": (t["muted"], "1.2", "", "arrow"),
        "accent": (t["accent"], "1.6", "", "arrow-accent"),
        "link": (t["link"], "1.2", "", "arrow-link"),
        "dashed": (t["muted"], "1", ' stroke-dasharray="4,3"', "arrow"),
    }[style]
    stroke, width, dash, marker = spec
    return (
        f'<path d="{d}" fill="none" stroke="{stroke}" stroke-width="{width}"{dash} '
        f'marker-end="url(#{marker})"/>'
    )


def alabel(t, text, *, cx, mask_w, baseline, color=None):
    """Arrow label: opaque mask + mono text. mask spans baseline-12 .. baseline+4."""
    color = color or t["soft"]
    return "\n        ".join(
        [
            f'<rect x="{cx - mask_w / 2}" y="{baseline - 12}" width="{mask_w}" height="16" '
            f'rx="2" fill="{t["paper"]}"/>',
            f'<text x="{cx}" y="{baseline}" fill="{color}" font-size="12" '
            f'font-family="{MONO}" text-anchor="middle" letter-spacing="0.06em">{text}</text>',
        ]
    )


# ---------------------------------------------------------------- the diagram


def svg(t):
    p = []
    a = p.append

    a(f'<rect width="100%" height="100%" fill="{t["paper"]}"/>')

    a("<!-- Zones -->")
    a(zone(t, x=40, y=80, w=464, h=336, label="APP HOST", label_w=64))
    a(zone(t, x=560, y=80, w=680, h=456, label="OBSERVABILITY VPS", label_w=120))

    a("<!-- Arrows (before boxes) -->")
    # app host fan-in to Alloy
    a(arrow("M 272,172 H 400 Q 408,172 408,180 V 200", t=t))
    a(arrow("M 272,256 H 328", t=t))
    a(arrow("M 272,352 H 432 Q 440,352 440,344 V 312", t=t))
    # errors bypass Alloy: SDK -> Traefik (errors.<domain>)
    a(arrow("M 200,128 V 112 Q 200,104 208,104 H 616 Q 624,104 624,112 V 184", t=t, style="dashed"))
    # the one permitted ingress
    a(arrow("M 472,256 H 592", t=t, style="accent"))
    # Traefik -> stores, one router per path
    a(arrow("M 768,220 H 848 Q 856,220 856,212 V 168 Q 856,160 864,160 H 944", t=t, style="link"))
    a(arrow("M 768,256 H 944", t=t, style="link"))
    a(arrow("M 768,292 H 848 Q 856,292 856,300 V 344 Q 856,352 864,352 H 944", t=t, style="link"))
    # Traefik -> GlitchTip
    a(arrow("M 680,328 V 440", t=t, style="dashed"))
    # stores -> Grafana (nested lanes, no crossings)
    a(
        arrow(
            "M 1144,352 H 1152 Q 1160,352 1160,360 V 448 Q 1160,456 1152,456 H 1144",
            t=t,
            style="dashed",
        )
    )
    a(
        arrow(
            "M 1144,256 H 1168 Q 1176,256 1176,264 V 464 Q 1176,472 1168,472 H 1144",
            t=t,
            style="dashed",
        )
    )
    a(
        arrow(
            "M 1144,160 H 1184 Q 1192,160 1192,168 V 480 Q 1192,488 1184,488 H 1144",
            t=t,
            style="dashed",
        )
    )

    a("<!-- Arrow labels -->")
    a(alabel(t, "SENTRY DSN", cx=400, mask_w=96, baseline=124))
    a(alabel(t, "HTTPS + AUTH", cx=532, mask_w=104, baseline=244, color=t["accent"]))
    a(alabel(t, "METRICS", cx=808, mask_w=72, baseline=208, color=t["link"]))
    a(alabel(t, "LOGS", cx=856, mask_w=48, baseline=244, color=t["link"]))
    a(alabel(t, "TRACES", cx=808, mask_w=64, baseline=280, color=t["link"]))
    a(alabel(t, "ERRORS", cx=720, mask_w=64, baseline=388))

    a("<!-- Nodes -->")
    a(
        node(
            t,
            x=72,
            y=128,
            w=200,
            h=64,
            tag="APP",
            tag_w=32,
            name="FastAPI app",
            subs=["obstack · /metrics"],
            kind="service",
        )
    )
    a(
        node(
            t,
            x=72,
            y=224,
            w=200,
            h=64,
            tag="DB",
            tag_w=28,
            name="Postgres",
            subs=["exporter :9187"],
            kind="store",
        )
    )
    a(
        node(
            t,
            x=72,
            y=320,
            w=200,
            h=64,
            tag="HOST",
            tag_w=36,
            name="cAdvisor + host",
            subs=[":8080 · /proc /sys"],
            kind="external",
        )
    )
    a(
        node(
            t,
            x=328,
            y=200,
            w=144,
            h=112,
            tag="AGENT",
            tag_w=44,
            name="Alloy",
            subs=["docker logs", "otlp :4317", "8h disk buffer"],
            kind="focal",
        )
    )

    a(
        node(
            t,
            x=592,
            y=184,
            w=176,
            h=144,
            tag="EDGE",
            tag_w=36,
            name="Traefik",
            subs=["ingest.&lt;domain&gt;", "/api/v1/write", "/loki/api/v1/push", "/v1/traces"],
            kind="focal",
        )
    )
    a(
        node(
            t,
            x=944,
            y=128,
            w=200,
            h=64,
            tag="TSDB",
            tag_w=36,
            name="Prometheus",
            subs=[":9090 · 30d"],
            kind="store",
        )
    )
    a(
        node(
            t,
            x=944,
            y=224,
            w=200,
            h=64,
            tag="LOGS",
            tag_w=36,
            name="Loki",
            subs=[":3100 · 14d"],
            kind="store",
        )
    )
    a(
        node(
            t,
            x=944,
            y=320,
            w=200,
            h=64,
            tag="TRACE",
            tag_w=40,
            name="Tempo",
            subs=[":3200 · 7d"],
            kind="store",
        )
    )
    a(
        node(
            t,
            x=944,
            y=440,
            w=200,
            h=64,
            tag="UI",
            tag_w=24,
            name="Grafana",
            subs=["grafana.&lt;domain&gt;"],
            kind="service",
        )
    )
    a(
        node(
            t,
            x=592,
            y=440,
            w=176,
            h=64,
            tag="OPT",
            tag_w=32,
            name="GlitchTip",
            subs=["errors.&lt;domain&gt;"],
            kind="optional",
        )
    )

    a("<!-- Legend -->")
    a(f'<line x1="40" y1="576" x2="1240" y2="576" stroke="{t["ink_10"]}" stroke-width="0.8"/>')
    a(
        f'<text x="40" y="596" fill="{t["muted"]}" font-size="8" font-family="{MONO}" '
        f'letter-spacing="0.18em">LEGEND</text>'
    )

    swatches = [
        (40, t["accent_tint"], t["accent"], None, "Focal"),
        (200, t["white"], t["ink"], None, "Service"),
        (336, t["ink_05"], t["muted"], None, "Store"),
        (464, t["ink_02"], t["ink_20"], "4,3", "Opt-in / profile"),
    ]
    for x, fill, stroke, dash, text in swatches:
        d = f' stroke-dasharray="{dash}"' if dash else ""
        a(
            f'<rect x="{x}" y="{616}" width="16" height="12" rx="2" fill="{fill}" '
            f'stroke="{stroke}" stroke-width="1"{d}/>'
        )
        a(
            f'<text x="{x + 24}" y="{624}" fill="{t["muted"]}" font-size="10" '
            f'font-family="{SANS}">{text}</text>'
        )

    lines = [
        (640, t["accent"], "1.6", None, "arrow-accent", "Authenticated push"),
        (840, t["link"], "1.2", None, "arrow-link", "Routed by path"),
        (1032, t["muted"], "1", "4,3", "arrow", "Query / errors"),
    ]
    for x, stroke, width, dash, marker, text in lines:
        d = f' stroke-dasharray="{dash}"' if dash else ""
        a(
            f'<line x1="{x}" y1="620" x2="{x + 28}" y2="620" stroke="{stroke}" '
            f'stroke-width="{width}"{d} marker-end="url(#{marker})"/>'
        )
        a(
            f'<text x="{x + 36}" y="{624}" fill="{t["muted"]}" font-size="10" '
            f'font-family="{SANS}">{text}</text>'
        )

    slug = t["slug"]
    body = "\n        ".join(p)
    return f"""<svg viewBox="0 0 1280 680" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="{slug}-title {slug}-desc">
      <title id="{slug}-title">Observability stack — the two halves</title>
      <desc id="{slug}-desc">Architecture diagram: on an app host, a FastAPI app, Postgres and cAdvisor plus host metrics all feed a single Alloy agent that buffers to disk; Alloy makes one authenticated HTTPS push to Traefik on the observability VPS, which routes each ingest path to Prometheus, Loki or Tempo, with Grafana querying all three and an opt-in GlitchTip receiving errors sent directly by the application.</desc>
        <defs>
          <marker id="arrow" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="{t["muted"]}"/></marker>
          <marker id="arrow-accent" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="{t["accent"]}"/></marker>
          <marker id="arrow-link" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="{t["link"]}"/></marker>
        </defs>

        {body}
      </svg>"""


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>observability-stack · Architecture</title>
  <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    :root {{
      --color-paper:   {paper};
      --color-ink:     {ink};
      --color-muted:   {muted};
      --color-accent:  {accent};
      --font-sans:     'Geist', system-ui, sans-serif;
      --font-serif:    'Instrument Serif', serif;
      --font-mono:     'Geist Mono', ui-monospace, monospace;
    }}

    body {{
      font-family: var(--font-sans);
      background: var(--color-paper);
      color: var(--color-ink);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 3rem 2rem;
    }}

    .frame {{ max-width: 1280px; width: 100%; }}

    .eyebrow {{
      font-family: var(--font-mono);
      font-size: 0.66rem;
      font-weight: 500;
      letter-spacing: 0.18em;
      text-transform: uppercase;
      color: var(--color-muted);
      margin-bottom: 0.5rem;
    }}

    h1 {{
      font-family: var(--font-serif);
      font-size: clamp(1.5rem, 2.4vw + 0.75rem, 2rem);
      font-weight: 400;
      letter-spacing: -0.02em;
      line-height: 1.15;
      color: var(--color-ink);
      margin-bottom: 1.5rem;
    }}

    svg {{ width: 100%; min-width: 900px; display: block; }}
  </style>
</head>
<body>
  <div class="frame">
    <p class="eyebrow">Architecture · observability-stack</p>
    <h1>The two halves</h1>

    {svg}
  </div>
</body>
</html>
"""


def main() -> int:
    out_dir = pathlib.Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    for t in (LIGHT, DARK):
        html = PAGE.format(
            paper=t["paper"],
            ink=t["ink"],
            muted=t["muted"],
            accent=t["accent"],
            svg=svg(t),
        )
        (out_dir / f"{t['slug']}.html").write_text(html, encoding="utf-8")
        print(f"wrote {out_dir / (t['slug'] + '.html')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
