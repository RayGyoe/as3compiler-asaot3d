// ShadowM7.as -- M7 directional shadow demo: a cube casts a shadow onto a ground
// plane through AGALRenderer's shadow-map prepass + PCF sampling.
//
// The directional light (castShadow = true) drives the prepass: the scene is
// rendered depth-first into the light's orthographic shadow map, then the base
// pass samples that map to gate the direct light where the cube occludes it.
// The result is a readable dark region on the ground aligned with the light
// direction.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.BoxGeometry;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class ShadowM7 extends Stage3DApp
    {
        private var _cube:Mesh;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 5, 11);
            _camera.lookAt(0, 1.5, 0);

            // The shadow-casting cube, hovering above the ground.
            var cubeMat:MeshStandardMaterial = new MeshStandardMaterial();
            cubeMat.color.setHex(0xdd8844);
            cubeMat.roughness = 0.6;
            cubeMat.metalness = 0.0;
            _cube = new Mesh(new BoxGeometry(2, 2, 2), cubeMat);
            _cube.position.set(0, 2.5, 0);
            _cube.castShadow = true;
            _scene.add(_cube);

            // Ground plane catches the shadow.
            var groundMat:MeshStandardMaterial = new MeshStandardMaterial();
            groundMat.color.setHex(0x9a9aa4);
            groundMat.roughness = 0.95;
            groundMat.metalness = 0.0;
            var ground:Mesh = new Mesh(new PlaneGeometry(20, 20), groundMat);
            ground.rotation.x = -1.5707963267948966; // -PI/2, lay flat
            ground.position.y = 0;
            ground.receiveShadow = true;
            _scene.add(ground);

            // Dim ambient so the shadowed region stays readable.
            var ambient:AmbientLight = new AmbientLight(0x666677, 0.35);
            _scene.add(ambient);

            // Directional key light with an active shadow: the light direction
            // (position -> target) tilts the shadow away from the cube.
            var key:DirectionalLight = new DirectionalLight(0xffffff, 1.0);
            key.position.set(6, 9, 4);
            key.castShadow = true;
            // NEGATIVE bias. fc9.x is ADDED to the fragment's shadow-space depth
            // before the `sample >= depth` compare, so a positive value makes a
            // surface MORE likely to be judged occluded -- i.e. it is acne, not a
            // cure. three.js's own recipe is `shadow.bias = -0.0005`; the sign
            // convention is the same here.
            //
            // How much is needed is set by the depth encoding, not by taste: the
            // shadow map stores [0,1] depth in an 8-bit colour channel (R11), and
            // this scene's shadow camera spans near=0.5..far=30, so one depth step
            // is 29.5/255 = 0.116 world units. A bias smaller than one step cannot
            // separate the ground from itself and the surface self-shadows in
            // stripes. -0.003 normalized = 0.088 units... rounded up over one step
            // is what makes the plane clean; -0.004 is the safer round number and
            // still keeps the cube's contact shadow attached.
            key.shadow.bias = -0.004;
            // Tighten the shadow camera's near/far to the scene so the depth
            // encoding (8-bit color, M7 R11-style) keeps enough precision to
            // separate the cube from the ground (the 0.5..500 default compresses
            // both to ~1 gray level).
            key.shadow.camera.near = 0.5;
            key.shadow.camera.far = 30;
            key.shadow.camera.updateProjectionMatrix();
            _scene.add(key);
            _scene.add(key.target);
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            // Rotate the cube so the moving silhouette is visible against the
            // static shadow.
            _cube.rotation.y += 0.01;
        }
    }
}
