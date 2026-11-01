// GeometryM11.as -- M11 acceptance demo: the geometry family + frustum culling.
//
// Three things are on screen, and each maps to one M11 sub-item:
//
//   1. GALLERY (centre row). Left to right: CylinderGeometry, ConeGeometry,
//      TorusGeometry, LatheGeometry (a vase profile), TubeGeometry (swept along
//      a CatmullRomCurve3), CircleGeometry, RingGeometry. All are lit by the
//      same MeshStandardMaterial + directional/ambient pair the earlier
//      milestones established, so a normal or winding mistake shows up as a
//      wrong shade rather than as "a shape appeared".
//
//   2. EDGES (the box at the far right). A BoxGeometry with an EdgesGeometry
//      overlay drawn as LineSegments. Stage3D has no line primitive, so this
//      exercises the renderer's vertex-shader segment expansion. Toggling
//      DRAW_EDGES off must leave the box but drop the wireframe -- that is the
//      visual A/B for the line path.
//
//   3. CULLING (invisible by design). Forty small boxes are stacked into two
//      vertical walls at x = -45 and x = +45, i.e. outside the LEFT/RIGHT
//      planes of the frustum but well inside the 200-unit far plane, so the test
//      really is a plane rejection and not far clipping. They contribute NOTHING
//      to the image, so with culling on and off the frame must be
//      pixel-identical -- while renderer.drawCalls and renderer.culledObjects
//      report the difference. The counters are printed every 60 frames, which is
//      the evidence for the culling pass. The group is not animated: spinning it
//      swept boxes through the frustum and made the count frame-dependent.
//
// Build/run from asaot3d/:
//   node ../as3compiler/src/index.ts --air-app apps/geometry-m11/GeometryM11-app.xml \
//     --main-class GeometryM11 --as-class-path seam --as-class-path kit
//   ./apps/geometry-m11/GeometryM11 > temp/geometry-m11.log 2>&1 &
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.Box3;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Frustum;
    import asaot.three.core.Sphere;
    import asaot.three.objects.Group;
    import asaot.three.core.Object3D;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.CircleGeometry;
    import asaot.three.geometries.ConeGeometry;
    import asaot.three.geometries.CylinderGeometry;
    import asaot.three.geometries.EdgesGeometry;
    import asaot.three.geometries.LatheGeometry;
    import asaot.three.geometries.RingGeometry;
    import asaot.three.geometries.TorusGeometry;
    import asaot.three.geometries.TubeGeometry;
    import asaot.three.extras.curves.CatmullRomCurve3;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.LineBasicMaterial;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;
    import asaot.three.objects.LineSegments;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class GeometryM11 extends Stage3DApp
    {
        // A/B switches. Both are constants so the shipped demo is a fixed image;
        // flip one and rebuild to get the comparison shot.
        private static const DRAW_EDGES:Boolean = true;
        private static const FRUSTUM_CULLING:Boolean = true;
        // 40 boxes parked outside the frustum: drawn-but-invisible when culling
        // is off, rejected when it is on.
        private static const OFFSCREEN_COUNT:int = 40;

        override protected function createScene():void
        {
            _renderer.frustumCullingEnabled = FRUSTUM_CULLING;

            _scene = new Scene();

            _camera = new PerspectiveCamera(40, stage.stageWidth / stage.stageHeight, 0.1, 200);
            _camera.position.set(0, 1.2, 9.6);
            _camera.lookAt(0, 0.15, 0);

            var ambient:AmbientLight = new AmbientLight(0xffffff, 0.22);
            _scene.add(ambient);

            var key:DirectionalLight = new DirectionalLight(0xffffff, 1.6);
            key.position.set(3, 6, 7);
            // No shadow in this demo: the gallery has no receiver surface, and a
            // DirectionalLightShadow defaults to an orthographic box of +-5
            // (three.js DirectionalLightShadow), which would not even cover this
            // ~13-unit row. Shadow quality (PCF, auto-fit bounds, normalBias) is
            // M13's subject; M7/M13 demos are where shadows are exercised.
            key.castShadow = false;
            _scene.add(key);

            buildGallery();
            buildEdges();
            buildOffscreenRing();

            // NOTE: Sphere(center, radius) keeps a REFERENCE to the center Vector3
            // (three.js Sphere.js:20 does the same), so feeding it
            // geometry.boundingSphere.center and then applyMatrix4() writes the
            // WORLD position back into the geometry's local bounding sphere. Use a
            // scratch copy instead -- doing it the other way silently corrupts
            // culling (the transform then gets applied twice).
            _scene.updateMatrixWorld(true);
            _camera.updateMatrixWorld(true);
            _camera.updateMatrixWorldInverse();
            var vp:Matrix4 = new Matrix4().multiplyMatrices(_camera.projectionMatrix, _camera.matrixWorldInverse);
            var f:Frustum = new Frustum();
            f.setFromProjectionMatrix(vp);
            var scratch:Sphere = new Sphere();
            var checked:int = 0;
            var outside:int = 0;
            var diag:int = 0;
            while (diag < _scene.children.length)
            {
                var o:Object3D = _scene.children[diag];
                if (o is Mesh && Mesh(o).geometry != null)
                {
                    var m2:Mesh = Mesh(o);
                    var g:BufferGeometry = m2.geometry;
                    if (g.boundingSphere == null) g.computeBoundingSphere();
                    scratch.copy(g.boundingSphere).applyMatrix4(m2.matrixWorld);
                    if (!f.intersectsSphere(scratch)) outside++;
                    checked++;
                }
                diag++;
            }
            logLine("diag: " + checked + " root meshes, " + outside + " outside the camera frustum");
        }

        // ------------------------------------------------------------------
        // 1. the geometry gallery
        // ------------------------------------------------------------------

        private function buildGallery():void
        {
            var items:Array = [];
            var x0:Number = -6.1;
            var step:Number = 1.75;

            // Cylinder: the M11 primitive that also backs ConeGeometry.
            var cyl:Mesh = new Mesh(new CylinderGeometry(0.45, 0.45, 1.3, 32, 8),
                                    standard(0xcccfd8, 0.35, 0.15));
            items.push(cyl);

            // Cone: radiusTop = 0, so no top cap and the apex triangles are the
            // ones CylinderGeometry's guards skip.
            var cone:Mesh = new Mesh(new ConeGeometry(0.6, 1.3, 32, 8),
                                     standard(0xe0a860, 0.5, 0.05));
            items.push(cone);

            // Torus: lies in XY with the hole on Z, so it faces this camera.
            var torus:Mesh = new Mesh(new TorusGeometry(0.52, 0.2, 24, 48),
                                      standard(0x9ad3a0, 0.25, 0.1));
            items.push(torus);

            // Lathe: a vase profile (radius, height) revolved about Y.
            var profile:Vector.<Vector2> = new Vector.<Vector2>();
            profile.push(new Vector2(0.00, -0.75));
            profile.push(new Vector2(0.30, -0.72));
            profile.push(new Vector2(0.46, -0.30));
            profile.push(new Vector2(0.34, 0.18));
            profile.push(new Vector2(0.22, 0.44));
            profile.push(new Vector2(0.30, 0.62));
            profile.push(new Vector2(0.26, 0.72));
            var lathe:Mesh = new Mesh(new LatheGeometry(profile, 48),
                                      standard(0xb9a2e0, 0.4, 0.05));
            items.push(lathe);

            // Tube: a swept circle along a 3D Catmull-Rom spline. Three control
            // points that are NOT collinear, so the Frenet frames actually twist.
            var path:Vector.<Vector3> = new Vector.<Vector3>();
            path.push(new Vector3(-0.55, -0.6, 0.25));
            path.push(new Vector3(0.0, 0.55, -0.35));
            path.push(new Vector3(0.55, 0.2, 0.35));
            var tube:Mesh = new Mesh(new TubeGeometry(new CatmullRomCurve3(path), 48, 0.11, 12),
                                     standard(0x7fb2e6, 0.3, 0.05));
            items.push(tube);

            // Circle / Ring: both flat in XY, both single-sided (side = Front),
            // so the winding is visible as "faces the camera" vs "disappears".
            var circle:Mesh = new Mesh(new CircleGeometry(0.62, 48),
                                       standard(0xe0776f, 0.3, 0.05));
            items.push(circle);

            var ring:Mesh = new Mesh(new RingGeometry(0.32, 0.62, 64, 1),
                                     standard(0xd8d2c0, 0.3, 0.05));
            items.push(ring);

            var i:int;
            for (i = 0; i < items.length; i++)
            {
                var mesh:Mesh = Mesh(items[i]);
                mesh.position.set(x0 + i * step, 0.15, 0);
                _scene.add(mesh);
                // 0..4 are the closed solids, 5/6 are the flat Circle and Ring.
                if (i < 5) _spinners.push(mesh);
            }

            // A dim floor line of boxes so the row does not float in a void.
            var j:int = 0;
            while (j < 8)
            {
                var plinth:Mesh = new Mesh(new BoxGeometry(1.25, 0.12, 1.0),
                                           standard(0x2a2f3a, 0.85, 0.0));
                plinth.position.set(x0 + j * step, -0.72, 0);
                _scene.add(plinth);
                j++;
            }
        }

        // ------------------------------------------------------------------
        // 2. edges overlay (LineSegments + vertex-shader segment expansion)
        // ------------------------------------------------------------------

        private function buildEdges():void
        {
            var box:Mesh = new Mesh(new BoxGeometry(1.1, 1.1, 1.1),
                                    standard(0x39404d, 0.8, 0.0));
            box.position.set(-6.1 + 7 * 1.75, 0.15, 0);
            box.rotation.set(0.35, 0.6, 0.0);
            _scene.add(box);
            _spinners.push(box);

            if (!DRAW_EDGES) return;

            var edges:EdgesGeometry = new EdgesGeometry(box.geometry, 1);
            var lineMat:LineBasicMaterial = new LineBasicMaterial(0x8fd2ff);
            lineMat.linewidth = 2;
            var lines:LineSegments = new LineSegments(edges, lineMat);
            _lines = lines;
            lines.position.copy(box.position);
            lines.rotation.copy(box.rotation);
            _scene.add(lines);

            // 12 hard edges of the source box, 2 vertices each. A box has 36
            // triangle edges; EdgesGeometry keeps only the 12 the eye sees.
            var ep:BufferAttribute = edges.getAttribute("position");
            logLine("edges: " + ep.count + " vertices (" + (ep.count / 2) + " segments)");
        }

        // ------------------------------------------------------------------
        // 3. the off-screen ring (culling evidence)
        // ------------------------------------------------------------------

        private var _offscreen:Group;
        // Only the closed solids spin: a flat Circle/Ring turned slowly about Y
        // spends most of its time near edge-on, which makes the gallery look
        // empty for no reason. The discs stay face-on so the winding is provable
        // from any single frame.
        private var _spinners:Array = [];
        private var _lines:LineSegments;

        private function buildOffscreenRing():void
        {
            _offscreen = new Group();
            var geom:BoxGeometry = new BoxGeometry(1, 1, 1);
            // Never shaded while culling is on, so the colour carries no
            // meaning; it is a plain surface tone rather than a debug green.
            var mat:MeshStandardMaterial = standard(0x39404d, 0.5, 0.0);

            // Two vertical walls at x = +-45. The frustum's half width at that
            // depth is ~26 units, so every one of them is rejected by the LEFT /
            // RIGHT planes -- a genuine plane test, not far-plane clipping (they
            // sit well inside the 200-unit far plane, so turning culling off
            // still draws them; they just land outside the viewport).
            var i:int = 0;
            while (i < OFFSCREEN_COUNT)
            {
                var m:Mesh = new Mesh(geom, mat);
                var side:Number = (i % 2 == 0) ? -45 : 45;
                var k:int = i >> 1;
                m.position.set(side, -8 + (k % 10) * 1.8, -8 + (k / 10) * 8);
                _offscreen.add(m);
                i++;
            }

            _scene.add(_offscreen);
        }

        // ------------------------------------------------------------------

        private function standard(hex:uint, roughness:Number, metalness:Number):MeshStandardMaterial
        {
            var m:MeshStandardMaterial = new MeshStandardMaterial();
            m.color.setHex(hex);
            m.roughness = roughness;
            m.metalness = metalness;
            return m;
        }

        private var _frameCount:int = 0;

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frameCount++;

            // Slow spin so the gallery reads as 3D and the normals are exercised
            // from several angles; the plinths and the flat discs stay put so the
            // row is stable and the discs never turn edge-on.
            var i:int;
            for (i = 0; i < _spinners.length; i++)
            {
                Mesh(_spinners[i]).rotation.y += 0.006;
            }
            if (_lines != null) _lines.rotation.y += 0.006;
            // The off-screen ring is deliberately NOT spun any more: rotating it
            // swept boxes through the frustum and changed the culled count frame
            // to frame, which makes the A/B numbers noisy.
            if (_offscreen != null) _offscreen.rotation.y = 0.0;
        }

        // Counters run AFTER present so they describe the frame that was just
        // drawn. Every 60 frames: short log, steady-state numbers (the first
        // frame builds buffers).
        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_frameCount % 60 == 0)
            {
                logLine("frame " + _frameCount
                      + " drawCalls=" + _renderer.drawCalls
                      + " triangles=" + _renderer.triangles
                      + " culled=" + _renderer.culledObjects
                      + " cullingEnabled=" + _renderer.frustumCullingEnabled);
            }
        }
    }
}