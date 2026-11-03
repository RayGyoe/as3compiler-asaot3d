// asaot3d/probes/panel-params-m35/PanelParamsM35.as -- M35 control-panel model smoke.
//
// The panel's VIEW needs pixels; its MODEL needs only arithmetic, and that is
// where the semantics live: the 0..1 <-> author-units mapping, the per-control
// clamps, the water preset -> absorption derivation (absorption = base / clarity,
// main.js's `absorption.copy(base).multiplyScalar(1 / clarity)`), reset, and the
// one-line log a headless run is judged from. All of it is pure, so all of it is
// pinned here:
//
//   A. Defaults are the reference's (and the port's two deliberate exceptions).
//   B. norm/denorm round-trip, clamping at both ends, and the degenerate span.
//   C. Every table entry is reachable by NAME through valueOf/setValue, and the
//      clamp each one applies is the documented one.
//   D. Water presets: base colours, clarity scaling, and re-applying a preset
//      after a clarity change.
//   E. reset() restores every field AND the derived colour arrays.
//   F. describe() reflects the model (so a log line cannot drift from the state).
//   G. Unknown names throw instead of silently reading zero.
//
// Run from asaot3d/:
//   node ../as3compiler/src/index.ts probes/panel-params-m35/PanelParamsM35.as \
//     apps/ocean-m34/src/panel/OceanParams.as -o temp/panel-params-m35 --run
import panel.OceanParams;

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

function setThrew(target:OceanParams, name:String, v:Number):Boolean
{
    try { target.setValue(name, v); }
    catch (e:Error) { return true; }
    return false;
}

// ---------------------------------------------------------------------------
// A. defaults
// ---------------------------------------------------------------------------
var p:OceanParams = new OceanParams();

check("A1 sun defaults are the reference's golden hour",
    p.sunElevation == 3.5 && p.sunAzimuth == 205.0 && p.sunIntensity == 9.0);
check("A2 cloud coverage is the port's 0.42", p.cloudCoverage == 0.42);
check("A3 sea state is the port's 9 m/s over 120 km",
    p.windSpeed == 9.0 && p.fetchKm == 120.0);
check("A4 wind bearing is the port's 0.6 rad, in degrees",
    near(p.windDirection, 34.3775, 1e-4));
check("A5 swell is 0.7 at 0.6 rad - 0.9 rad",
    p.swellScale == 0.7 && near(p.swellDirection, -17.1887, 1e-4));
check("A6 spectrum shape defaults",
    p.waveScale == 1.0 && p.spreadBlend == 0.85 && p.choppiness == 0.85);
check("A7 water optics defaults",
    p.roughness == 0.02 && p.refraction == 0.06 &&
    p.reflectionDistort == 0.04 && p.glint == 0.6);
check("A8 foam defaults", p.foamBias == 0.05 && p.foamScale == 1.3);
check("A9 post + switches",
    p.exposure == 0.45 && p.autoExposure == false && p.reflections == true && p.view == 0);
check("A10 preset 0 is the port's own colour", p.preset == 0);
check("A10b the post chain's own defaults are PostFX.js's",
    p.keyValue == 0.18 && p.minExposure == 0.05 && p.maxExposure == 20.0 &&
    p.bloomStrength == 0.05 && p.bloomThreshold == 1.5 && p.bloomClamp == 64.0 &&
    p.contrast == 1.0 && p.saturation == 1.0 && p.vignette == 0.22);
check("A10c the underwater defaults are the reference's scattering/shafts",
    p.scattering == 0.055 && p.shafts == 0.9 && p.shaftRange == 42.0 &&
    p.underwaterExposure == 0.55);
check("A10d the render size starts at 1x", p.renderScale == 1.0);
check("A11 construction seeds absorption = base / clarity",
    near(p.absorption[0], 0.17) && near(p.absorption[1], 0.055) &&
    near(p.absorption[2], 0.038));

