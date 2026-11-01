// AnimationM12.as -- M12 acceptance demo: the animation family end to end.
//
// Three objects, each proving one half of M12:
//
//   1. KEYFRAME (left). A carousel group driven by a real AnimationClip with
//      three tracks on the SAME node: position (VectorKeyframeTrack), quaternion
//      (QuaternionKeyframeTrack, slerped) and scale (VectorKeyframeTrack). If the
//      mixer's weighted accumulation or the quaternion interpolant were wrong the
//      motion would stutter or drift instead of looping cleanly.
//
//   2. MORPH (centre). A sphere with one glTF-style RELATIVE morph target (the
//      vertices are pushed out along their own direction) whose
//      morphTargetInfluences[0] is an ArrayElement-bound NumberKeyframeTrack.
//      The mixer writes the influence, Mesh.updateDeform (called by the seam
//      renderer) rebuilds the position/normal arrays and bumps their version so
//      the vertex buffer re-uploads.
//
//   3. SKINNING (right). A tapered tube built here vertex by vertex, bound to a
//      chain of six Bones with two-bone linear weights. Each bone has its own
//      quaternion track, so the whole tube whips. Skinning runs on the CPU
//      (D84: AGAL/Stage3D has no bone matrix palette input), and the renderer
//      uploads the deformed positions like any other geometry.
//
// Counters printed every 60 frames carry the evidence: mixer time, the carousel
// position, the morph influence, the tentacle tip position, a checksum of the
// skinned positions (it must differ from the bind pose), and the draw stats.
//
// Build/run from asaot3d/:
//   node ../as3compiler/src/index.ts --air-app apps/animation-m12/AnimationM12-app.xml \
//     --main-class AnimationM12 --as-class-path seam --as-class-path kit
//   ./apps/animation-m12/AnimationM12 > temp/animation-m12.log 2>&1 &
package
{
    import asaot.three.AGALRenderer;
    import asaot.three.animation.AnimationAction;
    import asaot.three.animation.AnimationClip;
    import asaot.three.animation.AnimationMixer;
    import asaot.three.animation.KeyframeTrack;
    import asaot.three.animation.NumberKeyframeTrack;
    import asaot.three.animation.QuaternionKeyframeTrack;
    import asaot.three.animation.VectorKeyframeTrack;
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.core.BufferAttribute;
    import asaot.three.core.BufferGeometry;
    import asaot.three.core.Object3D;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.math.Color;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Vector3;
    import asaot.three.objects.Bone;
    import asaot.three.objects.Group;
    import asaot.three.objects.Mesh;
    import asaot.three.objects.Skeleton;
    import asaot.three.objects.SkinnedMesh;
    import asaot.three.scenes.Scene;

    public class AnimationM12 extends Stage3DApp
    {
        private var _mixer:AnimationMixer;
        private var _actions:Vector.<AnimationAction>;

        private var _carousel:Group;
        private var _morphSphere:Mesh;
        private var _tentacle:SkinnedMesh;

        // 6 bones, 32 rings, 10 radial segments.
        private static const BONE_COUNT:int = 6;
        private static const RINGS:int = 32;
        private static const RADIAL:int = 10;
        private static const TENTACLE_LEN:Number = 3.0;
        private static const TENTACLE_RADIUS:Number = 0.34;

        private var _frameCount:int = 0;
        private var _bindChecksum:Number = 0;

        // Frames advance by real wall-clock time, not by a fixed step: the host
        // runs the application clock at the display's refresh rate (120 Hz here),
        // so a fixed 1/60 per frame would play every clip at double speed.
        private static const MAX_STEP:Number = 0.1;

        override protected function createScene():void
        {
            _scene = new Scene();
            _scene.background = new Color(0x0d1016);

            _camera = new PerspectiveCamera(40, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 1.15, 9.2);
            _camera.lookAt(0, 0.7, 0);

            _scene.add(new AmbientLight(0xffffff, 0.25));
            var key:DirectionalLight = new DirectionalLight(0xffffff, 1.7);
            key.position.set(3, 6, 7);
            key.castShadow = false;
            _scene.add(key);
            var fill:DirectionalLight = new DirectionalLight(0x88aaff, 0.55);
            fill.position.set(-5, 2, -4);
            fill.castShadow = false;
            _scene.add(fill);

            buildGround();
            buildCarousel();
            buildMorph();
            buildTentacle();

            buildAnimation();

            // Bind-pose checksum, taken before the first deform, so the log can
            // prove the skinning actually changed the vertices.
            _bindChecksum = _tentacle.geometry == null ? 0 : checksum(_tentacle.geometry.getAttribute("position").array);

            logLine("diag: actions=" + _actions.length
                  + " bones=" + _tentacle.skeleton.bones.length
                  + " tentacleVerts=" + _tentacle.geometry.getAttribute("position").count
                  + " tentacleTris=" + (_tentacle.geometry.index.count / 3)
                  + " bindChecksum=" + fmt(_bindChecksum));
        }

        // ------------------------------------------------------------------
        // scene content
        // ------------------------------------------------------------------

        private function buildGround():void
        {
            var ground:Mesh = new Mesh(new PlaneGeometry(26, 26, 1, 1), standard(0x1b2130, 0.9, 0.0));
            ground.rotation.x = -Math.PI / 2;
            ground.position.y = -1.35;
            ground.name = "ground";
            _scene.add(ground);
        }

        private function buildCarousel():void
        {
            // The animated node is the GROUP; its child box just gives it a
            // readable silhouette.
            _carousel = new Group();
            _carousel.name = "carousel";
            _carousel.position.set(-3.0, 0.45, 0);

            var box:Mesh = new Mesh(new BoxGeometry(1.05, 1.05, 1.05), standard(0xcccfd8, 0.62, 0.12));
            box.name = "carouselBox";
            _carousel.add(box);

            var edge:Mesh = new Mesh(new BoxGeometry(1.18, 0.06, 1.18), standard(0xe0a860, 0.5, 0.05));
            edge.position.y = -0.62;
            _carousel.add(edge);

            _scene.add(_carousel);
        }

        private function buildMorph():void
        {
            var geometry:BufferGeometry = new SphereGeometry(0.72, 40, 28);
            var position:BufferAttribute = geometry.getAttribute("position");
            var normal:BufferAttribute = geometry.getAttribute("normal");

            // A relative ("displaced") target, exactly the shape glTF morph
            // targets take: three angular lobes around Y.
            var count:int = position.count;
            var delta:Vector.<Number> = new Vector.<Number>(count * 3);
            var src:Vector.<Number> = position.array;
            for (var i:int = 0; i < count; i++)
            {
                var nx:Number = normal.array[i * 3];
                var ny:Number = normal.array[i * 3 + 1];
                var nz:Number = normal.array[i * 3 + 2];

                // The lobes are indexed by the angle around Y, so the angular
                // factor has to vanish at the poles: a pole vertex's normal is
                // (0,+-1,0), atan2(0,0) is arbitrary, and the duplicated pole
                // vertices would otherwise disagree and tear the surface open.
                var radial:Number = Math.sqrt(nx * nx + nz * nz);
                var theta:Number = (radial > 1e-6) ? Math.atan2(nz, nx) : 0.0;
                var lobe:Number = 0.32 * (1.0 + Math.cos(3.0 * theta)) * radial;

                delta[i * 3] = nx * lobe;
                delta[i * 3 + 1] = ny * lobe;
                delta[i * 3 + 2] = nz * lobe;
            }

            geometry.morphAttributes["position"] = new <BufferAttribute>[new BufferAttribute(delta, 3)];
            geometry.morphTargetsRelative = true;

            _morphSphere = new Mesh(geometry, standard(0x9ad3a0, 0.28, 0.08));
            _morphSphere.name = "morphSphere";
            _morphSphere.position.set(0.0, 0.5, 0);
            _morphSphere.updateMorphTargets();
            _scene.add(_morphSphere);
        }

        // A tapered tube along +Y, weighted to a chain of bones. Built here rather
        // than from CylinderGeometry because the demo needs the explicit
        // skinIndex/skinWeight attributes and a bone-aligned vertex layout.
        private function buildTentacle():void
        {
            var geometry:BufferGeometry = new BufferGeometry();

            var vertsPerRing:int = RADIAL;
            var ringCount:int = RINGS + 1;
            var vertCount:int = ringCount * vertsPerRing;

            var position:Vector.<Number> = new Vector.<Number>(vertCount * 3);
            var normal:Vector.<Number> = new Vector.<Number>(vertCount * 3);
            var skinIndex:Vector.<Number> = new Vector.<Number>(vertCount * 4);
            var skinWeight:Vector.<Number> = new Vector.<Number>(vertCount * 4);

            var boneSpacing:Number = TENTACLE_LEN / (BONE_COUNT - 1);

            for (var r:int = 0; r < ringCount; r++)
            {
                var t:Number = r / RINGS;
                var y:Number = t * TENTACLE_LEN;
                var radius:Number = TENTACLE_RADIUS * (1.0 - 0.45 * t);

                // two-bone linear weights along the chain
                var f:Number = y / boneSpacing;
                var b0:int = Math.floor(f);
                if (b0 > BONE_COUNT - 1) b0 = BONE_COUNT - 1;
                if (b0 < 0) b0 = 0;
                var b1:int = b0 + 1;
                if (b1 > BONE_COUNT - 1) b1 = BONE_COUNT - 1;
                var w1:Number = (b1 == b0) ? 0.0 : (f - b0);
                if (w1 < 0) w1 = 0;
                if (w1 > 1) w1 = 1;
                var w0:Number = 1.0 - w1;

                for (var j:int = 0; j < vertsPerRing; j++)
                {
                    var angle:Number = (j / vertsPerRing) * Math.PI * 2;
                    var cx:Number = Math.cos(angle);
                    var cz:Number = Math.sin(angle);

                    var v:int = r * vertsPerRing + j;
                    position[v * 3] = cx * radius;
                    position[v * 3 + 1] = y;
                    position[v * 3 + 2] = cz * radius;

                    normal[v * 3] = cx;
                    normal[v * 3 + 1] = 0;
                    normal[v * 3 + 2] = cz;

                    skinIndex[v * 4] = b0;
                    skinIndex[v * 4 + 1] = b1;
                    skinIndex[v * 4 + 2] = 0;
                    skinIndex[v * 4 + 3] = 0;

                    skinWeight[v * 4] = w0;
                    skinWeight[v * 4 + 1] = w1;
                    skinWeight[v * 4 + 2] = 0;
                    skinWeight[v * 4 + 3] = 0;
                }
            }

            var index:Vector.<Number> = new Vector.<Number>();
            for (var ring:int = 0; ring < RINGS; ring++)
            {
                for (var k:int = 0; k < vertsPerRing; k++)
                {
                    var k2:int = (k + 1) % vertsPerRing;
                    var a:int = ring * vertsPerRing + k;
                    var b:int = (ring + 1) * vertsPerRing + k;
                    var c:int = (ring + 1) * vertsPerRing + k2;
                    var d:int = ring * vertsPerRing + k2;

                    index.push(a); index.push(b); index.push(d);
                    index.push(b); index.push(c); index.push(d);
                }
            }

            geometry.setAttribute("position", new BufferAttribute(position, 3));
            geometry.setAttribute("normal", new BufferAttribute(normal, 3));
            geometry.setAttribute("skinIndex", new BufferAttribute(skinIndex, 4));
            geometry.setAttribute("skinWeight", new BufferAttribute(skinWeight, 4));
            geometry.setIndex(new BufferAttribute(index, 1));

            // Culling note (documented divergence): bounding volumes are computed
            // from the BIND pose, so a whipping tentacle can swing outside them.
            // Pad the sphere instead of disabling culling for the whole scene.
            geometry.computeBoundingSphere();
            geometry.boundingSphere.radius *= 1.8;

            _tentacle = new SkinnedMesh(geometry, standard(0xd88ad0, 0.3, 0.05));
            _tentacle.name = "tentacle";
            _tentacle.position.set(3.0, -1.3, 0);

            var bones:Vector.<Object3D> = new Vector.<Object3D>();
            var previous:Bone = null;
            for (var bi:int = 0; bi < BONE_COUNT; bi++)
            {
                var bone:Bone = new Bone();
                bone.name = "bone" + bi;
                // Chain them: every bone after the first sits one spacing above
                // its parent, so a rotation accumulates down the tube.
                bone.position.set(0, bi == 0 ? 0 : boneSpacing, 0);
                if (previous != null) previous.add(bone);
                else _tentacle.add(bone);
                previous = bone;
                bones.push(bone);
            }

            // Bind pose = the positions above, so the inverse binds are the
            // translation inverses of each bone's world matrix.
            _tentacle.updateMatrixWorld(true);
            var skeleton:Skeleton = new Skeleton(bones, null);
            skeleton.calculateInverses();
            // bind() with no matrix uses the mesh's world matrix (three.js
            // SkinnedMesh.bind default). Passing an identity here while the bones
            // hang off the mesh would apply the mesh's own translation twice:
            // bone.matrixWorld already contains it, and the vertex shader adds it
            // again through the model matrix.
            _tentacle.bind(skeleton);

            _scene.add(_tentacle);
        }

        // ------------------------------------------------------------------
        // clips + mixer
        // ------------------------------------------------------------------

        private function buildAnimation():void
        {
            _mixer = new AnimationMixer(_scene);
            _actions = new Vector.<AnimationAction>();

            // --- carousel: position / quaternion / scale -------------------
            var carouselTracks:Vector.<KeyframeTrack> = new Vector.<KeyframeTrack>();
            carouselTracks.push(new VectorKeyframeTrack("carousel.position",
                vec([0, 1, 2]), vec([-3.0, 0.45, 0,  -3.0, 0.95, 0,  -3.0, 0.45, 0])));

            var qv:Vector.<Number> = new Vector.<Number>();
            quatAxisZ(0.0, qv);                    // facing +Z
            quatAxisY(Math.PI, qv);                // half turn
            quatAxisY(Math.PI * 2, qv);            // full turn (same as identity)
            carouselTracks.push(new QuaternionKeyframeTrack("carousel.quaternion",
                vec([0, 1, 2]), qv));

            carouselTracks.push(new VectorKeyframeTrack("carousel.scale",
                vec([0, 1, 2]), vec([1, 1, 1,  1.18, 1.18, 1.18,  1, 1, 1])));

            var carouselClip:AnimationClip = new AnimationClip("carouselClip", 2, carouselTracks);
            var carouselAction:AnimationAction = _mixer.clipAction(carouselClip);
            carouselAction.play();
            _actions.push(carouselAction);

            // --- morph influence ------------------------------------------
            var morphTracks:Vector.<KeyframeTrack> = new Vector.<KeyframeTrack>();
            morphTracks.push(new NumberKeyframeTrack("morphSphere.morphTargetInfluences[0]",
                vec([0, 1, 2]), vec([0, 1, 0])));
            var morphClip:AnimationClip = new AnimationClip("morphClip", 2, morphTracks);
            var morphAction:AnimationAction = _mixer.clipAction(morphClip);
            morphAction.play();
            _actions.push(morphAction);

            // --- tentacle bones -------------------------------------------
            // Each bone swings +-26 degrees about Z, with the amplitude growing
            // toward the tip so the tube reads as a whip rather than a rigid
            // stick. Keys at 0/1/2 make the loop seamless.
            var skinTracks:Vector.<KeyframeTrack> = new Vector.<KeyframeTrack>();
            for (var b:int = 0; b < BONE_COUNT; b++)
            {
                var amp:Number = 0.10 + 0.05 * b;
                var keys:Vector.<Number> = new Vector.<Number>();
                quatAxisZ(amp, keys);
                quatAxisZ(0.0, keys);
                quatAxisZ(-amp, keys);

                skinTracks.push(new QuaternionKeyframeTrack("bone" + b + ".quaternion",
                    vec([0, 1, 2]), keys));
            }
            var skinClip:AnimationClip = new AnimationClip("skinClip", 2, skinTracks);
            var skinAction:AnimationAction = _mixer.clipAction(skinClip);
            skinAction.play();
            _actions.push(skinAction);
        }

        // Appends one quaternion (x,y,z,w) to `out`.
        private function quatAxisZ(angle:Number, out:Vector.<Number>):void
        {
            var q:Quaternion = new Quaternion().setFromAxisAngle(new Vector3(0, 0, 1), angle);
            out.push(q.x); out.push(q.y); out.push(q.z); out.push(q.w);
        }

        private function quatAxisY(angle:Number, out:Vector.<Number>):void
        {
            var q:Quaternion = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), angle);
            out.push(q.x); out.push(q.y); out.push(q.z); out.push(q.w);
        }

        // ------------------------------------------------------------------
        // frame loop
        // ------------------------------------------------------------------

        override protected function updateFrame(elapsedMs:Number):void
        {
            _frameCount++;

            // Seconds, clamped: a hiccup (or the first frame, which reports 0)
            // must not teleport the clip.
            var dt:Number = elapsedMs / 1000.0;
            if (dt > MAX_STEP) dt = MAX_STEP;
            _mixer.update(dt);
        }

        override protected function afterFrame(elapsedMs:Number):void
        {
            if (_frameCount % 60 == 0)
            {
                var geometry:BufferGeometry = _tentacle.geometry;
                var pos:Vector.<Number> = geometry.getAttribute("position").array;
                var morphPos:Vector.<Number> = _morphSphere.geometry.getAttribute("position").array;
                var tipIndex:int = (RINGS * RADIAL + 0) * 3;

                logLine("frame " + _frameCount
                      + " mixerTime=" + fmt(_mixer.time)
                      + " carouselY=" + fmt(_carousel.position.y)
                      + " morph=" + fmt(_morphSphere.morphTargetInfluences[0])
                      + " tip=(" + fmt(pos[tipIndex]) + "," + fmt(pos[tipIndex + 1]) + "," + fmt(pos[tipIndex + 2]) + ")"
                      + " skinChecksum=" + fmt(checksum(pos))
                      // Radius of one fixed mid-latitude vertex: 0.72 at
                      // influence 0, ~1.36 at influence 1. (A weighted sum over
                      // the whole array is nearly invariant here because the
                      // lobe deltas cancel by symmetry -- use the radius.)
                      + " morphRadius=" + fmt(sqrt3(morphPos, (14 * 41 + 20) * 3))
                      + " infl=" + fmt(_morphSphere.morphTargetInfluences[0])

                      + " bindChecksum=" + fmt(_bindChecksum)
                      + " drawCalls=" + _renderer.drawCalls
                      + " triangles=" + _renderer.triangles
                      + " culled=" + _renderer.culledObjects);
            }
        }

        // ------------------------------------------------------------------

        private function sqrt3(values:Vector.<Number>, offset:int):Number
        {
            var x:Number = values[offset];
            var y:Number = values[offset + 1];
            var z:Number = values[offset + 2];
            return Math.sqrt(x * x + y * y + z * z);
        }

        private function checksum(values:Vector.<Number>):Number
        {
            var sum:Number = 0;
            for (var i:int = 0; i < values.length; i++)
            {
                sum += values[i] * (1.0 + (i % 7) * 0.25);
            }
            return sum;
        }

        private function standard(hex:uint, roughness:Number, metalness:Number):MeshStandardMaterial
        {
            var m:MeshStandardMaterial = new MeshStandardMaterial();
            m.color.setHex(hex);
            m.roughness = roughness;
            m.metalness = metalness;
            return m;
        }

        private function vec(values:Array):Vector.<Number>
        {
            var out:Vector.<Number> = new Vector.<Number>();
            for (var i:int = 0; i < values.length; i++) out.push(Number(values[i]));
            return out;
        }

        private function fmt(v:Number):String
        {
            var scaled:Number = Math.round(v * 10000) / 10000;
            return String(scaled);
        }
    }
}