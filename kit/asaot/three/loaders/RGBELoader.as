// asaot.three.loaders.RGBELoader -- Radiance (.hdr) decoder, RGBE scanlines.
//
// Borrows the SHAPE of three.js src/loaders/RGBELoader.js (r187): a Loader
// subclass whose `load(url, onLoad, onProgress, onError)` decodes into a
// {width,height,data} payload. The decoder itself is transcribed from the
// Radiance file format definition (Greg Ward, `rgbe.c` / `color.c`), which is
// what RGBELoader.js transcribes too:
//
//   header      "#?RADIANCE" (or "#?RGBE"), then `KEY=value` lines, blank line
//   resolution  "<-Y H> <+X W>" (first axis = scanline order, second = pixels)
//   scanlines   either flat RGBe quadruples, old-style RLE (1,1,1,count runs), or
//               new-style RLE: "02 02 hi lo" + four separately RLE'd channels
//
// DIVERGENCES (three-api-design.md 30):
//   D152  the payload is HDRImage (RGBe bytes + on-demand decode), not a float
//         DataTexture -- this backend has no float texture format.
//   D153  `32-bit_rle_xyze` (CIE XYZ) is REFUSED by name instead of decoded as
//         RGB. Radiance allows it; three.js silently mis-reads such files as
//         RGB, which is the "compiles but the colours are wrong" failure mode
//         this project refuses (AGENTS.md 2.5). The message names the format.
//   D158  per-load state: this loader was written AFTER the L1 audit fixed the
//         other three and reintroduced the same defect (the request and both
//         callbacks lived in instance fields, so a second load() hijacked the
//         first one's decode). The request and the closures that read it are now
//         this call's locals.
//   D161  `manager` (L6) is honoured: resolveURL after the path prefix,
//         itemStart/itemEnd/itemError around the read+decode.
package asaot.three.loaders
{
    import asaot.three.textures.HDRImage;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.net.URLLoader;
    import flash.net.URLLoaderDataFormat;
    import flash.net.URLRequest;
    import flash.utils.ByteArray;

    public class RGBELoader extends Loader
    {
        public function RGBELoader(manager:LoadingManager = null)
        {
            super(manager);
        }

        public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):void
        {
            if (url == null) url = '';
            if (this.path != null && this.path.length > 0) url = this.path + url;
            // L6: path prefix, then the manager's URL modifier.
            url = this.manager.resolveURL(url);

            // D158: everything this read needs lives in this call's locals.
            var self:RGBELoader = this;
            var ul:URLLoader = new URLLoader();
            ul.dataFormat = URLLoaderDataFormat.BINARY;
            ul.addEventListener(Event.COMPLETE, function(e:Event):void
            {
                var img:HDRImage = null;
                try
                {
                    img = self.parse(ul.data as ByteArray);
                }
                catch (err:Error)
                {
                    self.manager.itemError(url);
                    self.manager.itemEnd(url);
                    if (onError != null) onError(err);
                    return;
                }
                self.manager.itemEnd(url);
                if (onLoad != null) onLoad(img);
            });
            ul.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void
            {
                self.manager.itemError(url);
                self.manager.itemEnd(url);
                if (onError != null) onError(e);
            });
            ul.load(new URLRequest(url));
            this.manager.itemStart(url);
        }

        // ---------------------------------------------------------------- parse

        public function parse(bytes:ByteArray):HDRImage
        {
            if (bytes == null) throw new Error("RGBELoader: no bytes to parse");

            // readLine publishes where the line ended in `lastEnd`; the byte
            // cursor is never derived from the returned text's length, which
            // would be wrong for a \r\n file.
            var magic:String = RGBELoader.readLine(bytes, 0);
            var pos:int = RGBELoader.lastEnd;

            if (magic != "#?RADIANCE" && magic != "#?RGBE")
            {
                throw new Error("RGBELoader: not a Radiance HDR file (first line '" + magic + "')");
            }

            var format:String = "";
            var exposure:Number = 1.0;
            var guard:int = 0;
            while (true)
            {
                var line:String = RGBELoader.readLine(bytes, pos);
                pos = RGBELoader.lastEnd;
                if (line.length == 0) break;
                if (line.charAt(0) == "#") continue;
                if (line.substr(0, 7) == "FORMAT=") format = line.substr(7);
                else if (line.substr(0, 9) == "EXPOSURE=") exposure = Number(line.substr(9));
                guard++;
                if (guard > 4096) throw new Error("RGBELoader: header never terminated");
            }

            if (format != "32-bit_rle_rgbe")
            {
                // D153: name the format we cannot honour instead of decoding it
                // as RGB and returning wrong colours.
                if (format == "32-bit_rle_xyze")
                    throw new Error("RGBELoader: 32-bit_rle_xyze (CIE XYZ) is not supported; convert the file to 32-bit_rle_rgbe");
                throw new Error("RGBELoader: unsupported FORMAT='" + format + "' (expected 32-bit_rle_rgbe)");
            }

            // Resolution line, e.g. "-Y 128 +X 256".
            var res:String = RGBELoader.readLine(bytes, pos);
            pos = RGBELoader.lastEnd;
            var toks:Array = res.split(" ");
            var t:Array = [];
            var i:int;
            for (i = 0; i < toks.length; i++)
            {
                if (toks[i] != null && String(toks[i]).length > 0) t.push(String(toks[i]));
            }
            if (t.length != 4)
                throw new Error("RGBELoader: bad resolution line '" + res + "' (expected e.g. '-Y 128 +X 256')");

            var axis0:String = t[0].substr(1);
            var dim0:int = int(Number(t[1]));
            var axis1:String = t[2].substr(1);
            var dim1:int = int(Number(t[3]));
            if ((axis0 != "Y" && axis0 != "X") || (axis1 != "X" && axis1 != "Y") || axis0 == axis1)
                throw new Error("RGBELoader: bad resolution axes '" + res + "'");
            if (dim0 <= 0 || dim1 <= 0)
                throw new Error("RGBELoader: bad resolution sizes '" + res + "'");

            // The kit's panorama is always width x height with row 0 = top.
            var width:int = axis1 == "X" ? dim1 : dim0;
            var height:int = axis0 == "Y" ? dim0 : dim1;
            var flipVertically:Boolean = (axis0 == "Y" && t[0].charAt(0) == "+");
            var flipHorizontally:Boolean = (axis1 == "X" && t[2].charAt(0) == "-");

            var img:HDRImage = new HDRImage(width, height);
            img.exposure = exposure;

            var scanlineBytes:int = width * 4;
            var scratch:ByteArray = new ByteArray();
            var y:int;
            for (i = 0; i < height; i++)
            {
                if (pos >= bytes.length)
                    throw new Error("RGBELoader: truncated scanline data at row " + i + " of " + height);
                pos = RGBELoader.readScanline(bytes, pos, scanlineBytes, scratch);
                y = flipVertically ? (height - 1 - i) : i;
                RGBELoader.storeRow(img, y, scratch, scanlineBytes, flipHorizontally);
            }
            return img;
        }

        // -------------------------------------------------------------- helpers

        // Offset just past the '\n' that terminated the line readLine returned.
        // ByteArray.readLine() cannot be used: it is AS2-era and its handling of
        // \r\n differs between runtimes, and a Radiance header's blank line is
        // load-bearing. This reader accepts both \n and \r\n.
        public static var lastEnd:int = 0;

        public static function readLine(bytes:ByteArray, start:int):String
        {
            var b:ByteArray = bytes;
            var end:int = start;
            var len:int = b.length;
            while (end < len && b[end] != 0x0A) end++;
            var text:String = "";
            var i:int;
            for (i = start; i < end; i++)
            {
                if (b[i] == 0x0D) continue;
                text += String.fromCharCode(b[i]);
            }
            lastEnd = (end < len) ? (end + 1) : len;
            return text;
        }

        // Decode one scanline of RGBe quadruples into `out` (width*4 bytes).
        // Three encodings, in the order Radiance's rgbe.c tries them:
        //   new-style RLE  02 02 <hi> <lo> with hi<<8|lo == width
        //   old-style RLE  a (1,1,1,count) quadruple repeats the previous texel
        //   flat           width plain quadruples (which may also contain old RLE)
        public static function readScanline(bytes:ByteArray, pos:int, widthBytes:int, out:ByteArray):int
        {
            out.length = 0;
            var width:int = widthBytes >> 2;

            // New-style header is only valid when the width fits in 15 bits and
            // is at least 8 texels -- exactly rgbe.c's condition.
            if (width >= 8 && width < 32768 && pos + 4 <= bytes.length)
            {
                var b0:int = bytes[pos] & 0xFF;
                var b1:int = bytes[pos + 1] & 0xFF;
                var b2:int = bytes[pos + 2] & 0xFF;
                var b3:int = bytes[pos + 3] & 0xFF;
                if (b0 == 2 && b1 == 2 && ((b2 << 8) | b3) == width)
                    return RGBELoader._readNewRle(bytes, pos + 4, width, out);
            }

            // Flat stream with optional old-style run markers.
            var x:int = 0;
            while (x < width)
            {
                if (pos + 4 > bytes.length)
                    throw new Error("RGBELoader: truncated scanline (wanted texel " + x + " of " + width + ")");
                var r:int = bytes[pos] & 0xFF;
                var g:int = bytes[pos + 1] & 0xFF;
                var bl:int = bytes[pos + 2] & 0xFF;
                var e:int = bytes[pos + 3] & 0xFF;
                pos += 4;
                if (r == 1 && g == 1 && bl == 1)
                {
                    // Old-style run: `count` copies of the previous texel, with
                    // the count split across consecutive markers (count << 8k).
                    var shift:int = 0;
                    while (true)
                    {
                        var count:int = e << shift;
                        shift += 8;
                        // The previous texel is already in `out`; snapshot its
                        // four bytes BEFORE writing, because writeByte moves the
                        // cursor (reading `out[out.length - 4]` inside the loop
                        // would read a byte this very loop just appended).
                        var pr:int = out[out.length - 4] & 0xFF;
                        var pg:int = out[out.length - 3] & 0xFF;
                        var pb:int = out[out.length - 2] & 0xFF;
                        var pe:int = out[out.length - 1] & 0xFF;
                        var k:int;
                        for (k = 0; k < count; k++)
                        {
                            out.writeByte(pr);
                            out.writeByte(pg);
                            out.writeByte(pb);
                            out.writeByte(pe);
                        }
                        x += count;
                        if (x >= width) break;
                        if (pos + 4 > bytes.length)
                            throw new Error("RGBELoader: truncated old-style run at texel " + x);
                        r = bytes[pos] & 0xFF;
                        g = bytes[pos + 1] & 0xFF;
                        bl = bytes[pos + 2] & 0xFF;
                        e = bytes[pos + 3] & 0xFF;
                        pos += 4;
                        if (!(r == 1 && g == 1 && bl == 1)) break;
                    }
                    if (!(r == 1 && g == 1 && bl == 1))
                    {
                        out.writeByte(r);
                        out.writeByte(g);
                        out.writeByte(bl);
                        out.writeByte(e);
                        x++;
                    }
                }
                else
                {
                    out.writeByte(r);
                    out.writeByte(g);
                    out.writeByte(bl);
                    out.writeByte(e);
                    x++;
                }
            }
            return pos;
        }

        // New-style RLE: four channels, each its own run stream. A run byte < 128
        // is a literal count; >= 128 is a repeat of (b - 128) copies of the next
        // byte.
        private static function _readNewRle(bytes:ByteArray, pos:int, width:int, out:ByteArray):int
        {
            var ch:int;
            var x:int;
            var chans:Vector.<int> = new Vector.<int>(width * 4, true);
            for (ch = 0; ch < 4; ch++)
            {
                x = 0;
                while (x < width)
                {
                    if (pos >= bytes.length)
                        throw new Error("RGBELoader: truncated RLE channel " + ch);
                    var code:int = bytes[pos] & 0xFF;
                    pos++;
                    if (code == 0)
                        throw new Error("RGBELoader: illegal zero-length RLE run in channel " + ch);
                    if (code > 128)
                    {
                        var n:int = code - 128;
                        if (pos >= bytes.length)
                            throw new Error("RGBELoader: truncated RLE repeat in channel " + ch);
                        var v:int = bytes[pos] & 0xFF;
                        pos++;
                        var k:int;
                        for (k = 0; k < n; k++) chans[(x + k) * 4 + ch] = v;
                        x += n;
                    }
                    else
                    {
                        var j:int;
                        for (j = 0; j < code; j++)
                        {
                            if (pos >= bytes.length)
                                throw new Error("RGBELoader: truncated RLE literal in channel " + ch);
                            chans[(x + j) * 4 + ch] = bytes[pos] & 0xFF;
                            pos++;
                        }
                        x += code;
                    }
                }
            }
            x = 0;
            while (x < width)
            {
                out.writeByte(chans[x * 4]);
                out.writeByte(chans[x * 4 + 1]);
                out.writeByte(chans[x * 4 + 2]);
                out.writeByte(chans[x * 4 + 3]);
                x++;
            }
            return pos;
        }

        // Copy one decoded scanline into the image, honouring the resolution
        // line's axis directions (a `+Y` file is stored bottom-up; `-X` right-to-left).
        private static function storeRow(img:HDRImage, y:int, row:ByteArray, widthBytes:int, flipH:Boolean):void
        {
            var base:int = y * img.width * 4;
            var dst:ByteArray = img.rgbe;
            var width:int = widthBytes >> 2;
            var x:int;
            var i:int;
            if (!flipH)
            {
                for (i = 0; i < widthBytes; i++) dst[base + i] = row[i];
                return;
            }
            for (x = 0; x < width; x++)
            {
                var src:int = (width - 1 - x) * 4;
                var d:int = base + x * 4;
                dst[d] = row[src];
                dst[d + 1] = row[src + 1];
                dst[d + 2] = row[src + 2];
                dst[d + 3] = row[src + 3];
            }
        }
    }
}