// ---------------------------------------------------------------------------
// B. 0..1 <-> author units
// ---------------------------------------------------------------------------
check("B1 norm maps lo/mid/hi",
    near(OceanParams.norm(0, 0, 10), 0) &&
    near(OceanParams.norm(5, 0, 10), 0.5) &&
    near(OceanParams.norm(10, 0, 10), 1));
check("B2 norm clamps outside the span",
    OceanParams.norm(-5, 0, 10) == 0 && OceanParams.norm(99, 0, 10) == 1);
check("B3 denorm maps back", near(OceanParams.denorm(0.5, 0, 10), 5));
check("B4 denorm clamps t",
    OceanParams.denorm(-1, 4, 8) == 4 && OceanParams.denorm(2, 4, 8) == 8);
check("B5 round-trip holds for a signed span",
    near(OceanParams.denorm(OceanParams.norm(-17.2, -180, 180), -180, 180), -17.2, 1e-9));
check("B6 a degenerate span collapses to 0 instead of dividing by zero",
    OceanParams.norm(3, 5, 5) == 0);
check("B7 NaN clamps to 0", OceanParams.norm(Math.sqrt(-1), 0, 10) == 0);

// ---------------------------------------------------------------------------
// C. every table entry is a name the model knows
// ---------------------------------------------------------------------------
var tables:Array = [OceanParams.SUN, OceanParams.WAVES,
                    OceanParams.WATER, OceanParams.POST, OceanParams.UNDERWATER];
var t:int = 0;
var total:int = 0;
while (t < tables.length)
{
    var spec:Array = tables[t];
    var i:int = 0;
    while (i < spec.length)
    {
        var row:Array = spec[i];
        var name:String = row[0];
        var mid:Number = (Number(row[2]) + Number(row[3])) / 2;
        p.setValue(name, mid);
        total++;
        check("C" + total + " " + name + " round-trips through the table span",
            near(p.valueOf(name), mid, 1e-9));
        i++;
    }
    t++;
}
// 4 sun + 9 waves + 7 water + 7 post + 4 underwater. The QUALITY row is a
// SELECT (see section H), not a slider table, so it is not counted here.
check("CT the tables cover 31 controls", total == 31);

// the documented clamps (K: kept out of the C numbering so the table loop and the
// clamp list cannot collide when a row is added)
p.setValue("cloudCoverage", 1.5);
check("K1 cloud coverage clamps to 1", p.cloudCoverage == 1);
p.setValue("windSpeed", 0);
check("K2 wind speed floors at 0.1 (a zero-wind spectrum is NaN)", p.windSpeed == 0.1);
p.setValue("exposure", 0);
check("K3 exposure floors at 0.01", p.exposure == 0.01);
p.setValue("glint", 2);
check("K4 glint clamps to 1", p.glint == 1);
p.setValue("sunAzimuth", -10);
check("K5 azimuth wraps into 0..360 (not a clamp)", near(p.sunAzimuth, 350));
p.setValue("sunAzimuth", 370);
check("K6 azimuth wraps down", near(p.sunAzimuth, 10));
p.setValue("clarity", 0);
check("K7 clarity floors at 0.05 rather than dividing by zero", p.clarity == 0.05);
p.setValue("fetchKm", 0);
check("K8 fetch floors at 1 km", p.fetchKm == 1);
p.setValue("scattering", -1);
check("K9 turbidity is non-negative (a negative extinction amplifies light)",
    p.scattering == 0);
p.setValue("saturation", -1);
check("K10 saturation is non-negative (a negative pull inverts hue)", p.saturation == 0);
p.setValue("renderScale", 0);
check("K11 render scale clamps to the menu floor (0.5x)", p.renderScale == 0.5);
p.setValue("renderScale", 9);
check("K12 render scale clamps to the menu ceiling (2x)", p.renderScale == 2.0);

