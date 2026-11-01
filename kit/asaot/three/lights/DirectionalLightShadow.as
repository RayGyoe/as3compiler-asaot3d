// asaot.three.lights.DirectionalLightShadow -- directional light shadow config.
//
// Borrows src/lights/DirectionalLightShadow.js + LightShadow.js (r187): an
// orthographic shadow camera framing the light frustum, a mapSize, a depth
// bias, the shadow matrix (world -> shadow clip), and a `map` slot the renderer
// fills with the shadow depth texture. The broad LightShadow base's runtime
// knobs (biasNode/radius/blurSamples/mapType/mapPass) are not carried:
// this backend implements a single-cascade directional shadow with a fixed
// NxN PCF kernel (M13), not the full node-based shadow pipeline.
package asaot.three.lights
{
    import asaot.three.cameras.OrthographicCamera;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Vector2;
    import asaot.three.textures.Texture;

    public class DirectionalLightShadow
    {
        public var camera:OrthographicCamera;
        public var mapSize:Vector2;
        // LightShadow.bias: constant depth offset added to the receiver's
        // shadow-space depth before the compare (LightShadow.js:37).
        public var bias:Number;
        // LightShadow.radius (M13): the PCF kernel radius in shadow-map texels
        // (LightShadow.js:44, consumed by PCFSoftShadowMap). r187 scales the
        // 3x3 tap offsets by it; 1 = one texel, 0 = a single hard tap.
        public var radius:Number;
        // LightShadow.normalBias (M13): offsets the RECEIVER's world position
        // along its own normal before projecting into shadow space, which is
        // what removes acne on curved/low-poly surfaces without the constant
        // depth offset that bias applies (shadowmap_vertex.glsl.js:51).
        public var normalBias:Number;
        public var map:Texture;
        public var matrix:Matrix4;

        public function DirectionalLightShadow()
        {
            // OrthographicCamera(-5,5,5,-5,0.5,500): DirectionalLightShadow.js
            // constructor defaults.
            this.camera = new OrthographicCamera(-5, 5, 5, -5, 0.5, 500);
            this.mapSize = new Vector2(512, 512);
            this.bias = 0;
            this.radius = 1;
            this.normalBias = 0;
            this.map = null;
            this.matrix = new Matrix4();
        }
    }
}