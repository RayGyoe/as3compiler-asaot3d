// VtfAir.as -- AIR/adl reference answers for the two capability questions that
// the AOT probe (../probe.as) asks of our own backend:
//   1. is Context3DTextureFormat.RGBA_HALF_FLOAT accepted on this profile, and
//      does a half-float render target actually keep values above 1.0?
//   2. does AIR accept a VERTEX-stage texture fetch (AGAL `tld` + `vs0`)?
package
{
    import com.adobe.utils.AGALMiniAssembler;
    import flash.display.BitmapData;
    import flash.display.Sprite;
    import flash.display.Stage3D;
    import flash.display3D.Context3D;
    import flash.display3D.Context3DProgramType;
    import flash.display3D.Context3DRenderMode;
    import flash.display3D.Context3DTextureFormat;
    import flash.display3D.Context3DVertexBufferFormat;
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.Program3D;
    import flash.display3D.VertexBuffer3D;
    import flash.display3D.textures.Texture;
    import flash.events.Event;
    import flash.events.ErrorEvent;
    import flash.events.TimerEvent;
    import flash.utils.Timer;
    import flash.desktop.NativeApplication;
    import flash.filesystem.File;
    import flash.filesystem.FileStream;
    import flash.filesystem.FileMode;
    import flash.utils.ByteArray;

    public class VtfAir extends Sprite
    {
        private var ctx:Context3D;
        private var ib:IndexBuffer3D;
        private var log:Vector.<String> = new Vector.<String>();
        private var pQuad:Program3D;
        private var frames:int = 0;

        // adl on macOS forwards neither trace() nor uncaught errors, so the log goes
        // to a file. The location is chosen by measurement, not by taste:
        //   applicationDirectory -- READ-ONLY for an AIR app; open(APPEND) throws and
        //     the catch turns the whole probe silent (run exited 0, wrote nothing).
        //   relative "air-out.txt" -- resolves against the adl runtime directory, same
        //     failure mode.
        // userDirectory ($HOME) is writable and stable under adl, so build.sh --run
        // knows exactly where to read the result.
        public static const LOG_NAME:String = "asaot-fmt-vtf-air.txt";

        private function outFile():File
        {
            return File.userDirectory.resolvePath(LOG_NAME);
        }

        private function say(m:String):void
        {
            log.push(m); trace(m);
            try {
                var f:File = outFile();
                var fs:FileStream = new FileStream();
                fs.open(f, FileMode.APPEND);
                fs.writeUTFBytes(m + "\n");
                fs.close();
            } catch (ew:Error) { trace("log write failed: " + ew.message); }
        }

        private function flush():void {
            var f:File = outFile();
            var fs:FileStream = new FileStream();
            fs.open(f, FileMode.WRITE);
            var i:int;
            for (i = 0; i < log.length; i++) fs.writeUTFBytes(log[i] + "\n");
            fs.close();
        }
        private var started:Boolean = false;

        public function VtfAir()
        {
            // `stage` is null in a document class's constructor, so the Stage3D
            // handshake has to wait for ADDED_TO_STAGE.
            addEventListener(Event.ADDED_TO_STAGE, onAdded);
        }

        private function onAdded(e:Event):void
        {
            say("added to stage");
            stage.stage3Ds[0].addEventListener(Event.CONTEXT3D_CREATE, onCtx);
            stage.stage3Ds[0].addEventListener(ErrorEvent.ERROR, onErr);
            stage.stage3Ds[0].requestContext3D(Context3DRenderMode.AUTO, "enhanced");
            var tm:Timer = new Timer(500, 8);
            tm.addEventListener(TimerEvent.TIMER, function(te:TimerEvent):void {
                var c3:Context3D = stage.stage3Ds[0].context3D;
                say("tick " + te.target.currentCount + " ctx=" + (c3 == null ? "null" : "ok"));
            });
            tm.start();
        }

        private function onErr(e:ErrorEvent):void { trace("Stage3D error: " + e.text); }

        private function onCtx(e:Event):void
        {
            if (started) return;
            started = true;
            ctx = stage.stage3Ds[0].context3D;
            say("onCtx fired");
            try { ctx.configureBackBuffer(200, 150, 0, true); }
            catch (eb:Error) { say("configureBackBuffer threw " + eb.errorID + " " + eb.message); return; }
            say("driver: " + ctx.driverInfo);
            run();
        }

        private function run():void
        {
            // ---- 1. half float ----
            try {
                var h:Texture = ctx.createTexture(4, 4, Context3DTextureFormat.RGBA_HALF_FLOAT, false);
                say("AIR half createTexture -> ok");
            } catch (e1:Error) {
                say("AIR half createTexture -> throw " + e1.errorID + " " + e1.message);
            }
            try {
                var b:Texture = ctx.createTexture(4, 4, Context3DTextureFormat.BGRA, false);
                say("AIR bgra createTexture -> ok");
            } catch (e2:Error) { say("AIR bgra createTexture -> throw " + e2.message); }

            try { ctx.createTexture(4, 4, "rgba", false); say("AIR rgba string -> ok"); }
            catch (e4:Error) { say("AIR rgba string -> throw " + e4.errorID + " " + e4.message); }

            var cube:flash.display3D.textures.CubeTexture;
            try {
                cube = ctx.createCubeTexture(8, Context3DTextureFormat.RGBA_HALF_FLOAT, false);
                say("AIR half createCubeTexture -> ok");
            } catch (e5:Error) {
                say("AIR half createCubeTexture -> throw " + e5.errorID + " " + e5.message);
            }
            if (cube != null) {
                var cb:BitmapData = new BitmapData(8, 8, true, 0xFFFF0000);
                try { cube.uploadFromBitmapData(cb, 0, 0); say("AIR half cube upload level0 -> ok"); }
                catch (e6:Error) { say("AIR half cube upload level0 -> throw " + e6.errorID + " " + e6.message); }
                try { cube.uploadFromBitmapData(cb, 0, 1); say("AIR cube upload miplevel=1 -> ok"); }
                catch (e7:Error) { say("AIR cube upload miplevel=1 -> throw " + e7.errorID + " " + e7.message); }
            }

            // ---- 2. vertex texture fetch ----
            var pos:Vector.<Number> = Vector.<Number>([-1,-1,0, 3,-1,0, -1,3,0]);
            var uv:Vector.<Number> = Vector.<Number>([0.5,0.5,0, 0.5,0.5,0, 0.5,0.5,0]);
            var vb:VertexBuffer3D = ctx.createVertexBuffer(3, 3);
            vb.uploadFromVector(pos, 0, 3);
            ctx.setVertexBufferAt(0, vb, 0, Context3DVertexBufferFormat.FLOAT_3);
            var vbu:VertexBuffer3D = ctx.createVertexBuffer(3, 3);
            vbu.uploadFromVector(uv, 0, 3);
            ctx.setVertexBufferAt(1, vbu, 0, Context3DVertexBufferFormat.FLOAT_3);
            var idx:Vector.<uint> = Vector.<uint>([0,1,2]);
            ib = ctx.createIndexBuffer(3);
            ib.uploadFromVector(idx, 0, 3);

            var cout:Number = 0.25;
            assembleAndDraw("tld vt0, va1.xy, vs0 <2d,clamp,linear,mipnone>, va1.z\n", "tld/vs0");

            // drawToBitmapData only works on a presented frame, so the visible
            // draw + readback happen in the next ENTER_FRAME.
            addEventListener(Event.ENTER_FRAME, onFrame);
        }

        private function onFrame(e:Event):void
        {
            frames++;
            ctx.setRenderToBackBuffer();
            ctx.clear(0, 0, 0, 1, 1.0, 0, 7);
            try {
                ctx.drawTriangles(ib, 0, 1);
                if (frames >= 3) {
                    // Read the back buffer BEFORE present(): AIR's #3692 means the
                    // copy has to happen inside the same cleared frame as the draw.
                    var bd0:BitmapData = new BitmapData(200, 150, false, 0);
                    ctx.drawToBitmapData(bd0);
                    say("readback=" + bd0.getPixel(100, 75).toString(16));
                }
                if (frames >= 3) ctx.present();
                say("frame " + frames + " draw ok");
            } catch (e3:Error) {
                say("frame " + frames + " draw threw " + e3.errorID + " " + e3.message);
                say("RESULT done"); flush(); NativeApplication.nativeApplication.exit(); return;
            }
            if (frames < 3) return;   // stabilise: clear+draw+present must be per frame
            removeEventListener(Event.ENTER_FRAME, onFrame);
            var bd:BitmapData = new BitmapData(200, 150, false, 0);
            try {
                ctx.drawToBitmapData(bd);
                say("readback=" + bd.getPixel(100, 75).toString(16));
            } catch (e2:Error) {
                say("drawToBitmapData threw " + e2.errorID + " " + e2.message);
            }
            say("RESULT done");
            flush();
            NativeApplication.nativeApplication.exit();
        }

        private function assembleAndDraw(texLine:String, label:String):void
        {
            var asmV:AGALMiniAssembler = new AGALMiniAssembler();
            var asmF:AGALMiniAssembler = new AGALMiniAssembler();
            var vsrc:String = "mov op, va0\n" + texLine + "mov v0, vt0\n";
            var fsrc:String = "mov oc, v0\n";
            var vp:ByteArray = asmV.assemble(Context3DProgramType.VERTEX, vsrc, 4);
            say(label + " vertex assemble error='" + asmV.error + "'");
            if (vp == null) return;
            var fp:ByteArray = asmF.assemble(Context3DProgramType.FRAGMENT, fsrc, 4);
            var p:Program3D = ctx.createProgram();
            try {
                p.upload(vp, fp);
                say(label + " upload -> ok");
            } catch (e:Error) {
                say(label + " upload -> throw " + e.errorID + " " + e.message);
                return;
            }

            var t:Texture = ctx.createTexture(4, 4, Context3DTextureFormat.BGRA, false);
            var src:BitmapData = new BitmapData(4, 4, true, 0xFF00FF00);
            t.uploadFromBitmapData(src);
            ctx.setTextureAt(0, t);
            ctx.setProgram(p);
            pQuad = p;
            // The draw itself happens in onFrame(): AIR insists that every
            // frame's first Stage3D call is clear(), so no draw lives here.
            say(label + " bound (draw happens in the next frames)");
        }
    }
}