// ---------------------------------------------------------------------------
// D. water colour: preset x clarity
// ---------------------------------------------------------------------------
p = new OceanParams();
p.setPreset(3);   // toxic green
check("D1 preset 3 is the reference's toxic green (R 0.45, G 0.1, B 1.1)",
    near(p.absorbBase[0], 0.45) && near(p.absorbBase[1], 0.1) && near(p.absorbBase[2], 1.1));
check("D2 its scatter comes with it",
    near(p.scatter[0], 0.05) && near(p.scatter[1], 0.1) && near(p.scatter[2], 0.004));
p.setValue("clarity", 2.0);
check("D3 clarity halves the absorption",
    near(p.absorption[0], 0.225) && near(p.absorption[1], 0.05) &&
    near(p.absorption[2], 0.55));
p.setPreset(0);
check("D4 a new preset re-derives with the CURRENT clarity",
    near(p.absorption[0], 0.085) && near(p.absorption[1], 0.0275) &&
    near(p.absorption[2], 0.019));
p.setPreset(-1);
check("D5 a negative index wraps to the last preset",
    p.preset == OceanParams.PRESETS.length - 1);
check("D6 there are seven presets (port default + the reference's six)",
    OceanParams.PRESETS.length == 7);
check("D7 preset labels are the first column",
    OceanParams.presetLabels()[1] == "clear" &&
    OceanParams.presetLabels()[6] == "murky brown");
check("D8 there are seven camera views, the first being the demo's own loop",
    OceanParams.VIEWS.length == 7 && OceanParams.VIEWS[0] == "auto loop (26 s)" &&
    OceanParams.VIEWS[6] == "Underwater");

// The view REQUEST counter. `view` says which camera is wanted; the counter says
// "apply it again", which is what lets a pick of the entry already shown hand the
// camera back to the cruise after an orbit (applyView keys on both). It must start
// at zero, move only when the panel asks, and reset with everything else -- a Reset
// is also a "give the camera back" instruction.
p = new OceanParams();
check("D9 the view request counter starts at zero", p.viewReq == 0);
p.view = 3;
check("D9b setting the view does not bump the request counter", p.viewReq == 0);
p.viewReq = p.viewReq + 2;
p.reset();
check("D10 reset asks for the default view again instead of copying the counter",
    p.view == 0 && p.viewReq == 3);

// ---------------------------------------------------------------------------
// E. reset
// ---------------------------------------------------------------------------
p = new OceanParams();
p.setValue("sunElevation", 40);
p.setValue("windSpeed", 18);
p.setValue("exposure", 2);
p.setValue("clarity", 3);
p.setPreset(5);
p.reflections = false;
p.view = 4;
p.reset();
check("E1 reset restores the scalars",
    p.sunElevation == 3.5 && p.windSpeed == 9.0 && p.exposure == 0.45 &&
    p.autoExposure == false);
check("E2 reset restores clarity AND the derived absorption",
    p.clarity == 1.0 && near(p.absorption[0], 0.17) &&
    near(p.absorption[1], 0.055) && near(p.absorption[2], 0.038));
check("E3 reset restores the preset's scatter",
    near(p.scatter[0], 0.010) && near(p.scatter[1], 0.062) &&
    near(p.scatter[2], 0.085));
check("E4 reset restores the switches",
    p.reflections == true && p.view == 0 && p.preset == 0);

// ---------------------------------------------------------------------------
// H. render scale is a stepped menu, not a slider
// ---------------------------------------------------------------------------
// The steps exist because each value rebuilds every size-dependent render target
// and the native channel has no texture dispose; six steps bound that. These pin
// the mapping the panel and the app both read.
check("H1 six steps, 0.5x through 2x",
    OceanParams.SCALES.length == 6 && OceanParams.SCALES[0] == 0.5 &&
    OceanParams.SCALES[5] == 2.0);
check("H2 labels are the value with an x, integers without a decimal point",
    OceanParams.scaleLabels()[0] == "0.5x" && OceanParams.scaleLabels()[2] == "1x" &&
    OceanParams.scaleLabels()[5] == "2x");
