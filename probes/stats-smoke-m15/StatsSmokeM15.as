// asaot3d/probes/stats-smoke-m15/StatsSmokeM15.as -- M15 performance HUD smoke.
//
// Pins the parts of the Stats HUD that are observable WITHOUT a GPU, i.e. the
// whole borrowed contract except the pixels themselves:
//
//   A. Panel geometry and the label grammar ("<rounded value> <NAME>
//      (<rounded min>-<rounded max>)"), straight out of
//      `examples/jsm/libs/stats.module.js`.
//   B. barHeight(): the graph column height, including saturation above the
//      normalizer and the degenerate cases a normalizer of 0/NaN produces.
//   C. StatsPanel.update(): monotonic min/max over the panel's whole life, the
//      one-column-per-update scroll window (74 slots), and the read-back the
//      graph is painted from.
//   D. Stats.begin/end/update(): MS every frame with normalizer 200, FPS once
//      per 1000 ms window with normalizer 100, frames reset at the window edge,
//      and `update()` == `begin(); end()` folded. Driven by a fake clock through
//      `setTimeSource`, so the assertions are exact rather than approximate.
//   E. Panel cycling: one visible tile, click advances, `showPanel` wraps.
//   F. Corner anchoring math and the margin defaults (default = TOP-LEFT, so the
//      right-hand side stays free for a control panel).
//   G. The event bridge: a click on a panel bubbles to Stats and cycles it, and
//      Stats stops it there -- a press that lands on the HUD must not reach the
//      stage (which is also OrbitControls' event source).
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/stats-smoke-m15/StatsSmokeM15.as \
//     $(find kit -name '*.as') -o temp/stats-smoke-m15 --run
import asaot.three.extras.hud.Stats;
import asaot.three.extras.hud.StatsPanel;

import flash.display.Sprite;
import flash.events.MouseEvent;

var failed:int = 0;

function check(name:String, cond:Boolean):void
{
    if (cond) trace("PASS " + name);
    else { trace("FAIL " + name); failed++; }
}

