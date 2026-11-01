// asaot.three.controls.OrbitControls -- orbit / dolly / pan camera control.
//
// Semantics borrowed from three.js r187 `examples/jsm/controls/OrbitControls.js`.
// That file is NOT part of the vendored `three-src/` tree (the repository ships
// `src/` only, no `examples/jsm/`), so this port is pinned by behaviour rather
// than by line numbers: every formula below carries the r187 expression it comes
// from, and `probes/interaction-smoke-m14` asserts the numeric outcomes. Recorded
// as D99 in three-api-design.md §19.
//
// WHAT IS PORTED (the whole interaction model, not a subset of the maths):
//   * state machine ROTATE / DOLLY / PAN with three.js's exact deltas --
//     `rotateLeft(2PI * dx / clientHeight)`, `_getZoomScale = 0.95^(speed*|dY|*0.01)`,
//     `_panLeft(2 * dx * targetDistance / clientHeight)` with the perspective
//     target distance `|pos - target| * tan(fov/2)`;
//   * spherical storage (theta/phi/radius) so a drag cannot drift the distance;
//   * min/max polar + azimuth angles, min/max distance, min/max zoom;
//   * damping (`_sphericalDelta *= 1 - dampingFactor` per update) and autoRotate;
//   * saveState/reset, and the public programmatic API (rotateLeft/rotateUp/pan/
//     dollyIn/dollyOut) that r187 exposes -- which is also what makes the maths
//     testable without a window.
//
// WHAT IS NOT PORTED (registered, never silently dropped):
//   * touch (ONE/TWO finger) -- AIR delivers TouchEvent only on touch-capable
//     platforms and this backend has no touch source;
//   * keyboard panning (`listenToKeyEvents`) -- the AGAL demos have no key focus
//     model;
//   * `zoomToCursor` -- it depends on `unproject` at pointer NDC plus a
//     dollyDirection, and with ONE pointer path (no pointer capture) it would
//     behave differently from r187 in a way that is hard to verify here;
//   * pointer capture: r187 moves the move/up listeners to `ownerDocument` on
//     pointerdown. AIR has no such document -- the Stage keeps receiving moves
//     while a button is held, which is the same thing for a full-window view.
//
// STAGE3D EVENT BRIDGE (M14): the constructor takes an InteractiveObject (the
// Stage) instead of a DOM element. AIR reports pointer positions in STAGE pixels
// (top-left origin, y down) through `MouseEvent.stageX/stageY`; only DIFFERENCES
// are used for rotation/pan, so the fact that three.js uses clientX/clientY does
// not matter. Buttons: AIR's MouseEvent has no `button` field -- the right button
// arrives as `rightMouseDown`/`rightMouseUp` -- so LEFT and RIGHT are wired to
// `mouseButtons.left` / `mouseButtons.right` and the middle button is unreachable
// (D99). The wheel arrives as MouseEvent.MOUSE_WHEEL with `delta` positive when
// scrolling UP (window glue comment: "e.wheel.y is positive when scrolling up,
// matching MouseEvent.delta"), i.e. the opposite sign of the DOM's `deltaY` --
// so `_handleWheel` negates it before applying three.js's "deltaY < 0 = dolly in".
package asaot.three.controls
{
    import asaot.three.cameras.Camera;
    import asaot.three.cameras.OrthographicCamera;
    import asaot.three.cameras.PerspectiveCamera;
    import asaot.three.math.Matrix4;
    import asaot.three.math.Quaternion;
    import asaot.three.math.Spherical;
    import asaot.three.math.Vector2;
    import asaot.three.math.Vector3;

    import flash.display.InteractiveObject;
    import flash.events.MouseEvent;

    public class OrbitControls
    {
        // ---- mouse action constants (r187 MOUSE.ROTATE/DOLLY/PAN) ----
        public static const ROTATE:int = 0;
        public static const DOLLY:int = 1;
        public static const PAN:int = 2;
        public static const NONE:int = -1;

        private static const _TWO_PI:Number = 2 * Math.PI;

        // ---- configuration (r187 defaults) ----
        public var object:Camera;
        public var target:Vector3;
        public var enabled:Boolean = true;

        public var minDistance:Number = 0;
        public var maxDistance:Number = Infinity;
        public var minZoom:Number = 0;
        public var maxZoom:Number = Infinity;

        public var minPolarAngle:Number = 0;
        public var maxPolarAngle:Number = Math.PI;
        public var minAzimuthAngle:Number = -Infinity;
        public var maxAzimuthAngle:Number = Infinity;

        public var enableDamping:Boolean = false;
        public var dampingFactor:Number = 0.05;

        public var enableZoom:Boolean = true;
        public var zoomSpeed:Number = 1.0;
        public var enableRotate:Boolean = true;
        public var rotateSpeed:Number = 1.0;
        public var enablePan:Boolean = true;
        public var panSpeed:Number = 1.0;
        public var screenSpacePanning:Boolean = true;
        public var autoRotate:Boolean = false;
        public var autoRotateSpeed:Number = 2.0;

        public var mouseButtons:MouseButtons = new MouseButtons();

        // ---- runtime state ----
        public var state:int = NONE;

        private var _view:InteractiveObject;
        private var _viewWidth:Number = 0;
        private var _viewHeight:Number = 0;

        private var _rotateStart:Vector2 = new Vector2();
        private var _rotateEnd:Vector2 = new Vector2();
        private var _rotateDelta:Vector2 = new Vector2();
        private var _panStart:Vector2 = new Vector2();
        private var _panEnd:Vector2 = new Vector2();
        private var _panDelta:Vector2 = new Vector2();

        private var _spherical:Spherical = new Spherical();
        private var _sphericalDelta:Spherical = new Spherical();

        private var _scale:Number = 1;
        private var _panOffset:Vector3 = new Vector3();

        private var _quat:Quaternion;
        private var _quatInverse:Quaternion;

        private var _lastPosition:Vector3 = new Vector3();
        private var _lastQuaternion:Quaternion = new Quaternion();
        private var _lastTargetPosition:Vector3 = new Vector3();

        private var _position0:Vector3;
        private var _target0:Vector3;
        private var _zoom0:Number;

        private static var _v:Vector3 = new Vector3();

        // Bound closures, kept so disconnect() can remove exactly what connect()
        // added (a fresh `this.onMouseDown` reference is not guaranteed to compare
        // equal in the AOT runtime, so the identity is held here instead).
        private var _onMouseDownFn:Function = null;
        private var _onRightMouseDownFn:Function = null;
        private var _onMouseMoveFn:Function = null;
        private var _onMouseUpFn:Function = null;
        private var _onWheelFn:Function = null;

        public function OrbitControls(object:Camera, view:InteractiveObject = null)
        {
            this.object = object;
            this.target = new Vector3();

            this._position0 = object.position.clone();
            this._target0 = this.target.clone();
            this._zoom0 = object.zoom;

            // Orbit around the camera's up axis: rotate the offset into a space
            // where +Y is the orbit axis, do the spherical maths there, and rotate
            // back. Without this a camera with up = +Z would orbit around a tilted
            // axis (r187 constructor: `_quat = setFromUnitVectors(object.up, (0,1,0))`).
            this._quat = new Quaternion().setFromUnitVectors(object.up, new Vector3(0, 1, 0));
            this._quatInverse = this._quat.clone().invert();

            this._view = view;
            if (view != null) this.connect(view);

            this.update();
        }

        // ---- wiring -------------------------------------------------------

        public function connect(view:InteractiveObject):void
        {
            this.disconnect();
            this._view = view;

            var self:OrbitControls = this;
            this._onMouseDownFn = function(e:MouseEvent):void { self._handleMouseDown(e, false); };
            this._onRightMouseDownFn = function(e:MouseEvent):void { self._handleMouseDown(e, true); };
            this._onMouseMoveFn = function(e:MouseEvent):void { self._handleMouseMove(e); };
            this._onMouseUpFn = function(e:MouseEvent):void { self._handleMouseUp(e); };
            this._onWheelFn = function(e:MouseEvent):void { self._handleWheel(e); };

            view.addEventListener(MouseEvent.MOUSE_DOWN, this._onMouseDownFn);
            view.addEventListener(MouseEvent.RIGHT_MOUSE_DOWN, this._onRightMouseDownFn);
            view.addEventListener(MouseEvent.MOUSE_MOVE, this._onMouseMoveFn);
            view.addEventListener(MouseEvent.MOUSE_UP, this._onMouseUpFn);
            view.addEventListener(MouseEvent.RIGHT_MOUSE_UP, this._onMouseUpFn);
            view.addEventListener(MouseEvent.MOUSE_WHEEL, this._onWheelFn);
        }

        public function disconnect():void
        {
            this.state = NONE;
            if (this._view == null) return;

            if (this._onMouseDownFn != null) this._view.removeEventListener(MouseEvent.MOUSE_DOWN, this._onMouseDownFn);
            if (this._onRightMouseDownFn != null) this._view.removeEventListener(MouseEvent.RIGHT_MOUSE_DOWN, this._onRightMouseDownFn);
            if (this._onMouseMoveFn != null) this._view.removeEventListener(MouseEvent.MOUSE_MOVE, this._onMouseMoveFn);
            if (this._onMouseUpFn != null)
            {
                this._view.removeEventListener(MouseEvent.MOUSE_UP, this._onMouseUpFn);
                this._view.removeEventListener(MouseEvent.RIGHT_MOUSE_UP, this._onMouseUpFn);
            }
            if (this._onWheelFn != null) this._view.removeEventListener(MouseEvent.MOUSE_WHEEL, this._onWheelFn);
        }

        public function dispose():void
        {
            this.disconnect();
        }

        // The viewport size in pixels. three.js reads `domElement.clientHeight`
        // (rotation and pan are normalised by HEIGHT, and only height -- dividing
        // by width would make the feels differ with the aspect ratio). A Stage3D
        // app has no DOM, so the size is either given explicitly (setSize, e.g.
        // from a RESIZE handler) or read live from the Stage.
        public function setSize(width:Number, height:Number):void
        {
            this._viewWidth = width;
            this._viewHeight = height;
        }

        private function _height():Number
        {
            if (this._viewHeight > 0) return this._viewHeight;
            if (this._view != null && this._view.stage != null) return this._view.stage.stageHeight;
            return 1;
        }

        private function _width():Number
        {
            if (this._viewWidth > 0) return this._viewWidth;
            if (this._view != null && this._view.stage != null) return this._view.stage.stageWidth;
            return 1;
        }

        // ---- queries ------------------------------------------------------

        public function getPolarAngle():Number
        {
            return this._spherical.phi;
        }

        public function getAzimuthalAngle():Number
        {
            return this._spherical.theta;
        }

        public function getDistance():Number
        {
            return this.object.position.distanceTo(this.target);
        }

        public function saveState():void
        {
            this._target0.copy(this.target);
            this._position0.copy(this.object.position);
            this._zoom0 = this.object.zoom;
        }

        public function reset():void
        {
            this.target.copy(this._target0);
            this.object.position.copy(this._position0);
            this.object.zoom = this._zoom0;
            this.object.updateMatrixWorld(true);
            this.object.updateProjectionMatrix();
            this.update();
            this.state = NONE;
        }

        // ---- programmatic API (r187) --------------------------------------

        public function rotateLeft(angle:Number):void
        {
            this._rotateLeft(angle);
            this.update();
        }

        public function rotateUp(angle:Number):void
        {
            this._rotateUp(angle);
            this.update();
        }

        public function pan(deltaX:Number, deltaY:Number):void
        {
            this._pan(deltaX, deltaY);
            this.update();
        }

        public function dollyIn(dollyScale:Number):void
        {
            this._dollyIn(dollyScale);
            this.update();
        }

        public function dollyOut(dollyScale:Number):void
        {
            this._dollyOut(dollyScale);
            this.update();
        }

        // ---- the update loop ----------------------------------------------

        public function update(deltaTime:Number = -1):Boolean
        {
            var position:Vector3 = this.object.position;

            OrbitControls._v.copy(position).sub(this.target);
            OrbitControls._v.applyQuaternion(this._quat);

            this._spherical.setFromVector3(OrbitControls._v);

            if (this.autoRotate && this.state == NONE) this._rotateLeft(this._autoRotationAngle(deltaTime));

            if (this.enableDamping)
            {
                this._spherical.theta += this._sphericalDelta.theta * this.dampingFactor;
                this._spherical.phi += this._sphericalDelta.phi * this.dampingFactor;
            }
            else
            {
                this._spherical.theta += this._sphericalDelta.theta;
                this._spherical.phi += this._sphericalDelta.phi;
            }

            // azimuth limits: three.js folds both bounds into [-PI, PI] first, so a
            // range like [350deg, 10deg] (which wraps) is handled by the "min > max"
            // branch instead of clamping everything to the empty interval.
            var minA:Number = this.minAzimuthAngle;
            var maxA:Number = this.maxAzimuthAngle;
            if (this._isFinite(minA) && this._isFinite(maxA))
            {
                if (minA < -Math.PI) minA += _TWO_PI;
                else if (minA > Math.PI) minA -= _TWO_PI;
                if (maxA < -Math.PI) maxA += _TWO_PI;
                else if (maxA > Math.PI) maxA -= _TWO_PI;

                if (minA <= maxA)
                {
                    this._spherical.theta = Math.max(minA, Math.min(maxA, this._spherical.theta));
                }
                else
                {
                    this._spherical.theta = (this._spherical.theta > (minA + maxA) / 2) ?
                        Math.max(minA, this._spherical.theta) : Math.min(maxA, this._spherical.theta);
                }
            }

            this._spherical.phi = Math.max(this.minPolarAngle, Math.min(this.maxPolarAngle, this._spherical.phi));
            this._spherical.makeSafe();

            if (this.enableDamping) this.target.addScaledVector(this._panOffset, this.dampingFactor);
            else this.target.add(this._panOffset);

            var zoomChanged:Boolean = false;

            if (this.object.isOrthographicCamera)
            {
                this._spherical.radius = this._clampDistance(this._spherical.radius);
            }
            else
            {
                var prevRadius:Number = this._spherical.radius;
                this._spherical.radius = this._clampDistance(this._spherical.radius * this._scale);
                zoomChanged = prevRadius != this._spherical.radius;
            }

            OrbitControls._v.setFromSpherical(this._spherical);
            OrbitControls._v.applyQuaternion(this._quatInverse);
            position.copy(this.target).add(OrbitControls._v);

            this.object.lookAt(this.target.x, this.target.y, this.target.z);

            if (this.enableDamping)
            {
                this._sphericalDelta.theta *= (1 - this.dampingFactor);
                this._sphericalDelta.phi *= (1 - this.dampingFactor);
                this._panOffset.multiplyScalar(1 - this.dampingFactor);
            }
            else
            {
                this._sphericalDelta.set(0, 0, 0);
                this._panOffset.set(0, 0, 0);
            }

            if (this.object.isOrthographicCamera)
            {
                var prevZoom:Number = this.object.zoom;
                this.object.zoom = Math.max(this.minZoom, Math.min(this.maxZoom, this.object.zoom / this._scale));
                if (prevZoom != this.object.zoom)
                {
                    this.object.updateProjectionMatrix();
                    zoomChanged = true;
                }
            }

            this._scale = 1;

            // Refresh the local matrix so the NEXT pan reads a current basis. The
            // renderer refreshes matrixWorld every frame anyway; this only makes the
            // control self-consistent between two events of the same frame.
            this.object.updateMatrix();

            // r187 change detection: squared camera displacement > EPS, or a
            // rotation whose quaternion difference exceeds EPS using the
            // small-angle form 8 * (1 - dot) ~= angle^2.
            var EPS:Number = 0.000001;
            if (zoomChanged ||
                this._lastPosition.distanceToSquared(this.object.position) > EPS ||
                8 * (1 - this._lastQuaternion.dot(this.object.quaternion)) > EPS ||
                this._lastTargetPosition.distanceToSquared(this.target) > EPS)
            {
                this._lastPosition.copy(this.object.position);
                this._lastQuaternion.copy(this.object.quaternion);
                this._lastTargetPosition.copy(this.target);
                return true;
            }
            return false;
        }

        // ---- internals ----------------------------------------------------

        private function _autoRotationAngle(deltaTime:Number):Number
        {
            if (deltaTime >= 0) return (_TWO_PI / 60 * this.autoRotateSpeed) * deltaTime;
            return _TWO_PI / 60 / 60 * this.autoRotateSpeed;
        }

        // DOM wheel deltaY -> scale factor. `Math.abs` makes the exponent symmetric:
        // three.js only calls this with the sign already resolved by the caller.
        private function _getZoomScale(delta:Number):Number
        {
            var normalizedDelta:Number = Math.abs(delta * 0.01);
            return Math.pow(0.95, this.zoomSpeed * normalizedDelta);
        }

        private function _rotateLeft(angle:Number):void
        {
            this._sphericalDelta.theta -= angle;
        }

        private function _rotateUp(angle:Number):void
        {
            this._sphericalDelta.phi -= angle;
        }

        // r187 `_panLeft`: move the target along the camera's -X axis. The camera's
        // matrix columns ARE its world basis, so panning in screen space is just
        // "column 0 / column 1 of the camera matrix".
        private function _panLeft(distance:Number, objectMatrix:Matrix4):void
        {
            OrbitControls._v.setFromMatrixColumn(objectMatrix, 0);
            OrbitControls._v.multiplyScalar(-distance);
            this._panOffset.add(OrbitControls._v);
        }

        // r187 `_panUp`. `screenSpacePanning` moves along the camera's own +Y
        // column, which tilts with the camera; otherwise the move is constrained to
        // the horizontal plane (up x X column), which keeps the horizon level while
        // panning -- the usual choice for a ground-plane scene.
        private function _panUp(distance:Number, objectMatrix:Matrix4):void
        {
            if (this.screenSpacePanning)
            {
                OrbitControls._v.setFromMatrixColumn(objectMatrix, 1);
            }
            else
            {
                OrbitControls._v.setFromMatrixColumn(objectMatrix, 0);
                OrbitControls._v.crossVectors(this.object.up, OrbitControls._v);
            }
            OrbitControls._v.multiplyScalar(distance);
            this._panOffset.add(OrbitControls._v);
        }

        // deltaX/deltaY in pixels, right and down positive (r187 `_pan`).
        private function _pan(deltaX:Number, deltaY:Number):void
        {
            if (this.object.isPerspectiveCamera)
            {
                var camera:PerspectiveCamera = this.object as PerspectiveCamera;
                OrbitControls._v.copy(this.object.position).sub(this.target);
                var targetDistance:Number = OrbitControls._v.length();
                // Half the vertical fov is the centre-to-top of the screen, so this
                // is the world size of one screen height at the target distance.
                targetDistance *= Math.tan((camera.fov / 2) * Math.PI / 180.0);

                this._panLeft(2 * deltaX * targetDistance / this._height(), this.object.matrix);
                this._panUp(2 * deltaY * targetDistance / this._height(), this.object.matrix);
            }
            else if (this.object.isOrthographicCamera)
            {
                var ortho:OrthographicCamera = this.object as OrthographicCamera;
                this._panLeft(deltaX * (ortho.right - ortho.left) / ortho.zoom / this._width(), this.object.matrix);
                this._panUp(deltaY * (ortho.top - ortho.bottom) / ortho.zoom / this._height(), this.object.matrix);
            }
        }

        private function _dollyOut(dollyScale:Number):void
        {
            this._scale /= dollyScale;
        }

        private function _dollyIn(dollyScale:Number):void
        {
            this._scale *= dollyScale;
        }

        private function _clampDistance(dist:Number):Number
        {
            return Math.max(this.minDistance, Math.min(this.maxDistance, dist));
        }

        // `isFinite` without the global: three.js uses isFinite() here to mean
        // "the user set a bound at all", and +/-Infinity is the default. NaN is
        // NOT a bound either -- and every comparison against NaN is false, which
        // would silently disable clamping.
        private function _isFinite(v:Number):Boolean
        {
            if (v != v) return false;
            if (v == Infinity || v == -Infinity) return false;
            return true;
        }

        // ---- event handlers -----------------------------------------------

        private function _handleMouseDown(e:MouseEvent, right:Boolean):void
        {
            if (!this.enabled) return;

            var action:int = right ? this.mouseButtons.right : this.mouseButtons.left;

            // three.js: ctrl/meta/shift on the LEFT button swaps in PAN, and on the
            // RIGHT button swaps in ROTATE. AIR's MouseEvent carries ctrlKey/
            // altKey/shiftKey (there is no metaKey on this class).
            var modifier:Boolean = e.ctrlKey || e.altKey || e.shiftKey;

            if (action == DOLLY)
            {
                if (!this.enableZoom) return;
                this.state = DOLLY;
            }
            else if (action == ROTATE)
            {
                if (modifier)
                {
                    if (!this.enablePan) return;
                    this._panStart.set(e.stageX, e.stageY);
                    this.state = PAN;
                }
                else
                {
                    if (!this.enableRotate) return;
                    this._rotateStart.set(e.stageX, e.stageY);
                    this.state = ROTATE;
                }
            }
            else if (action == PAN)
            {
                if (modifier)
                {
                    if (!this.enableRotate) return;
                    this._rotateStart.set(e.stageX, e.stageY);
                    this.state = ROTATE;
                }
                else
                {
                    if (!this.enablePan) return;
                    this._panStart.set(e.stageX, e.stageY);
                    this.state = PAN;
                }
            }
            else
            {
                this.state = NONE;
            }
        }

        private function _handleMouseMove(e:MouseEvent):void
        {
            if (!this.enabled) return;

            if (this.state == ROTATE)
            {
                if (!this.enableRotate) return;
                this._rotateEnd.set(e.stageX, e.stageY);
                this._rotateDelta.subVectors(this._rotateEnd, this._rotateStart).multiplyScalar(this.rotateSpeed);
                // NOTE: height, not width -- r187 normalises both axes by the
                // element's clientHeight so a horizontal drag feels the same as a
                // vertical one at any aspect ratio.
                this._rotateLeft(_TWO_PI * this._rotateDelta.x / this._height());
                this._rotateUp(_TWO_PI * this._rotateDelta.y / this._height());
                this._rotateStart.copy(this._rotateEnd);
                this.update();
            }
            else if (this.state == PAN)
            {
                if (!this.enablePan) return;
                this._panEnd.set(e.stageX, e.stageY);
                this._panDelta.subVectors(this._panEnd, this._panStart).multiplyScalar(this.panSpeed);
                this._pan(this._panDelta.x, this._panDelta.y);
                this._panStart.copy(this._panEnd);
                this.update();
            }
            else if (this.state == DOLLY)
            {
                // Middle-button dolly has no event source here (see the header), but
                // the state is kept so a future pointer source can drive it.
                if (!this.enableZoom) return;
            }
        }

        private function _handleMouseUp(e:MouseEvent):void
        {
            this.state = NONE;
        }

        // AIR wheel delta is positive scrolling UP; the DOM's deltaY is negative
        // scrolling up. Negating here is what keeps "wheel up zooms in" true.
        private function _handleWheel(e:MouseEvent):void
        {
            if (!this.enabled || !this.enableZoom || this.state != NONE) return;

            var deltaY:Number = -e.delta;
            if (deltaY < 0) this._dollyIn(this._getZoomScale(deltaY));
            else if (deltaY > 0) this._dollyOut(this._getZoomScale(deltaY));

            this.update();
        }
    }
}