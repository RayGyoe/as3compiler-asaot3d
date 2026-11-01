# tools/refscene — three.js ground truth for the ported demos

A port cannot be judged by comparing two of *our* backends: AOT and AIR run the
same kit/seam renderer, so they agree with each other even when both disagree
with the reference. Answering "is our render wrong?" needs the reference
implementation itself, running at the same stage size, measured with the same
statistic.

```
tools/refscene/
  walk-m26.html    three.js `webgl_animation_walk` at 1000x800, frozen pose,
                   exposes window.__stats(box) -> { mean, p50, p90, p99, max, n }
  boxstats.mjs     the SAME statistic for a screenshot PNG (AOT or AIR capture)
```

## Usage

```bash
# from asaot3d/ -- the server root must be the repo root so /assets/... resolves
python3 -m http.server 8791 --bind 127.0.0.1
open http://127.0.0.1:8791/tools/refscene/walk-m26.html

# in the page console (or via a CDP driver)
__stats([0.44,0.44,0.56,0.62])

# same box on a capture; 32 = AOT titlebar in CSS px, 0 for AIR/adl
node tools/refscene/boxstats.mjs temp/w26-aot.png 32 0.44,0.44,0.56,0.62
node tools/refscene/boxstats.mjs temp/w26-air.png  0 0.44,0.44,0.56,0.62
```

`?t=<s>` pins the animation time, `?fog=0` removes `scene.fog`, `?nonormal=1`
drops the body's `normalMap`.

## Why a frozen pose and a region *distribution*

A per-frame `mixer.update()` makes any region statistic a function of wall-clock
time; the first M26 comparisons were confounded by exactly that. Pinning the
pose makes the number a function of the renderer alone. Reporting p50/p90/p99 as
well as the mean separates "everything is lifted" (fog-like) from "the specular
tail is wrong" (BRDF-like) — the two produce identical means but different
shapes.

## Stage size matters: 1000x800, not 1000x768

`adl` gives the stage the window minus the ~32 px titlebar, so a descriptor
height of 800 yields a 1000x768 stage (aspect 1.302). AOT gives the stage the
full 1000x800 (aspect 1.25). Different aspect ⇒ different projection ⇒ different
normals at the same fractional box. For parity work set the AIR descriptor to
`<height>832</height>` so both are 1000x800; the descriptor is otherwise left at
800.

## Diagnostic handles

The page exposes `window.__scene`, `__renderer`, `__camera`, `__names()` and
`__only(name)` so a bright patch can be attributed to a mesh:

```js
__names()                 // ['vanguard_Mesh','vanguard_visor','(unnamed)']
__only('vanguard_Mesh')   // hide every other mesh, then __stats(box)
__only(null)              // restore
```

Used to rule the visor out of the M26-R1b body box (three-api-design.md §34.5):
the visor covers none of that box, so it cannot explain the highlight.

## Measured truth (M26 body/floor audit, 2026-11-01)

> **SUPERSEDED (2026-11-01, later the same day).** The three.js rows below were
> produced by a page whose module never ran to completion (§32.3) and are void.
> The current truth table, the retracted M26-R2 verdict and the D170–D172 fixes
> are in `three-api-design.md` §32.4 and §34. Keep this table only for the
> `AOT ≡ AIR` observation, which used in-repo captures and still holds.

Body box `0.44,0.44,0.56,0.62`, floor box `0.30,0.80,0.70,0.95`, luma:

| frame | body mean | body p50 | body p90 | floor mean |
|---|---|---|---|---|
| three.js, fog ON | 20.75 | 8 | 46.0 | 23.65 |
| three.js, fog OFF | 11.45 | 0 | 29.1 | 21.10 |
| AOT, fog ON | 44.19 | 21.6 | 72.8 | 28.44 |
| AOT, fog OFF | 38.69 | 17.7 | 88.7 | 27.22 |
| AIR (832 descriptor), fog OFF | 37.80 | 17.0 | 73.7 | 27.28 |

Readings:

* **AOT ≡ AIR** (fog off: 38.69 vs 37.80, floor 27.22 vs 27.28). The old
  "AOT is brighter than AIR on the metal body" claim was a stage-aspect artifact
  of comparing a 1.25 stage against a 1.302 stage.
* **We are brighter than three.js on both surfaces, and far brighter on the
  metal**: body 3.4x the reference with fog off, floor +29%. The metal has no
  environment map and no diffuse lobe, so this is the direct specular term.
* **Our fog lifts less than the reference's** (body -5.5 going fognull vs
  -9.3), so fog is a second, smaller, independent gap.
* The background is pixel-identical (94,93,93) on all three, which rules out
  camera, clear colour, output encoding and tone-map exposure as causes.