check("H3 scaleIndex finds the exact step",
    OceanParams.scaleIndex(1.0) == 2 && OceanParams.scaleIndex(2.0) == 5);
check("H4 scaleIndex snaps to the NEAREST step",
    OceanParams.scaleIndex(0.9) == 2 && OceanParams.scaleIndex(0.55) == 0 &&
    OceanParams.scaleIndex(1.9) == 5);
check("H5 renderScale round-trips through the model",
    near(p.valueOf("renderScale"), p.renderScale));

// MSAA is a second, orthogonal select: the render scale supersamples every pixel,
// the sample count only averages subpixel coverage on the scene targets. Both are
// real sample counts on the channel side (Context3DNative.setRenderTargetSamples),
// so the model has to carry an int, not a 0..1 slider position.
check("H6 the sample menu is off/2x/4x",
    OceanParams.MSAA_LEVELS.length == 3 && OceanParams.MSAA_LEVELS[0] == 1 &&
    OceanParams.MSAA_LEVELS[1] == 2 && OceanParams.MSAA_LEVELS[2] == 4);
check("H7 the sample labels name the level",
    OceanParams.msaaLabels()[0] == "off" && OceanParams.msaaLabels()[1] == "2x" &&
    OceanParams.msaaLabels()[2] == "4x");
check("H8 msaaIndex finds the exact level",
    OceanParams.msaaIndex(1) == 0 && OceanParams.msaaIndex(2) == 1 &&
    OceanParams.msaaIndex(4) == 2);
// 8x is accepted by the channel but not offered here, and a level between two rows
// must still highlight one of them rather than an empty trigger.
check("H9 msaaIndex snaps an unlisted level to the nearest row",
    OceanParams.msaaIndex(8) == 2 && OceanParams.msaaIndex(3) == 1 &&
    OceanParams.msaaIndex(0) == 0);
check("H10 the sample level starts off (AIR parity: Stage3D has no such knob)",
    p.msaa == 1);
check("H11 msaa round-trips through the model", p.valueOf("msaa") == p.msaa);
p.setValue("msaa", 4);
check("H12 setValue snaps to a menu level", p.msaa == 4);
p.setValue("msaa", 8);
check("H13 an unlisted level snaps down to 4x", p.msaa == 4);
p.setValue("msaa", 1);
check("H14 the level can be turned back off", p.msaa == 1);
p.setValue("msaa", 4);
p.setValue("renderScale", 2.0);
p.reset();
check("H15 reset() restores the off default", p.msaa == 1);
check("H16 reset() restores the 1x render scale", p.renderScale == 1.0);

// ---------------------------------------------------------------------------
// F. describe()
// ---------------------------------------------------------------------------
p = new OceanParams();
var d:String = p.describe();
check("F1 describe() names the default view", d.indexOf("view=auto loop (26 s)") >= 0);
check("F2 describe() names the water preset", d.indexOf("water=port default") >= 0);
check("F3 describe() carries the sea state",
    d.indexOf("wind=9m/s@34.4deg") >= 0 && d.indexOf("fetch=120km") >= 0);
p.setValue("sunElevation", 12);
p.setPreset(2);
p.reflections = false;
d = p.describe();
check("F4 describe() follows the model",
    d.indexOf("sun=12deg") >= 0 && d.indexOf("water=tropical") >= 0 &&
    d.indexOf("reflections=false") >= 0);

// ---------------------------------------------------------------------------
// G. unknown names are errors, not zeros
// ---------------------------------------------------------------------------
check("G1 setValue throws on an unknown name", setThrew(p, "sunAzim", 1.0));
var valueOfThrew:Boolean = false;
try { p.valueOf("nope"); }
catch (e:Error) { valueOfThrew = true; }
check("G2 valueOf throws on an unknown name", valueOfThrew);

trace(failed == 0 ? "ALL PASS" : (failed + " FAILED"));