// LightM6.as -- M6 punctual-light demo: one point light + one spot light over a
// ground plane and a glossy sphere, rendered through AGALRenderer's additive
// punctual passes on top of the base (ambient + directional) pass.
//
// The point light (red, left) proves the Frostbite distance attenuation + the
// additive point pass. The spot light (white, above) proves the cone
// attenuation (angle + penumbra smoothstep). A very dim ambient keeps the
// shadowed side from being pure black.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.geometries.PlaneGeometry;
    import asaot.three.geometries.SphereGeometry;
    import asaot.three.lights.AmbientLight;
    import asaot.three.lights.DirectionalLight;
    import asaot.three.lights.PointLight;
    import asaot.three.lights.SpotLight;
    import asaot.three.materials.MeshStandardMaterial;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class LightM6 extends Stage3DApp
    {
        private var _sphere:Mesh;

        override protected function createScene():void
        {
            _scene = new Scene();
            _camera = new PerspectiveCamera(60, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 2.5, 9);
            _camera.lookAt(0, 0.5, 0);

            // Glossy sphere: moderate roughness shows a visible specular lobe
            // without over-exposing the whole surface (the M6 acceptance needs
            // the point/spot contributions readable, not clipped to white).
            var sphereMat:MeshStandardMaterial = new MeshStandardMaterial();
            sphereMat.color.setHex(0xcccccc);
            sphereMat.roughness = 0.55;
            sphereMat.metalness = 0.0;
            _sphere = new Mesh(new SphereGeometry(1.5, 48, 32), sphereMat);
            _sphere.position.set(0, 1.5, 0);
            _scene.add(_sphere);

            // Ground plane catches the distance falloff of both punctual lights.
            var groundMat:MeshStandardMaterial = new MeshStandardMaterial();
            groundMat.color.setHex(0x3a3a44);
            groundMat.roughness = 0.9;
            groundMat.metalness = 0.0;
            var ground:Mesh = new Mesh(new PlaneGeometry(20, 20), groundMat);
            ground.rotation.x = -1.5707963267948966; // -PI/2, lay flat
            ground.position.y = 0;
            _scene.add(ground);

            // Dim ambient so the unlit side is readable, not pitch black.
            var ambient:AmbientLight = new AmbientLight(0x666677, 0.10);
            _scene.add(ambient);

            // Directional key light gives the base pass a readable form so the
            // punctual passes are judged against a lit reference.
            var key:DirectionalLight = new DirectionalLight(0xffffff, 0.55);
            key.position.set(3, 5, 4);
            _scene.add(key);

            // Point light: red, up-left, finite range with physically-correct
            // inverse-square decay. distance=8 + decay=2 => a soft cutoff window.
            var point:PointLight = new PointLight(0xff4d33, 1.6, 8, 2);
            point.position.set(-4, 2.5, 2);
            _scene.add(point);

            // Spot light: white, high above, aimed at the sphere with a soft
            // penumbra edge (angle 30deg, penumbra 0.6).
            var spot:SpotLight = new SpotLight(0xffffff, 1.8, 0, 0.5235987755982988, 0.6, 2);
            spot.position.set(0, 6, 3);
            spot.target.position.set(0, 0.5, 0);
            _scene.add(spot);
            _scene.add(spot.target);
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            // Rotate the sphere to show the moving specular lobe.
            _sphere.rotation.y += 0.01;
        }
    }
}
