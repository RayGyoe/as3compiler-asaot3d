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
    p.exposure == 0.45 && p.reflections == true && p.view == 0);
check("A10 preset 0 is the port's own colour", p.preset == 0);
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
                    OceanParams.WATER, OceanParams.POST];
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
check("C" + (total + 1) + " the tables cover 21 controls", total == 21);

// the documented clamps
p.setValue("cloudCoverage", 1.5);
check("C23 cloud coverage clamps to 1", p.cloudCoverage == 1);
p.setValue("windSpeed", 0);
check("C24 wind speed floors at 0.1 (a zero-wind spectrum is NaN)", p.windSpeed == 0.1);
p.setValue("exposure", 0);
check("C25 exposure floors at 0.01", p.exposure == 0.01);
p.setValue("glint", 2);
check("C26 glint clamps to 1", p.glint == 1);
p.setValue("sunAzimuth", -10);
check("C27 azimuth wraps into 0..360 (not a clamp)", near(p.sunAzimuth, 350));
p.setValue("sunAzimuth", 370);
check("C28 azimuth wraps down", near(p.sunAzimuth, 10));
p.setValue("clarity", 0);
check("C29 clarity floors at 0.05 rather than dividing by zero", p.clarity == 0.05);
p.setValue("fetchKm", 0);
check("C30 fetch floors at 1 km", p.fetchKm == 1);

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
    p.sunElevation == 3.5 && p.windSpeed == 9.0 && p.exposure == 0.45);
check("E2 reset restores clarity AND the derived absorption",
    p.clarity == 1.0 && near(p.absorption[0], 0.17) &&
    near(p.absorption[1], 0.055) && near(p.absorption[2], 0.038));
check("E3 reset restores the preset's scatter",
    near(p.scatter[0], 0.010) && near(p.scatter[1], 0.062) &&
    near(p.scatter[2], 0.085));
check("E4 reset restores the switches",
    p.reflections == true && p.view == 0 && p.preset == 0);

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