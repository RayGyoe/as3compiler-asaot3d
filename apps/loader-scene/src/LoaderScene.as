// LoaderScene.as -- M3 first-frame demo: a Stage3D context renders a scene that
// was deserialized from a JSON scene graph (three.js Object/Scene format 4) by
// ObjectLoader -- NOT constructed programmatically. Proves the asset layer: JSON
// text -> BufferGeometry (position/normal/uv + index) + MeshStandardMaterial +
// Scene/Group/Mesh/light tree -> AGALRenderer.
//
// The JSON describes one rotating cube (standard material, blue GGX-lit) lit by
// one directional + one ambient light, nested one level deep (Scene -> Group ->
// Mesh) to prove recursive object-tree rebuilding.
package
{
    import asaot.three.app.Stage3DApp;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.loaders.ObjectLoader;
    import asaot.three.objects.Mesh;
    import asaot.three.scenes.Scene;

    public class LoaderScene extends Stage3DApp
    {
        private var _cube:Mesh;

        override protected function createScene():void
        {
            logLine("M3: context created");
            logLine("M3: renderer ready");

            _camera = new PerspectiveCamera(75, stage.stageWidth / stage.stageHeight, 0.1, 100);
            _camera.position.set(0, 0, 6);

            // Deserialize the whole scene from JSON (a 2x2x2 unit cube, per-face
            // normals, CCW winding, blue GGX standard material, one group deep).
            logLine("M3: parsing JSON");
            var parsed:Object = JSON.parse(LoaderScene.CUBE_JSON);
            logLine("M3: JSON parsed");
            var loader:ObjectLoader = new ObjectLoader();
            _scene = Scene(loader.parse(parsed));
            logLine("M3: scene deserialized, children=" + _scene.children.length);

            // The JSON object tree put the mesh under a Group; reach in to animate it.
            _cube = Mesh(_scene.children[0].children[0]);
            logLine("M3: cube reached");
        }

        override protected function updateFrame(elapsedMs:Number):void
        {
            _cube.rotation.x += 0.01;
            _cube.rotation.y += 0.02;
        }

        // A three.js Object/Scene format 4 envelope for one 2x2x2 cube.
        // position/normal/uv/index are the exact 24-vertex, per-face-normal layout
        // three.js BoxGeometry produces (see BoxGeometry.as buildPlane order).
        private static const CUBE_JSON:String =
            '{"metadata":{"version":4.5,"type":"Object","generator":"asaot3d"},' +
            '"geometries":[{"uuid":"geo-cube","type":"BufferGeometry","data":{"attributes":{' +
            '"position":{"itemSize":3,"type":"Float32Array","array":[' +
            '1,1,1,1,1,-1,1,-1,1,1,-1,-1,-1,1,-1,-1,1,1,-1,-1,-1,-1,-1,1,' +
            '-1,1,-1,1,1,-1,-1,1,1,1,1,1,-1,-1,1,1,-1,1,-1,-1,-1,1,-1,-1,' +
            '-1,1,1,1,1,1,-1,-1,1,1,-1,1,1,1,-1,-1,1,-1,1,-1,-1,-1,-1,-1]},' +
            '"normal":{"itemSize":3,"type":"Float32Array","array":[' +
            '1,0,0,1,0,0,1,0,0,1,0,0,-1,0,0,-1,0,0,-1,0,0,-1,0,0,' +
            '0,1,0,0,1,0,0,1,0,0,1,0,0,-1,0,0,-1,0,0,-1,0,0,-1,0,' +
            '0,0,1,0,0,1,0,0,1,0,0,1,0,0,-1,0,0,-1,0,0,-1,0,0,-1]},' +
            '"uv":{"itemSize":2,"type":"Float32Array","array":[' +
            '0,1,1,1,0,0,1,0,0,1,1,1,0,0,1,0,0,1,1,1,0,0,1,0,' +
            '0,1,1,1,0,0,1,0,0,1,1,1,0,0,1,0,0,1,1,1,0,0,1,0]}},' +
            '"index":{"itemSize":1,"type":"Uint16Array","array":[' +
            '0,2,1,2,3,1,4,6,5,6,7,5,8,10,9,10,11,9,' +
            '12,14,13,14,15,13,16,18,17,18,19,17,20,22,21,22,23,21]}}}],' +
            '"materials":[{"uuid":"mat-blue","type":"MeshStandardMaterial","name":"blue",' +
            '"color":3366527,"roughness":0.3,"metalness":0.1,"emissive":0,"emissiveIntensity":1}],' +
            '"object":{"uuid":"root","type":"Scene","name":"Scene","children":[' +
            '{"uuid":"grp","type":"Group","name":"holder","children":[' +
            '{"uuid":"mesh","type":"Mesh","name":"cube","geometry":"geo-cube","material":"mat-blue"}' +
            ']},' +
            '{"uuid":"sun","type":"DirectionalLight","color":16777215,"intensity":1.0,"position":[0,1,3]},' +
            '{"uuid":"amb","type":"AmbientLight","color":16777215,"intensity":0.15}' +
            ']}}';
    }
}