function near(a:Number, b:Number, eps:Number = 1e-6):Boolean
{
    return Math.abs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// A. Panel geometry + label grammar.
// ---------------------------------------------------------------------------
check("A1 tile is 80x48", StatsPanel.WIDTH == 80 && StatsPanel.HEIGHT == 48);
check("A2 label at (3,2)", StatsPanel.TEXT_X == 3 && StatsPanel.TEXT_Y == 2);
check("A3 graph at (3,15) 74x30",
      StatsPanel.GRAPH_X == 3 && StatsPanel.GRAPH_Y == 15 &&
      StatsPanel.GRAPH_WIDTH == 74 && StatsPanel.GRAPH_HEIGHT == 30);
check("A4 label font is 9px", StatsPanel.FONT_SIZE == 9);

check("A5 FPS label",
      StatsPanel.labelFor(60, "FPS", 60, 60) == "60 FPS (60-60)");
check("A6 value is rounded, not truncated",
      StatsPanel.labelFor(12.4, "MS", 12.4, 12.4) == "12 MS (12-12)");
check("A7 min/max are rounded independently",
      StatsPanel.labelFor(23.9, "MB", 20.2, 30.7) == "24 MB (20-31)");
check("A8 0.5 rounds up (same as JS Math.round)",
      StatsPanel.labelFor(0.5, "MS", 0.5, 0.5) == "1 MS (1-1)");

// ---------------------------------------------------------------------------
// B. barHeight().
// ---------------------------------------------------------------------------
check("B1 half of the normalizer is half the graph", near(StatsPanel.barHeight(50, 100), 15));
check("B2 at the normalizer the column is full", near(StatsPanel.barHeight(100, 100), 30));
check("B3 above the normalizer saturates", near(StatsPanel.barHeight(250, 100), 30));
check("B4 zero sample draws nothing", near(StatsPanel.barHeight(0, 100), 0));
check("B5 negative sample draws nothing", near(StatsPanel.barHeight(-3, 100), 0));
check("B6 zero normalizer draws nothing", near(StatsPanel.barHeight(5, 0), 0));
check("B7 NaN sample draws nothing", near(StatsPanel.barHeight(Number.NaN, 100), 0));
check("B8 tiny sample stays proportional", near(StatsPanel.barHeight(1, 3), 10));

// ---------------------------------------------------------------------------
// C. StatsPanel.update(): min/max, window scroll, read-back.
// ---------------------------------------------------------------------------
var panel:StatsPanel = new StatsPanel("FPS", 0x00ffff, 0x000022);
check("C1 fresh panel has no range yet",
      panel.min == Number.POSITIVE_INFINITY && panel.max == 0 && panel.filledColumns == 0);
check("C2 fresh panel paints no columns", !panel.columnFilled(StatsPanel.GRAPH_WIDTH - 1));

panel.update(30, 100);
check("C3 first sample seeds min and max", panel.min == 30 && panel.max == 30);
check("C4 first sample lands in the rightmost column",
      panel.filledColumns == 1 &&
      panel.columnValue(StatsPanel.GRAPH_WIDTH - 1) == 30 &&
      panel.columnFilled(StatsPanel.GRAPH_WIDTH - 1));
check("C5 columns left of the window are empty",
      !panel.columnFilled(StatsPanel.GRAPH_WIDTH - 2));
check("C6 label after one sample",
      panel.labelText == "30 FPS (30-30)");
check("C7 column height follows the sample",
      near(panel.columnHeight(StatsPanel.GRAPH_WIDTH - 1), 9));

panel.update(50, 100);
check("C8 min is monotonic (does not follow a rising sample)", panel.min == 30);
check("C9 max follows a rising sample", panel.max == 50);
check("C10 label tracks min and max", panel.labelText == "50 FPS (30-50)");
check("C11 older samples scroll left",
      panel.columnValue(StatsPanel.GRAPH_WIDTH - 1) == 50 &&
      panel.columnValue(StatsPanel.GRAPH_WIDTH - 2) == 30);
check("C12 height of the newest column", near(panel.columnHeight(StatsPanel.GRAPH_WIDTH - 1), 15));

panel.update(20, 100);
check("C13 min follows a falling sample", panel.min == 20);
check("C14 max does not follow a falling sample", panel.max == 50);
check("C15 label after the minimum drops", panel.labelText == "20 FPS (20-50)");

// Fill the whole window and then some: the buffer must stop growing at 74 and
// the leftmost column must be the oldest surviving sample.
var i:int = 0;
while (i < 100)
{
    panel.update(i, 100);
    i++;
}
check("C16 the window holds exactly 74 columns", panel.filledColumns == 74);
check("C17 newest sample is i=99", panel.columnValue(StatsPanel.GRAPH_WIDTH - 1) == 99);
check("C18 oldest surviving sample is i=26 (100 samples - 74 slots)",
      panel.columnValue(0) == 26);
check("C19 panel echoes the last update inputs", panel.value == 99 && panel.maxValue == 100);
check("C20 min/max survive the whole run", panel.min == 0 && panel.max == 99);

// A normalizer of 0 (the MB panel before its first heap read) must not paint
// NaN-height rects.
var zeroPanel:StatsPanel = new StatsPanel("MB", 0xff0088, 0x220011);
zeroPanel.update(12, 0);
check("C21 zero normalizer keeps column heights finite",
      near(zeroPanel.columnHeight(StatsPanel.GRAPH_WIDTH - 1), 0));

// ---------------------------------------------------------------------------
// D. Stats timing: MS per frame, FPS per 1 s window.
// ---------------------------------------------------------------------------
var fakeClock:Number = 0;

function fakeNow():Number
{
    return fakeClock;
}

var stats:Stats = new Stats();
stats.setTimeSource(fakeNow);

check("D1 three built-in panels", stats.panelCount == 3);
check("D2 stats.js REVISION is carried", Stats.REVISION == 16);
check("D3 normalizers match the addon", Stats.MS_MAX == 200 && Stats.FPS_MAX == 100);

var fpsPanel:StatsPanel = stats.panels[Stats.FPS];
var msPanel:StatsPanel = stats.panels[Stats.MS];
var mbPanel:StatsPanel = stats.panels[Stats.MB];

fakeClock = 16;
stats.begin();
fakeClock = 32;
var endTime:Number = stats.end();
check("D4 end() returns the clock reading", endTime == 32);
check("D5 MS is the frame period", near(msPanel.value, 16));
check("D6 MS normalizer is 200", near(msPanel.maxValue, 200));
check("D7 MS samples every frame", msPanel.filledColumns == 1);

// 61 more 16 ms frames: the first 1 s window closes on the frame that crosses
// 1000 ms, which is frame 62 at clock 1008.
i = 0;
while (i < 61)
{
    fakeClock += 16;
    stats.begin();
    stats.end();
    i++;
}
check("D8 the first window closes after 1000 ms", fpsPanel.filledColumns == 1);
check("D9 FPS is frames*1000/elapsed over the window",
      near(fpsPanel.value, (62 * 1000) / 1008, 1e-6));
check("D10 FPS normalizer is 100", near(fpsPanel.maxValue, 100));
check("D11 MS samples every frame", msPanel.filledColumns == 62);

// A second window: frames were reset at the edge, so the next window is
// frames-since-the-last-edge / elapsed-since-the-last-edge.
i = 0;
while (i < 63)
{
    fakeClock += 16;
    stats.begin();
    stats.end();
    i++;
}
check("D12 the second window resets the frame counter",
      near(fpsPanel.value, (63 * 1000) / 1008, 1e-6));
check("D13 FPS keeps one sample per closed window", fpsPanel.filledColumns == 2);

// MB is read on the same 1 s tick, in MiB over a nominal 1 GiB scale.
check("D14 MB panel reads the AIR heap", mbPanel.value > 0);
check("D15 MB normalizer is the nominal 1 GiB scale", near(mbPanel.maxValue, Stats.MEMORY_SCALE_MB));

// update() == begin() folded into end(): the next MS sample is the next frame
// period, not the whole run.
fakeClock = 10000;
stats.update();
fakeClock = 10016;
stats.end();
check("D16 update() re-seeds the frame start", near(msPanel.value, 16));

var noMem:Stats = new Stats(false);
check("D17 withMemory=false drops the MB panel", noMem.panelCount == 2);

// ---------------------------------------------------------------------------
// E. Cycling: exactly one tile at a time.
// ---------------------------------------------------------------------------
check("E1 FPS is the initial panel", stats.mode == Stats.FPS && stats.panels[0].visible);
check("E2 MS starts hidden", !stats.panels[1].visible && !stats.panels[2].visible);
check("E3 currentPanel is the visible one", stats.currentPanel == stats.panels[0]);

stats.cycle();
check("E4 cycle advances to MS", stats.mode == Stats.MS && stats.panels[1].visible &&
                                 !stats.panels[0].visible && !stats.panels[2].visible);
stats.cycle();
check("E5 cycle advances to MB", stats.mode == Stats.MB && stats.panels[2].visible);
stats.cycle();
check("E6 cycle wraps back to FPS", stats.mode == Stats.FPS);

var counters:StatsPanel = new StatsPanel("CALLS", 0xffff00, 0x222200);
stats.addPanel(counters);
check("E7 addPanel appends and stays hidden",
      stats.panelCount == 4 && !counters.visible);
stats.showPanel(3);
check("E8 showPanel reveals only its own tile", counters.visible && !stats.panels[0].visible);
stats.cycle();
check("E9 cycle wraps from a added panel to FPS", stats.mode == 0);
stats.showPanel(9);
check("E10 showPanel wraps an out-of-range id", stats.mode == 1);
stats.showPanel(-1);
check("E11 showPanel(-1) wraps to the last tile", stats.mode == 3 && counters.visible);

// ---------------------------------------------------------------------------
// F. Anchoring.
// ---------------------------------------------------------------------------
check("F1 right-aligned anchor leaves the right margin", near(Stats.anchorX(960, 8), 872));
check("F2 right-aligned anchor on a narrow stage", near(Stats.anchorX(200, 8), 112));
check("F3 default margin is 8px", Stats.MARGIN == 8);

// The DEFAULT corner is the top-left, which is where stats.js puts its DOM div
// and which leaves the right-hand side of the window to a control panel.
check("F4 default corner is LEFT", stats.align == Stats.LEFT);
check("F5 the LEFT corner is the plain margin, no arithmetic",
      near(Stats.anchorFor(Stats.LEFT, 960, 8), 8));
check("F6 anchorFor(RIGHT) is anchorX", near(Stats.anchorFor(Stats.RIGHT, 960, 8), 872));
check("F7 a detached HUD sits at the left margin", near(stats.panels[0].x, 8));

var rightStats:Stats = new Stats(false, Stats.RIGHT);
check("F8 align=RIGHT is accepted", rightStats.align == Stats.RIGHT);
check("F9 a detached RIGHT HUD still falls back to the left margin",
      near(rightStats.panels[0].x, 8));

// An unknown corner is a programming error, not a silent fallback: a HUD that
// quietly lands somewhere unexpected is worse than one that refuses to exist.
var alignThrew:Boolean = false;
try { new Stats(false, "middle"); } catch (alignErr:Error) { alignThrew = true; }
check("F10 an unknown align throws", alignThrew);

// ---------------------------------------------------------------------------
// G. Event bridge: a click on a tile reaches Stats and stops there.
// ---------------------------------------------------------------------------
var parentClicks:int = 0;
var parentDowns:int = 0;

function onParentClick(e:MouseEvent):void
{
    parentClicks++;
}

function onParentDown(e:MouseEvent):void
{
    parentDowns++;
}

var host:Sprite = new Sprite();
var hud:Stats = new Stats(false);
host.addChild(hud);
host.addEventListener(MouseEvent.CLICK, onParentClick);
host.addEventListener(MouseEvent.MOUSE_DOWN, onParentDown);

var clickEvent:MouseEvent = new MouseEvent(MouseEvent.CLICK, true);
hud.panels[0].dispatchEvent(clickEvent);
check("G1 click on a tile bubbles to the HUD and cycles it", hud.mode == 1);
check("G2 the HUD stops the click before the parent", parentClicks == 0);

var downEvent:MouseEvent = new MouseEvent(MouseEvent.MOUSE_DOWN, true);
hud.panels[1].dispatchEvent(downEvent);
check("G3 a press on the HUD does not reach the stage-owning parent", parentDowns == 0);
check("G4 a press on the HUD does not cycle", hud.mode == 1);

hud.cycle();
check("G5 cycle from the event path still works", hud.mode == 0);
hud.showPanel(0);
check("G6 showPanel resets the cycle", hud.mode == 0);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));