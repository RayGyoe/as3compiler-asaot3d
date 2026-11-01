// asaot.three.loaders.EXRLoader -- OpenEXR (.exr) decoder, uncompressed + RLE.
//
// Borrows the SHAPE of three.js src/loaders/EXRLoader.js (r187) -- a Loader
// subclass whose `load(url, onLoad, onProgress, onError)` decodes into the same
// payload RGBELoader produces -- and the wire format from the OpenEXR file
// layout spec (openexr/docs/OpenEXRFileLayout.md). This is the M25-R3 gap: the
// Radiance decoder refused .exr by name, and refusing is only acceptable while
// the loader that CAN read it does not exist.
//
// DIVERGENCES (three-api-design.md 33):
//   D167  the payload is HDRImage (RGBE bytes, decoded on demand), NOT the float
//         DataTexture three.js builds. This backend has no float texture format
//         at all, and the only consumer is EquirectangularToCube, whose output is
//         8-bit cube faces -- so half-float precision would be quantised away
//         three stages later while costing 48 MB per 2K panorama today. EXR
//         samples are converted to the same RGBE quadruples .hdr produces.
//   D168  compression: NONE (0) and RLE (1) are decoded; ZIP/ZIPS/PIZ/PXR24/
//         B44/B44A/DWAA/DWAB are REFUSED BY NAME with the code in the message.
//         Those schemes need zlib or a proprietary predictor, i.e. an inflate
//         implementation this project does not have -- and silently rendering an
//         all-black panorama would be the "compiles but the image is wrong"
//         failure mode AGENTS.md 2.5 forbids.
//   D169  pixel types: HALF (1) and FLOAT (2) decode; UINT (0) is refused (an
//         integer channel is an id/mask map, never radiance). Tiled, deep,
//         multi-part and random-order files are refused by name too.
//   D158  per-load state: the request, the closures that read it and the parse
//         error all live in this call's locals (the L1 audit defect).
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
    import flash.utils.Endian;

    public class EXRLoader extends Loader
    {
        // 20000630 decimal == 0x01312F76, stored little-endian.
        public static const MAGIC:int = 20000630;

        // Compression codes in the file header (OpenEXR `ImfCompression.h`).
        public static const COMPRESSION_NONE:int = 0;
        public static const COMPRESSION_RLE:int = 1;
        public static const COMPRESSION_ZIPS:int = 2;
        public static const COMPRESSION_ZIP:int = 3;
        public static const COMPRESSION_PIZ:int = 4;
        public static const COMPRESSION_PXR24:int = 5;
        public static const COMPRESSION_B44:int = 6;
        public static const COMPRESSION_B44A:int = 7;
        public static const COMPRESSION_DWAA:int = 8;
        public static const COMPRESSION_DWAB:int = 9;

        // Pixel types in a chlist entry.
        public static const PIXELTYPE_UINT:int = 0;
        public static const PIXELTYPE_HALF:int = 1;
        public static const PIXELTYPE_FLOAT:int = 2;

        public function EXRLoader(manager:LoadingManager = null)
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
            var self:EXRLoader = this;
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
            if (bytes == null) throw new Error("EXRLoader: no bytes to parse");
            if (bytes.length < 8) throw new Error("EXRLoader: file is too short to be an EXR");

            // AIR's ByteArray defaults to BIG endian; every integer in an EXR is
            // little endian. Setting it once here is why the reads below are bare
            // readInt()/readUnsignedInt() calls.
            var oldEndian:String = bytes.endian;
            bytes.endian = Endian.LITTLE_ENDIAN;
            bytes.position = 0;

            var magic:int = bytes.readInt();
            if (magic != EXRLoader.MAGIC)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: not an OpenEXR file (magic 0x" + (magic >>> 0).toString(16) + ")");
            }
            var version:int = bytes.readInt();
            var flags:int = version & 0x1FFF;
            if ((flags & 0x200) != 0)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: tiled EXR files are not supported (scanline only)");
            }
            if ((flags & 0x1000) != 0)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: multi-part EXR files are not supported");
            }
            if ((flags & 0x800) != 0)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: deep-data EXR files are not supported");
            }

            // --- header: name\0 type\0 int32 size, repeated, terminated by \0 ---
            var channels:Array = null;
            var compression:int = -1;
            var dataX0:int = 0;
            var dataY0:int = 0;
            var dataX1:int = -1;
            var dataY1:int = -1;
            var lineOrder:int = 0;

            while (true)
            {
                var name:String = EXRLoader.readCString(bytes);
                if (name.length == 0) break;
                var type:String = EXRLoader.readCString(bytes);
                var size:int = bytes.readInt();
                var valuePos:int = bytes.position;

                if (name == "channels" && type == "chlist")
                {
                    channels = EXRLoader.readChannels(bytes);
                }
                else if (name == "compression" && type == "compression")
                {
                    compression = bytes.readUnsignedByte();
                }
                else if (name == "dataWindow" && type == "box2i")
                {
                    dataX0 = bytes.readInt();
                    dataY0 = bytes.readInt();
                    dataX1 = bytes.readInt();
                    dataY1 = bytes.readInt();
                }
                else if (name == "lineOrder" && type == "lineOrder")
                {
                    lineOrder = bytes.readUnsignedByte();
                }
                // Everything else (chromaticities, pixelAspectRatio, custom
                // attributes) is skipped by the declared size -- reading it is how
                // a "known" attribute list silently rejects valid files.
                bytes.position = valuePos + size;
            }

            if (channels == null) throw new Error("EXRLoader: header has no channels attribute");
            if (compression < 0) throw new Error("EXRLoader: header has no compression attribute");
            if (dataX1 < dataX0 || dataY1 < dataY0)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: header has no usable dataWindow");
            }
            if (lineOrder != 0)
            {
                // 0 = INCREASING_Y. 1 (DECREASING_Y) and 2 (RANDOM_Y) are legal but
                // vanishingly rare; refusing beats guessing the scan order.
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: only INCREASING_Y line order is supported (got " + lineOrder + ")");
            }
            if (compression != EXRLoader.COMPRESSION_NONE && compression != EXRLoader.COMPRESSION_RLE)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: compression " + EXRLoader.compressionName(compression)
                    + " (code " + compression + ") is not supported -- only NONE and RLE are");
            }

            // Resolve the R/G/B channels. three.js EXRLoader also accepts the
            // Maya-style "red/green/blue"; both spellings appear in the wild, and a
            // channel list is sorted alphabetically so a fixed index is wrong.
            var iR:int = EXRLoader.findChannel(channels, "R", "red");
            var iG:int = EXRLoader.findChannel(channels, "G", "green");
            var iB:int = EXRLoader.findChannel(channels, "B", "blue");
            if (iR < 0 || iG < 0 || iB < 0)
            {
                bytes.endian = oldEndian;
                throw new Error("EXRLoader: no R/G/B channels (found " + EXRLoader.channelNames(channels) + ")");
            }
            var pixelType:int = int(channels[iR].type);
            var check:int;
            for (check = 0; check < channels.length; check++)
            {
                var ct:int = int(channels[check].type);
                if (ct == EXRLoader.PIXELTYPE_UINT)
                {
                    bytes.endian = oldEndian;
                    throw new Error("EXRLoader: UINT channel '" + channels[check].name
                        + "' is an id/mask, not radiance -- refusing to guess");
                }
                if (ct != EXRLoader.PIXELTYPE_HALF && ct != EXRLoader.PIXELTYPE_FLOAT)
                {
                    bytes.endian = oldEndian;
                    throw new Error("EXRLoader: unknown pixel type " + ct + " on channel '" + channels[check].name + "'");
                }
            }

            var width:int = dataX1 - dataX0 + 1;
            var height:int = dataY1 - dataY0 + 1;
            var img:HDRImage = new HDRImage(width, height);

            // --- offset table, then the chunks in file order ---
            // NONE and RLE both store ONE scanline per chunk, so the table is
            // strictly increasing and the chunks can simply be read in order; the
            // table itself only has to be skipped.
            bytes.position = bytes.position + height * 8;

            var bytesPerSample:int = (pixelType == EXRLoader.PIXELTYPE_HALF) ? 2 : 4;
            // Byte offset of each channel's scanline inside a chunk: channels are
            // stored back to back in chlist order (which is alphabetical), one full
            // scanline each.
            var rowBytes:int = 0;
            var offset:int = 0;
            var k:int;
            for (k = 0; k < channels.length; k++)
            {
                channels[k].rowOffset = offset;
                offset += width * int(channels[k].bytesPerSample);
            }
            rowBytes = offset;

            var rOff:int = int(channels[iR].rowOffset);
            var gOff:int = int(channels[iG].rowOffset);
            var bOff:int = int(channels[iB].rowOffset);

            var rgb:Vector.<Number> = new Vector.<Number>(3, true);
            // Two buffers for the compressed path: RLE inflates into `scratch`,
            // then the delta-predictor is undone in place and the byte
            // de-interleave writes the real scanline into `line`.
            var scratch:ByteArray = null;
            var line:ByteArray = null;
            var y:int;
            for (y = 0; y < height; y++)
            {
                var chunkY:int = bytes.readInt();
                var dataSize:int = bytes.readInt();
                var chunkEnd:int = bytes.position + dataSize;

                var src:ByteArray;
                var base:int;
                if (compression == EXRLoader.COMPRESSION_NONE)
                {
                    if (dataSize != rowBytes)
                    {
                        bytes.endian = oldEndian;
                        throw new Error("EXRLoader: scanline " + y + " is " + dataSize + " bytes, expected " + rowBytes);
                    }
                    src = bytes;
                    base = bytes.position;
                }
                else if (dataSize == rowBytes)
                {
                    // OpenEXR stores a chunk UNCOMPRESSED whenever compressing it
                    // does not make it strictly smaller -- including under an RLE
                    // header. Readers detect that by size, not by a flag.
                    src = bytes;
                    base = bytes.position;
                }
                else
                {
                    if (scratch == null)
                    {
                        scratch = new ByteArray();
                        line = new ByteArray();
                    }
                    scratch.length = 0;
                    scratch.position = 0;
                    EXRLoader.rleDecode(bytes, dataSize, scratch);
                    if (scratch.length != rowBytes)
                    {
                        bytes.endian = oldEndian;
                        throw new Error("EXRLoader: RLE scanline " + y + " decoded to " + scratch.length
                            + " bytes, expected " + rowBytes);
                    }
                    // NOT the scanline yet: OpenEXR runs the ZIP predictor and the
                    // even/odd byte split before byte-RLE, so an RLE chunk needs the
                    // same two inverses ZIP does (internal_rle.c
                    // `reorder_and_predict` / `unpredict_and_reorder`). Skipping
                    // them yields a clean-looking decode of garbage -- the failure
                    // this project treats as a defect, not a limitation.
                    EXRLoader.unpredict(scratch, rowBytes);
                    if (line == null) line = new ByteArray();
                    line.length = 0;
                    EXRLoader.deinterleave(scratch, rowBytes, line);
                    src = line;
                    base = 0;
                }

                var row:int = chunkY - dataY0;
                if (row < 0 || row >= height)
                {
                    bytes.endian = oldEndian;
                    throw new Error("EXRLoader: scanline address " + chunkY + " is outside the data window");
                }
                var x:int;
                for (x = 0; x < width; x++)
                {
                    rgb[0] = EXRLoader.sampleAt(src, base + rOff, x, bytesPerSample);
                    rgb[1] = EXRLoader.sampleAt(src, base + gOff, x, bytesPerSample);
                    rgb[2] = EXRLoader.sampleAt(src, base + bOff, x, bytesPerSample);
                    EXRLoader.linearToRGBE(rgb[0], rgb[1], rgb[2], img.rgbe, (row * width + x) * 4);
                }
                // NONE reads in place, so the cursor has to be moved past the
                // scanline; RLE decodes into `scratch`, but the raw fallback above
                // also reads in place -- both need the skip.
                bytes.position = chunkEnd;
            }

            bytes.endian = oldEndian;
            return img;
        }

        // ------------------------------------------------------------ primitives

        private static function readCString(b:ByteArray):String
        {
            var chars:ByteArray = new ByteArray();
            var c:int = b.readUnsignedByte();
            while (c != 0)
            {
                chars.writeByte(c);
                c = b.readUnsignedByte();
            }
            chars.position = 0;
            return chars.readUTFBytes(chars.length);
        }

        // chlist: [name\0, int32 pixelType, uint8 pLinear, 3 reserved,
        //          int32 xSampling, int32 ySampling] repeated, terminated by a 0 byte.
        private static function readChannels(b:ByteArray):Array
        {
            var list:Array = [];
            // `rowOffset` (where this channel's scanline starts inside a chunk)
            // needs the width, so parse() assigns it once the dataWindow is known.
            while (b.position < b.length)
            {
                var name:String = readCString(b);
                if (name.length == 0) break;
                var entry:Object = {};
                entry.name = name;
                entry.type = b.readInt();
                b.readUnsignedByte();               // pLinear
                b.readByte(); b.readByte(); b.readByte();   // 3 reserved bytes
                entry.xSampling = b.readInt();
                entry.ySampling = b.readInt();
                entry.bytesPerSample = (int(entry.type) == EXRLoader.PIXELTYPE_HALF) ? 2 : 4;
                if (int(entry.xSampling) != 1 || int(entry.ySampling) != 1)
                {
                    throw new Error("EXRLoader: sub-sampled channel '" + name + "' is not supported");
                }
                list.push(entry);
            }
            return list;
        }

        private static function findChannel(channels:Array, a:String, b:String):int
        {
            var i:int;
            for (i = 0; i < channels.length; i++)
            {
                var n:String = String(channels[i].name);
                if (n == a || n == b) return i;
            }
            return -1;
        }

        private static function channelNames(channels:Array):String
        {
            var out:String = "";
            var i:int;
            for (i = 0; i < channels.length; i++)
            {
                if (i > 0) out += ",";
                out += String(channels[i].name);
            }
            return out;
        }

        public static function compressionName(code:int):String
        {
            switch (code)
            {
                case COMPRESSION_NONE: return "NONE";
                case COMPRESSION_RLE: return "RLE";
                case COMPRESSION_ZIPS: return "ZIPS";
                case COMPRESSION_ZIP: return "ZIP";
                case COMPRESSION_PIZ: return "PIZ";
                case COMPRESSION_PXR24: return "PXR24";
                case COMPRESSION_B44: return "B44";
                case COMPRESSION_B44A: return "B44A";
                case COMPRESSION_DWAA: return "DWAA";
                case COMPRESSION_DWAB: return "DWAB";
            }
            return "code " + code;
        }

        // OpenEXR's RLE: a signed count byte. count < 0 -> -count LITERAL bytes
        // follow; count >= 0 -> the next byte repeats count+1 times. (This is
        // NOT the Radiance RLE above, and it is not `run-length` in the PackBits
        // sense either: the repeat length is count+1, not count.)
        //
        // The run data itself is NOT the raw scanline: see `unpredict` and
        // `deinterleave` (OpenEXRCore internal_rle.c).
        public static function rleDecode(src:ByteArray, byteCount:int, dst:ByteArray):void
        {
            var end:int = src.position + byteCount;
            while (src.position < end)
            {
                var count:int = src.readByte();
                if (count < 0)
                {
                    var literals:int = -count;
                    var j:int;
                    for (j = 0; j < literals; j++) dst.writeByte(src.readUnsignedByte());
                }
                else
                {
                    var value:int = src.readUnsignedByte();
                    var r:int;
                    for (r = 0; r <= count; r++) dst.writeByte(value);
                }
            }
        }

        // Inverse of OpenEXRCore `reorder_and_predict`'s delta step: after RLE,
        // byte i holds `(orig[i] - orig[i-1] + 128) mod 256` (orig[-1] == 0 for
        // the predictor's `p = t1[0]` seed, which is why the loop starts at 1).
        // The sum is cumulative, so it has to run left to right in place.
        public static function unpredict(buf:ByteArray, n:int):void
        {
            var i:int;
            for (i = 1; i < n; i++)
            {
                var d:int = (buf[i - 1] & 0xFF) + (buf[i] & 0xFF) - 128;
                buf[i] = d & 0xFF;
            }
        }

        // Inverse of `reorder_and_predict`'s byte shuffle: the predictor output was
        // split into even and odd positions (first half = even indices, second
        // half = odd), so the scanline interleaves the two halves.
        public static function deinterleave(buf:ByteArray, n:int, out:ByteArray):void
        {
            var half2:int = int((n + 1) / 2);
            var even:int = 0;
            var odd:int = half2;
            var s:int = 0;
            while (s < n)
            {
                out[s] = buf[even];
                even++;
                s++;
                if (s < n)
                {
                    out[s] = buf[odd];
                    odd++;
                    s++;
                }
            }
        }

        // IEEE 754 binary16 -> Number. Written out instead of using a lookup table
        // so the denormal and infinity branches are visible: EXR radiance is
        // positive and finite, but a corrupt channel must not become NaN silently.
        public static function halfToNumber(h:int):Number
        {
            var sign:int = (h >> 15) & 0x1;
            var exp:int = (h >> 10) & 0x1F;
            var mant:int = h & 0x3FF;
            var value:Number;
            if (exp == 0)
            {
                value = mant * Math.pow(2.0, -24.0);      // denormal
            }
            else if (exp == 31)
            {
                value = (mant == 0) ? Number.POSITIVE_INFINITY : Number.NaN;
            }
            else
            {
                value = (1.0 + mant / 1024.0) * Math.pow(2.0, exp - 15);
            }
            return (sign == 1) ? -value : value;
        }

        private static function halfAt(b:ByteArray, pos:int):Number
        {
            var lo:int = b[pos] & 0xFF;
            var hi:int = b[pos + 1] & 0xFF;
            return halfToNumber((hi << 8) | lo);
        }

        // One 4-byte little-endian float at `pos`, WITHOUT moving the caller's
        // cursor -- the chunk walk owns `position`. The bytes go through a scratch
        // ByteArray instead of being assembled with shifts because a float's bit
        // pattern is not an integer value (sign/exponent/mantissa are not
        // arithmetic fields, and (b3 << 24) is a negative int for any float >= 2).
        private static const _floatScratch:ByteArray = makeFloatScratch();

        private static function makeFloatScratch():ByteArray
        {
            var s:ByteArray = new ByteArray();
            s.endian = Endian.LITTLE_ENDIAN;
            s.length = 4;
            return s;
        }

        private static function floatAt(b:ByteArray, pos:int):Number
        {
            var s:ByteArray = EXRLoader._floatScratch;
            s[0] = b[pos];
            s[1] = b[pos + 1];
            s[2] = b[pos + 2];
            s[3] = b[pos + 3];
            s.position = 0;
            return s.readFloat();
        }

        private static function sampleAt(b:ByteArray, channelBase:int, x:int,
                                         bytesPerSample:int):Number
        {
            return (bytesPerSample == 2)
                ? halfAt(b, channelBase + x * 2)
                : floatAt(b, channelBase + x * 4);
        }

        // Linear RGB -> the Radiance RGBE quadruple HDRImage stores. Lossy by
        // construction (8-bit mantissa + shared 8-bit exponent), which is exactly
        // the precision .hdr itself carries and three orders of magnitude finer
        // than the 8-bit cube faces this ends up in (D167).
        public static function linearToRGBE(r:Number, g:Number, b:Number, out:ByteArray, offset:int):void
        {
            var v:Number = Math.max(r, Math.max(g, b));
            if (!(v > 1e-32) || !isFinite(v))
            {
                out[offset] = 0;
                out[offset + 1] = 0;
                out[offset + 2] = 0;
                out[offset + 3] = 0;
                return;
            }
            // Radiance's own `setcolr`: frexp() gives v = m * 2^e with m in [0.5,1).
            var e:int = Math.ceil(Math.log(v) / Math.LN2);
            var scale:Number = 255.0 / Math.pow(2.0, e);
            var re:int = int(Math.round(r * scale));
            var ge:int = int(Math.round(g * scale));
            var be:int = int(Math.round(b * scale));
            if (re > 255) re = 255;
            if (ge > 255) ge = 255;
            if (be > 255) be = 255;
            if (re < 0) re = 0;
            if (ge < 0) ge = 0;
            if (be < 0) be = 0;
            var ee:int = e + 128;
            if (ee > 255) ee = 255;
            if (ee < 0)
            {
                out[offset] = 0;
                out[offset + 1] = 0;
                out[offset + 2] = 0;
                out[offset + 3] = 0;
                return;
            }
            out[offset] = re;
            out[offset + 1] = ge;
            out[offset + 2] = be;
            out[offset + 3] = ee;
        }
    }
}