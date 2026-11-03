# asaot3d — three.js 风格 API 设计草案

> 状态：草案（2026-10-30）。本文先定「API 形状 + 关键设计决策」，逐条出处回填到
> `three-borrow-map.md` §1（落地后）。命名空间 `asaot.three.*`，目录见 `README.md`。
> 参照版本：three.js **r187**（`three-src/` 浅克隆，commit `a1ca74b`）。

---

## 0. 三个总原则

1. **只借设计、不借实现**：three.js 是 JS + WebGL2，我们是 AS3 + Stage3D（AGAL→MSL/GLSL），
   落地形态必然不同。凡是「形态不同」处，本文都写清「为什么不照搬」。
2. **AGAL-first 渲染后端**：材质编译成 AGAL，走 as-aot 现有翻译器（`ASC_AGAL_TARGET`），
   源码在 adl/真 AIR 上也能跑（对齐 AIR 底线）。原生 shader 直通（E6）是**已落地的 opt-in 第二通道**
   （§37，M30）：默认构建不变，开了 `--features native-shader` 才多一个后端。
3. **可变数学库 + 就地方法**：three.js 的 `Vector3`/`Matrix4` 是**可变对象**，
   `set()/add()/multiplyScalar()` 就地改值并 `return this` 支持链式。这套风格**恰好契合**
   as-aot 的内存红线——「禁止在每帧/每循环热路径里产生进 arena 的临时分配」。照抄它。

---

## 1. 全局约定（照 three.js，逐条给出处）

| 约定 | three.js 出处 | 值 | 备注 |
|---|---|---|---|
| 坐标系 | `src/core/Object3D.js` `DEFAULT_UP` | **右手系**，`+Y` 朝上 | Stage3D/AGAL 的 NDC 手性在 seam 层投影矩阵里对齐，不污染场景图 |
| 角度单位 | `src/math/MathUtils.js`（`DEG2RAD`/`RAD2DEG`） | **弧度**（API 入参），相机 `fov` 例外是**度** | `PerspectiveCamera.fov` 是垂直视场角的度数 |
| 矩阵存储 | `src/math/Matrix4.js`（`elements`） | **列主序** 16 元素一维数组；`set()` 接受**行主序** 16 参数 | 与 AGAL/OpenGL 同序，翻译器零转换 |
| 颜色 | `src/math/Color.js` | `0xRRGGBB` 整数 + `Color` 类 | — |
| 长度单位 | three.js 约定 | **米**（无强制，仅为惯例） | 不设单位系统 |

> 这五条是「借设计」的骨架：它们是语言无关的约定，AS3 里照抄零语义风险。

---

## 2. 数学库（`kit/asaot/three/math/`）

| AS3 类 | 对应 three.js | 关键面（照抄签名） |
|---|---|---|
| `Vector2` / `Vector3` / `Vector4` | `src/math/Vector3.js` | `x/y/z` 公开字段；`set/copy/add/sub/multiplyScalar/normalize/dot/cross/length/applyMatrix4/clone`；就地改 + `return this` |
| `Matrix3` / `Matrix4` | `src/math/Matrix4.js` | `elements`（`Vector.<Number>` 长度 16，列主序）；`set/identity/copy/multiply/multiplyMatrices/makePerspective/makeOrthographic/lookAt/compose/decompose/fromArray/toArray`；**深度列 [0,1]**（Stage3D/Metal NDC z，偏离 three.js 的 WebGL [-1,1]，见 borrow-map D-depth） |
| `Quaternion` | `src/math/Quaternion.js` | `x/y/z/w`；`setFromEuler/setFromRotationMatrix/multiply/slerp/normalize` |
| `Euler` | `src/math/Euler.js` | `x/y/z`（弧度）+ `order`（默认 `XYZ`）；`set/setFromQuaternion/reorder` |
| `Color` | `src/math/Color.js` | 构造 `0xRRGGBB` / `setHex/setRGB/copy` |
| `MathUtils` | `src/math/MathUtils.js` | `clamp/lerp/degToRad/radToDeg` 等纯函数 |

**强制差异（不照搬）**：

- three.js 的 `Vector3.add(a, b)` 等「双参版本」返回临时新对象（用于链式里的中间量）。
  我们**只提供单参就地版**（`add(v)`），需要「a+b 不改 a」时显式 `tmp.copy(a).add(b)`。
  理由：双参版本每帧制造临时分配，踩 as-aot 红线；语义等价，只是少一个便利重载。
- three.js 用 `Number`（JS double）与 `Float32Array`（GPU 缓冲）两套并存。
  我们**CPU 侧统一 `Number`**（AS3 的 `Number` = double），GPU 侧 `Vector.<Number>` 在
  upload 时由 seam 层一次性转成 AGAL 需要的单精度 —— 不在数学库混两套标量类型。

---

## 3. 场景图（`kit/asaot/three/core/`）

### 3.1 `Object3D`（场景图节点基类）

对齐 `src/core/Object3D.js`，关键面：

```as3
public class Object3D {
  public var name:String = "";
  public var userData:Object;           // 任意 key→value，见 §8 差异
  public var parent:Object3D;           // null 表示根
  public var children:Vector.<Object3D>;

  // 变换四元组（rotation 与 quaternion 双向同步，见 §8 差异）
  public var position:Vector3;
  public var rotation:Euler;
  public var quaternion:Quaternion;
  public var scale:Vector3;
  public var up:Vector3;                // 默认 +Y

  public var matrix:Matrix4;            // 本地
  public var matrixWorld:Matrix4;       // 世界（updateMatrixWorld 惰性更新）
  public var matrixAutoUpdate:Boolean = true;

  public var visible:Boolean = true;
  public var castShadow:Boolean = false;
  public var receiveShadow:Boolean = false;
  public var frustumCulled:Boolean = true;
  public var renderOrder:int = 0;

  public function add(object:Object3D, ...rest):Object3D;   // 见 §8 varargs
  public function remove(object:Object3D, ...rest):Object3D;
  public function clear():Object3D;
  public function traverse(callback:Function):void;
  public function traverseVisible(callback:Function):void;
  public function traverseAncestors(callback:Function):void;
  public function updateMatrix():void;
  public function updateMatrixWorld(force:Boolean = false):void;
  public function lookAt(x:Number, y:Number, z:Number):void;
  public function getWorldPosition(target:Vector3):Vector3;
  public function getWorldQuaternion(target:Quaternion):Quaternion;
  public function localToWorld(v:Vector3):Vector3;
  public function worldToLocal(v:Vector3):Vector3;
  public function clone(recursive:Boolean = true):Object3D;
  public function copy(source:Object3D, recursive:Boolean = true):Object3D;
}
```

**注意 r187 的 `pivot`**（`Object3D.js` 381 行「rotation/scale 的支点」）是较新加入的，
本里程碑**不借**——它依赖「pivot → position」的额外矩阵合成，先不做，留 `matrixAutoUpdate=false`
给作者手写变换矩阵兜底。

### 3.2 子类（对齐 three.js 继承层级）

| AS3 类 | 父类 | three.js 出处 | 本里程碑面 |
|---|---|---|---|
| `Scene` | `Object3D` | `src/scenes/Scene.js` | `background`/`fog`（可选）+ 根节点身份 |
| `Mesh` | `Object3D` | `src/objects/Mesh.js` | `geometry` + `material` 两个强引用 |
| `Group` | `Object3D` | `src/objects/Group.js` | 纯分组节点（无几何/材质） |
| `Camera` | `Object3D` | `src/cameras/Camera.js` | `projectionMatrix`/`projectionMatrixInverse`/`matrixWorldInverse` |
| `Light` | `Object3D` | `src/lights/Light.js` | `color` + `intensity`，子类见 §6 |

> `Scene`/`Mesh`/`Camera`/`Light` 在 three.js 里都 `extends Object3D`；AS3 单继承天然同构。

---

## 4. 几何（`kit/asaot/three/core/`）

### 4.1 `BufferAttribute`

对齐 `src/core/BufferAttribute.js`：`array:Vector.<Number>` + `itemSize:int` + `normalized:Boolean`。
本里程碑**只支持 `Float32` 单精度**（`Float32BufferAttribute`），索引缓冲单独用 `Uint16/Uint32`
（`setIndex` 时按顶点数自动选，对齐 `BufferGeometry.setIndex` 的 `arrayNeedsUint32` 逻辑）。

### 4.2 `BufferGeometry`

对齐 `src/core/BufferGeometry.js`：

```as3
public class BufferGeometry {
  public var attributes:Object;         // name:String → BufferAttribute（见 §8 差异）
  public var index:BufferAttribute;     // 索引缓冲，null = 无索引
  public var groups:Vector.<Object>;    // {start,count,materialIndex} 三元组
  public var boundingBox:Box3;          // null 直到 computeBoundingBox()
  public var boundingSphere:Sphere;
  public var drawRange:Object;          // {start,count}

  public function setAttribute(name:String, attr:BufferAttribute):void;
  public function getAttribute(name:String):BufferAttribute;
  public function deleteAttribute(name:String):void;
  public function setIndex(index:BufferAttribute):void;
  public function addGroup(start:int, count:int, materialIndex:int = 0):void;
  public function clearGroups():void;
  public function setDrawRange(start:int, count:int):void;
  public function computeBoundingBox():void;
  public function computeBoundingSphere():void;
}
```

**强制差异**：three.js 的 `groups`/`drawRange` 是裸 JS 对象字面量；AS3 里用**无名 record**
（`{start,count,materialIndex}`）或小 struct 类。本里程碑用 struct 类 `GeometryGroup`/`DrawRange`
（强类型、免装箱），**不照搬** JS 对象字面量形态。

### 4.3 内建几何（`kit/asaot/three/geometries/`）

首里程碑只做**最小集**（证明属性缓冲通路）：`BoxGeometry`、`SphereGeometry`、`PlaneGeometry`。
它们都是「填 position/normal/uv attribute + index」的工厂，对齐 `src/geometries/*.js` 的
拓扑生成逻辑，**不借**它们的 JS 运行期形态。

---

## 5. 材质（`kit/asaot/three/materials/`）

### 5.1 `Material`（基类）

对齐 `src/materials/Material.js`：`name/type`、`transparent/opacity/alphaTest/side/blending`、
`depthTest/depthWrite/visible`、`needsUpdate/version`（脏标记驱动 seam 层重编译 shader）。
`alphaTest` 是 M10 补的（`Material.js:477` 默认 0）：>0 时 `map` 的 texel alpha 低于阈值的片段被
`kil` 丢弃，用于树叶/铁丝网这类镂空物体（见 §15.2）。
`side`/`blending` 用**静态整型常量**（`FrontSide=0/BackSide=1/DoubleSide=2`、`NormalBlending=1`），
对齐 `src/constants.js` —— 不用 AS3 `enum`（禁用）。

### 5.2 `MeshStandardMaterial`（PBR）

对齐 `src/materials/MeshStandardMaterial.js` 的核心参数面（不借 GLSL chunk）：

```as3
public var color:Color = new Color(0xffffff);      // diffuse
public var roughness:Number = 1.0;
public var metalness:Number = 0.0;
public var emissive:Color = new Color(0x000000);
public var emissiveIntensity:Number = 1.0;
public var map:Texture;                            // null
public var normalMap:Texture;
public var roughnessMap:Texture;
public var metalnessMap:Texture;
public var emissiveMap:Texture;                    // fs5 (M8 follow-up)
public var aoMap:Texture;                          // fs6 (M8 follow-up)
public var aoMapIntensity:Number = 1.0;
public var normalScale:Vector2 = new Vector2(1,1);
public var wireframe:Boolean = false;
public var flatShading:Boolean = false;
```

**关键决策**：参数面照 three.js（`roughness/metalness` 是 metallic-roughness PBR 模型的
标准输入），但 **shader 代码不借**（§9 渲染接缝），PBR 光照在 AGAL 里机器生成。

---

## 6. 灯光（`kit/asaot/three/lights/`）

| AS3 类 | three.js 出处 | 关键面 |
|---|---|---|
| `Light`（抽象基） | `src/lights/Light.js` | `color` + `intensity` |
| `AmbientLight` | `src/lights/AmbientLight.js` | 无方向均匀光 |
| `DirectionalLight` | `src/lights/DirectionalLight.js` | `position` 定方向 + `target`（可简化为方向） |
| `PointLight` | `src/lights/PointLight.js` | `position` + `distance`/`decay`（Frostbite 衰减） |
| `SpotLight` | `src/lights/SpotLight.js` | `position` + `target` + `angle`/`penumbra`/`distance`/`decay` |

光照实现按里程碑递进：ambient + directional（M2 起）→ point + spot 逐光 additive pass（M6 起，见 `AGALRenderer` R10）。

---

## 7. 加载器（`kit/asaot/three/loaders/`）

对齐 `src/loaders/Loader.js` 的**异步形态**（回调式，非 Promise）：

```as3
public class Loader {
  // 抽象基类：load/parse 是待子类覆盖的空实现（D23：AS3 无 abstract class）。
  public function load(url:String, onLoad:Function = null, onProgress:Function = null, onError:Function = null):void;
  public function setPath(v:String):Loader;           // 链式 setter，同 three.js
  public function setResourcePath(v:String):Loader;
  public function setCrossOrigin(v:String):Loader;    // API 形状对齐；本地 IO 忽略
  public function setWithCredentials(v:Boolean):Loader;
}
public class ObjectLoader extends Loader {
  // JSON Object/Scene format 4 信封：{ metadata, geometries, materials, object }。
  // load(url,...) 走 URLLoader -> JSON.parse -> parse；parse(json:Object):Object3D
  // 重建 BufferGeometry（position/normal/uv + index）+ 材质 + 对象树（递归 children）。
}
public class GLTFLoader extends Loader {
  // glTF 2.0 / GLB。load(url,...) 读二进制（.glb 与 .gltf 同一入口），
  // parse(data:*, path, onLoad, onError) 收 String / ByteArray / 已解析 Object。
  // buffers 就绪后同步建图，交付 Object3D（Group，同 three.js 的 gltf.scene）。
}
```

**强制差异**：three.js 用 `fetch`/`XMLHttpRequest`；我们用 as-aot 的 `URLLoader`/`URLRequest`
本地异步通路（D26）。M3 已实装：`JSON.parse` 字符串 → 完整场景图（`Scene`/`Group`/`Mesh`/
`PerspectiveCamera`/`AmbientLight`/`DirectionalLight` + `BufferGeometry` + `MeshBasicMaterial`/
`MeshStandardMaterial`）。M3 支持子集与 D23–D29 全部分歧见 §12。M5 追加批量资产通路
（`FileLoader`/`ImageLoader`/`TextureLoader` + `ObjectLoader.parseGeometry`，D32–D34）；
M8 追加 `GLTFLoader`（glTF 2.0 / GLB，分歧 D40–D45 见 §13）；`[Embed]`/`LoaderInfo` 对齐
留后续阶段。

---

## 8. AS3 ↔ three.js 强制差异汇总（红线约束）

| # | three.js 形态 | 我们改成 | 为什么（红线） |
|---|---|---|---|
| D1 | `userData = {}`、`attributes = {}` 用 JS 动态字典 | `userData` 用 `Dictionary`（任意 key）；`attributes` 用 `Dictionary`（String key → `BufferAttribute`） | as-aot 的反射表只支持 record 字符串 key + Dictionary 对象引用 key，语义对齐见 `AGENTS.md` §2.4 动态索引行 |
| D2 | `add(a, b, c)` 多参 varargs | `...rest` 参数（AS3 原生 rest），内部逐个 add | 语义等价，AS3 有 rest 语法 |
| D3 | `traverse(cb)` 传 JS 闭包 | `traverse(cb:Function)`，cb 走 as-aot 的 Function box（`as_v_fn`） | 已支持；`typeof`/真值判断已有四处同步 |
| D4 | `Vector3.add(a,b)` 双参版返回临时对象 | 只留单参就地版 | 避免每帧 arena 临时分配（红线） |
| D5 | 对象字面量（`groups`/`drawRange`/构造参数 `{}`） | struct 类或命名参数 | AS3 无对象字面量；struct 类免装箱 |
| D6 | `rotation` 与 `quaternion` 用 `_onChange` 双向同步 | AS3 在 `Euler`/`Quaternion` 内部用私有字段 + getter/setter 触发 `_onChangeCallback`，`Object3D` 构造时 hook 两个回调 | three.js 同步点在数学库**内部字段级**，不是 Object3D 的 rotation setter；放 Object3D 层会漏掉 `rotation.x += 0.01` 这种字段写 |
| D7 | JS `Infinity`/`NaN` 默认值（如 `drawRange.count=Infinity`） | 用哨兵常量（如 `-1` 或 `uint.MAX_VALUE`） | AS3 的 `Number` 有 `Infinity`/`NaN`，但 drawRange 语义要显式，不用 JS 隐式约定 |
| D8 | `Object3D` 的 `pivot`（r187 新特性） | 本里程碑不借 | 额外矩阵合成复杂度，`matrixAutoUpdate=false` 可兜底 |
| D9 | `clone()` 用 `new this.constructor()` 返回精确子类 | AS3 无 `this.constructor` 反射，`Object3D.clone()` 返回 `Object3D` 拷贝内容 | 子类精确 clone 留待后续（按需 override），M1 不阻塞首帧 |
| D10 | `BufferAttribute.array` 持有 TypedArray（Float32/Uint8/…），读回时按 `normalized` 做 GL 归一化往返 | `array` 用 `Vector.<Number>`（AS3 `Number`=double），CPU 侧恒 float 语义，`normalized` 留字段但读回不做归一化（归一化归 GPU 上传层 seam） | CPU 缓冲本就是 float，无需 three.js 因 TypedArray 才做的反归一化；不是静默降级 |
| D11 | 索引缓冲分 `Uint16BufferAttribute`/`Uint32BufferAttribute`（`setIndex` 按顶点数自动选） | 索引也是 `Vector.<Number>` itemSize=1，M1 不分精度 | 精度选择是 GPU 上传层（seam）的活，非 CPU 缓冲；顶点数 >65535 时 seam 层再决策 |
| D12 | `groups`/`drawRange` 是裸 JS 对象字面量，`drawRange.count` 默认 `Infinity` | `GeometryGroup`/`DrawRange` struct 类，`DrawRange.count=-1` 表示「渲染到底」 | AS3 无对象字面量（免装箱）；不用 JS `Infinity` 隐式约定（D7 同款哨兵口径） |
| D13 | 几何工厂用 JS 嵌套闭包（如 `BoxGeometry.buildPlane`）、`vector[u]` 字符串索引 | 闭包提为私有方法 + 共享计数器升级为实例字段；`vector[u]` 换成 `Vector3.setComponent(int)` | AS3 无嵌套函数、无动态字段访问 |
| D14 | three.js 的 side/blending 是模块级 export 常量（`constants.js`） | `Material` 的**静态整型常量**（`FrontSide=0` 等），不用 enum | AS3 无模块级常量；enum 被项目规则禁用 |
| D15 | `Material.needsUpdate` 是只写 setter（`Material.js:1246`） | 保留 setter、省略 getter | AS3 无「只写属性」，用 getter 缺席表达只写语义 |
| D16 | `MeshBasicMaterial.map` 纹理采样 | M1 不借，字段留待 M2 随 `Texture` 类落地 | 纹理上传走 seam 层 `BitmapData.pixels`→Stage3D 通路（M2） |
| D17 | `isAmbientLight`/`isDirectionalLight` 运行时类型标志 | 不设标志，渲染器用 `light is AmbientLight` 判类型 | AS3 有 `is` 运算符，无需 JS 的历史遗留标志 |
| D18 | `DirectionalLight.shadow`（DirectionalLightShadow） | M7 已借（单 cascade 方向光阴影 + 深度 prepass） | 阴影映射是独立渲染 pass，深度存颜色（Stage3D 深度附件不可采样） |

---

## 9. 渲染接缝（`seam/asaot/three/`）

渲染后端是**可替换接缝**（对齐 `gpui-borrow-map.md` B3 的思路）：

```as3
// seam/asaot/three/IRenderer.as —— 引擎层只认这个窄接口
public interface IRenderer {
  function render(scene:Scene, camera:Camera):void;
  function setSize(width:int, height:int):void;
}
```

| 后端 | 落地 | 状态 |
|---|---|---|
| `AGALRenderer` | 遍历场景图 → 生成 draw call → 每个材质编译成 AGAL → `ASC_AGAL_TARGET` 翻译成 MSL/GLSL ES | **默认，主后端** |
| `NativeShaderRenderer` | 作者手写 GLSL ES 3.00 一对（three.js `ShaderMaterial` 风格），经 glslang + SPIRV-Cross 直接编到 MSL，绕过 AGAL | **✅ M30 落地，opt-in**（`--features native-shader`；未开时探测不到、`ShaderMaterial` 抛错，见 §37） |

**AGAL-first 的含义**：`MeshStandardMaterial` 等标准材质在 seam 层**机器生成** AGAL 程序
（顶点：position/normal/uv 变换 + MVP；片元：metallic-roughness PBR 简化式），**不要求作者
手写 shader**。这是对 Away3D 的升级点——Away3D 的 shader 也是机器生成但用户无最终 shader
接管路径，E6 补上这个洞。

**渲染接缝强制差异**（与 as-aot Stage3D seam 对齐，见 `AGENTS.md` §2.4）：

| # | three.js/WebGL 形态 | 我们改成 | 为什么（红线） |
|---|---|---|---|
| R1 | `mvpMatrix * position` 直接传 GPU（WebGL 列主序 uniform） | `Matrix3D.rawData` 列主序 + `setProgramConstantsFromMatrix(..., transposed=true)` | AGAL `dp4 op.x, va0, vc0` 计算 `dot(vc0, va0)`，vc0 必须装矩阵**行**；transposed=true 才把每个数学行放进寄存器（as-aot emit 注释已钉） |
| R2 | 索引缓冲是 Uint16/Uint32 TypedArray | `Vector.<Number>` 索引在此 seam 层加宽成 `Vector.<uint>` | `IndexBuffer3D.uploadFromVector` 只收 `Vector.<uint>`（D11 的「精度归上传层」落地处） |
| R3 | 非索引几何走 `drawArrays` | 合成顺序 index buffer（0..n-1）走 `drawTriangles` | Stage3D 无 drawArrays；内建几何恒索引，此分支是安全网 |
| R4 | renderer 每次同步上传 attribute | per-mesh GPU buffer 按 attribute.version 缓存 | 避免每帧 `createVertexBuffer`（热路径分配红线） |
| R5 | three.js 几何体绕序 **CCW** | `setCulling('front')` 反向剔除 | Stage3D 后端 front-face=**CW**（stage3d_glue.mm 为 Starling 设 `MTLWindingClockwise`），CCW 正面是后端「背面」；`setCulling('back')` 会剔除正面渲染背面（M2 金属立方体全黑根因，M1 纯色正反面同色未暴露）。绕序适配集中收口在 seam 层，不反转每个几何体 |
| R6 | 片元 PBR 公式用 GLSL chunk（N2 不借） | AGAL 机器生成 GGX 片元程序（`_buildStandardProgram(hasMap)` 两种变体） | AGAL1 profile 仅 8 个 ft 寄存器，寄存器手工分配（类注释）；fc 布局固定在 `_fillStandardConstants` 与 shader 严格互锁，改常量布局必须同步改 shader |
| R7 | three.js r187 默认 `outputColorSpace = SRGBColorSpace`（`WebGLRenderer.js:313`），线性光照结果输出前编码为 sRGB | standard 程序末级 `pow(x, 1/2.2)` 近似编码（指数在 fc7.w），basic 程序同样末级 `pow(x, 1/2.2)`（指数在 fc1.w，见 `_renderBasic`） | 与 D30 的输入解码配对：渲染在 linear 工作空间、输出时编码，端到端对齐 three.js 默认色彩管理。~~pow 近似与 three.js 精确分段 sRGB 曲线差在暗部（视觉差异很小）~~ —— **D170 已改为真 sRGB 曲线**（`SRGB_CONSTANTS` / `fc41`/`fc42`，§34.1）：2.2 近似在中间调差 3 个码值且方向固定，会让「解+编」这一对退化成非 sRGB 的非线性残差。注意 `setProgramConstantsFromVector` 的 numRegisters 从单个 Vector 连续读 4N 个浮点，多寄存器常量要一个 8 元素 Vector 或分两次上传，否则越界读（basic 的 fc0/fc1 分两次上传） |
| R8 | 贴图族采样（M4）：`map`/`normalMap`/`roughnessMap`/`metalnessMap` 各自语义见 borrow-map AGALRenderer 行 | 单 standard 程序（AGAL2，version=2）+ 恒绑采样槽 fs0–fs3（M8 后续再加 fs5 emissive / fs6 AO，见 §13.1；fs4 留给阴影图）：未绑定槽位绑 1x1 **中性纹理**（白色 = 乘 1 恒等；法线槽位 (0.5,0.5,1) 解码后 = (0,0,1) 恒等法线）；法线扰动走 three.js **默认**的 `getTangentFrame` 导数 TBN（`normalmap_pars_fragment.glsl.js:20-40`，ddx/ddy 指令 AGAL2 起可用，翻译器发射 dfdx/dfdy），无需切线属性 | **必须扰动在前、点积在后**（three.js 顺序：normal_fragment_maps 先跑、光照后算 dotNL 等）——首次实现把 TBN 放在点积之后，光照吃旧法线，法线贴图视觉上完全无效。⚠️ AGAL 部分 swizzle **复制最后一个分量**（`.zw` = z,w,w,w，非 GLSL 的 (z,w)）——导数打包必须写显式 `.xyzw`。`color*map` 的乘法语义（`map_fragment.glsl.js:14`）顺带修复了 M2 hasMap 时忽略 color 的缺漏；`metalnessMap`/`roughnessMap` 是**衰减**语义（`metalnessFactor = metalness × texel.b`），demo 上金属盘需 base metalness=1 而非 0 |
| R14 | 色调映射见 §15.1 | `toneMapping`/`toneMappingExposure` 烘进片元源码；常量占 fc14–fc21（`_uploadToneConstants` 一次传 8 寄存器） | fc0–fc13 已被 standard 程序的材质/光照/阴影/IBL 占满（见 §14.1），色调映射只能往后排。tone 段必须插在 sRGB `pow` 编码之前，且 `toneMapping` 改变要置 `_programsDirty` 惰性重建 |
| R17 | 透明混合见 §15.2 | 渲染循环拆 opaque/transparent 两表，透明表按相机平方距离降序插入排序后单独一趟画（`sourceAlpha`/`oneMinusSourceAlpha`，`setDepthTest(false,'lessEqual')`） | opaque 必须先把深度写满，透明物体才知道自己「在谁前面」；透明表不参与逐光 additive pass（D50），pass 结束恢复 `setBlendFactors('one','zero')` 与深度写入 |
| R18 | `alphaTest` 见 §15.2 | `sub reg, alphaSwizzle, fc15.zzzz` + `kil reg`，**无条件发射**（两条指令）；`alphaSwizzle` 用 `x.wwww` 这种复制形，让 `reg` 四分量同为 `a - alphaTest` | `kil` 的判据是「任一分量为负」，与 GLSL 显式 `if` 不同——靠 swizzle 只填一个分量会让其余分量的旧值决定去留。`alphaTest = 0` 时该段是恒真的 no-op（`a - 0 ≥ 0`），因此不需要为它新增程序变体 |
| R9 | 几何缺 normal/uv 属性时 WebGLAttributes 补**默认 attribute**（normal 默认 (0,0,1)、uv 默认 (0,0)） | seam 层在缓存未命中时合成默认 `BufferAttribute`（法线全 (0,0,1)、uv 全 (0,0)，长度 = position.count，itemSize 对齐），缓存键挂在 position.version 上 | three.js 模型文件常缺 uv/normal（如 io_three 导出的 suzanne 只有 position+index）；`suzanne_buffergeometry.json` 无 uv 时 pipeline 连顶点描述都建不起来（M5 真模型冒烟暴露）。three.js 合成默认 attribute 不写回 geometry（`getAttribute` 仍返 null），我们同样只在 GPU 缓存层合成 |

---

## 10. 里程碑划分

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M1 · 首帧** ✅ | 数学库全量 + `Object3D` 场景图 + `BufferGeometry`/`BufferAttribute` + 内建三几何 + `Scene`/`Mesh`/`Camera` + `AGALRenderer` 最简通路（纯色/漫反射单方向光） | 旋转立方体上屏 ✅（`apps/rotating-cube/`，MeshBasicMaterial 纯色已上屏；漫反射/光照留 M2） |
| **M2 · PBR + 纹理** ✅ | `MeshStandardMaterial` 参数面 + **GGX 微表面**光照（ambient/directional）+ 基础 `map` 纹理采样 | PBR 立方体 + 灯光 + 纹理对比 ✅（`apps/pbr-cube/`：左蓝 GGX 立方体光照渐变 + 右棋盘格 map 立方体，上屏截图确认；specular 峰值经金属 `metalness=1` 诊断验证） |
| **M3 · 资产** ✅ | `Loader` 接口 + `ObjectLoader`（JSON 场景图反序列化） | 加载并渲染 JSON 场景 ✅（`apps/loader-scene/`：内嵌 three.js format 4 JSON 文本 → `JSON.parse` → `ObjectLoader.parse` 重建蓝色 GGX 立方体 + 双灯 → 上屏截图确认；含 D23–D29、R7） |
| **M4 · PBR 贴图族** ✅ | `normalMap`（+`normalScale`）/`roughnessMap`/`metalnessMap` 从「只声明」→ 真采样；单 AGAL2 程序 + 中性纹理；`computeTangents` | 新 demo 上屏 ✅（`apps/texture-maps/`：法线贴图鼓包 + 粗糙度竖向条纹切断高光 + 金属圆盘，截图确认；含 R8、D31） |
| **M5 · 外部资产通路** ✅ | `FileLoader` + `ImageLoader` + `TextureLoader`（字节→BitmapData→Texture）+ `ObjectLoader.parseGeometry`（裸 BufferGeometry JSON）+ `computeVertexNormals/normalizeNormals` + R9 缺属性默认缓冲 | 引擎侧 + 冒烟全绿 ✅（`probes/loader-smoke-m5/` 8 节：FileLoader text/arraybuffer/path 前缀/onError、ImageLoader 像素断言、TextureLoader 同步返+异步填、真 suzanne（505 顶点）+ computeVertexNormals + uuid 守卫）；demo `apps/asset-load/` 磁盘加载 suzanne JSON + PNG 贴图（seam 层绘制已验证：967 三角形/帧），上屏验收待补（验证暂停等编译器侧收工） |
| **M6 · 灯光族扩展** ✅ | `PointLight`（distance/decay）+ `SpotLight`（angle/penumbra/target）；多光逐光 additive pass；物理衰减 | 点光衰减 + 多灯 demo 上屏 ✅（`apps/light-m6/` 方向光/红点光/白聚光三光源） |
| **M7 · 阴影** ✅ | `DirectionalLightShadow`（ortho shadow camera + mapSize + bias + matrix）；深度 prepass render-to-texture（深度存颜色，R11 式）+ 主 pass 采样比较（硬阴影） | 立方体在平面上投阴影 ✅（`apps/shadow-m7/`：悬空立方体投阴影到地面，方向/位置对齐光向；根因修复：投影矩阵深度列 [-1,1]→[0,1] + bias y 列取负，见 borrow-map D-depth/R11-R13）；冒烟 `probes/shadow-smoke-m7/` 19/19 PASS |
| **M8 · GLTF 资产通路** ✅ | `GLTFLoader`（借 r187 `examples/jsm/loaders/GLTFLoader.js`，5006 行）：GLB/glTF 2.0 核心解析管线——GLB 信封（JSON/BIN chunk）、buffer/bufferView/accessor（6 分量类型 + 小端 + normalized + sparse）、交错 bufferView 解析时去步长、mesh/primitives（TRIANGLES/STRIP/FAN）→ `BufferGeometry`、材质 `pbrMetallicRoughness` → `MeshStandardMaterial`（baseColor/metallicRoughness/normal/emissive 因子；alphaMode → transparent/opacity；doubleSided → side）+ unlit → `MeshBasicMaterial`、纹理/图像（bufferView 内嵌 + 外部 + data URI，Skia 解码；sampler → wrap/filter；flipY=false）、节点 TRS/matrix、`PerspectiveCamera`/`OrthographicCamera`、KHR_lights_punctual（依赖 M6）。不落：Draco/meshopt/basisu 压缩、skins、animations、morph targets、emissive/AO 贴图槽（§13 逐条登记） | r187 现成模型上屏 ✅：Duck.glb + DamagedHelmet.gltf 同屏（`apps/gltf-m8/`）；冒烟 `probes/gltf-smoke-m8/` 41 项全 PASS；分歧 D40–D45 见 §13 |
| **M9 · 环境贴图 IBL** ✅ | `CubeTexture` + `CubeTextureLoader` + `Scene.environment` + 渲染器 fs7 cube 采样（漫反射 irradiance + 镜面 radiance + Karis EnvBRDFApprox） | 五金属球粗糙度扫描仅由环境贴图照明 ✅（`apps/env-m9/`）；A/B 去掉 `scene.environment` 整排纯黑；分歧 D46–D48 见 §14 |
| **M10 · 渲染质量** ✅ | `toneMapping`（No/Linear/ACESFilmic）+ `toneMappingExposure`；`transparent`/`opacity`/`alphaTest`/`depthWrite` 真生效（透明 pass 远到近 + NormalBlending + 不写深度；`alphaTest` → `kil`）；AGAL cap 200→400；Metal 4x MSAA（`ASC_S3D_MSAA` opt-in） | 镂空 alphaTest 面板 + 三层重叠玻璃 + 过曝球上屏 ✅（`apps/alpha-m10/`）；三组 A/B（tone / 排序方向 / alphaTest 开关）；冒烟 `probes/alpha-smoke-m10/` 32 项 PASS；分歧 D49–D55、R14–R18 见 §15 |
| **M11 · 几何族 + 剔除** ✅ | `Cylinder`/`Cone`/`Torus`/`Circle`/`Ring`/`Lathe`/`Tube` + `Curve`/`CatmullRomCurve3`/`FrenetFrames` + `EdgesGeometry`/`LineSegments`（顶点着色器线段扩展）+ `mergeGeometries`；`Plane`/`Frustum` 视锥剔除 + `object.frustumCulled` | 几何族画廊 + 线框盒 + 屏外 40 盒上屏 ✅（`apps/geometry-m11/`：7 个几何 + 8 个基座 + EdgesGeometry 12 段线框，`drawCalls=17 / triangles=5428 / culled=40` 稳定；冒烟 `probes/geometry-smoke-m11/` 103 项 ALL PASS）；分歧 D56–D65、R19–R21 见 §16 |
| **M12 · 动画** ✅ | `AnimationClip`/`KeyframeTrack`（Number/Vector/Quaternion/Color/Boolean）× `AnimationMixer`/`AnimationAction` × `PropertyBinding`/`PropertyMixer`，五种插值器（Discrete/Linear/QuaternionLinear/Cubic + glTF CUBICSPLINE）；`Bone`/`Skeleton`/`SkinnedMesh` CPU 蒙皮 + `Mesh` morph targets；`GLTFLoader` 扩 `skins`/`animations`/`JOINTS_0`/`WEIGHTS_0`/`targets` | 6 骨节鞭 + 形变球 + 旋转方块同屏上屏 ✅（`apps/animation-m12/`：`carouselY` 0.45↔0.95、鞭尖 (0.187,3,0)↔(1.4017,2.3192,0)、蒙皮校验和 865.991↔1061.9015、形变半径 0.72↔1.36 全部由动画驱动改变）；冒烟 `probes/animation-smoke-m12/` 110 项 ALL PASS；分歧 D66–D87、R22 见 §17 |
| **M13 · 阴影质量** ✅ | PCF 3×3 九抽头（`LightShadow.radius`）+ `normalBias`/`bias` 符号 + 16 位两字节深度打包 + `castShadow`/`receiveShadow` 真生效 + `alphaTest` 镂空 caster；顺带定死「一 draw 一张阴影图」预算红线（D93）与编译期 AGSL 校验（R23） | 环面投影 + 镂空薄板同屏上屏 ✅（`apps/shadow-m13/`；A/B：半影占比 0%→19.3%、错误自阴影 34.5%→2.6%、镂空投影 4 窗透光）；冒烟 `probes/shadow-smoke-m13/` 47 项 ALL PASS；分歧 D88–D93、R23–R24 见 §18 |
| **M14 · 交互** ✅ | `Ray` + `Raycaster` + `Mesh.raycast`（side 绕序 / `drawRange` / `near`·`far` / 稳定排序 / 包围体早退）+ `Pointer` 的 AIR→NDC 桥 + `OrbitControls`（rotate/dolly/pan + damping + 角度与距离夹取 + 正交 zoom）+ Stage 事件桥 | 点击高亮 + 左拖绕行 + 滚轮缩放 + 右键平移 ✅（`apps/interaction-m14/`，Quartz 合成真实系统鼠标事件驱动，日志给出命中物体/距离/世界点/法线，拖拽 271px 明确不拾取）；冒烟 `probes/interaction-smoke-m14/` **110 项 ALL PASS**；分歧 D94–D100、R25–R26 见 §19 |

> 每个里程碑结束走 asaotui 同款「局部开发 → 全量 `node test.ts` 回归 → README → 版本号」收尾。
>
> **M15–M24 的行不在本表重复**（本表在 M14 之后就没再扩，避免两份漂移）：
> M15→§20、M16→§21、M17→§22、M18→§23、M19→§24、M20→§25、M21/M22→§26、M24→§27；
> M25–M27（HDR / 骨骼可视化+键盘 / LightProbe）的排期与缺口表见 §28，
> README 的「路线图」表是唯一的合并视图。

---

## 11. 已定决策（2026-10-30 拍板）

1. **M1 + M2 合并冲首帧**：不单独做「无渲染的纯逻辑」里程碑，第一个可运行 demo 是旋转立方体上屏。
2. **GGX 微表面**（真 PBR，非 Lambert/Blinn-Phong 近似）。⚠️ AGAL 指令数更高，M2 验收需在
   `ASC_AGAL_TARGET` 翻译器上验证 GGX 片元程序可编译。
3. **基础 `map` 纹理尽早做**（M2 随 PBR 一起，不拖到 M3）。纹理上传走 seam 层
   `BitmapData.pixels` → Stage3D 纹理通路。
4. **绕序适配收口在 seam**（R5）：three.js 几何体绕序 CCW 而 Stage3D 后端 front-face=CW，
   AGALRenderer 用 `setCulling('front')` 反向剔除，而不是反转每个几何体的绕序——保持
   borrow-map 里几何体与 three.js 绕序一致，绕序差异只在 seam 层处理一次。
5. **AGAL2/3/4 profile 完整支持**（2026-10-31 用户确认）：贴图族/多光/阴影的寄存器与指令
   预算不再受限；翻译器 200 指令 cap 按 AGAL1 基线，超出时按 profile 提升。
6. **web 目标暂缓**（2026-10-31）：web 目标验证移出路线图（曾规划为 M8，现 M8 编号已分配给
   GLTF 资产通路）；`IRenderer` 接缝仍保留可替换性，未来需要时再补 web 实现。

---

## 12. 加载器分歧明细（D23–D35，2026-10-31 拍板）

`kit/asaot/three/loaders/{Loader,FileLoader,ImageLoader,TextureLoader,ObjectLoader}.as` 头注释引用的
D23–D35 均在此维护；D30 为 M3 期间发现的渲染色彩管理遗留，已随 M3 收尾解决。

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D23 | JS 抽象基类（构造即抛） | AS3 无 `abstract` class → `load`/`parse` 是空实现，子类覆盖；直接 new 基类是编程错误而非编译错误 | 语言限制，非语义差异 |
| D24 | `loadAsync`（Promise 包装） | AS3/as-aot 无 Promise → 只提供回调式 `load` | 运行时限制 |
| D25 | `requestHeader`/`priority`/`cache`（XHR/fetch 关注点） | 不借（同 N3 口径：借回调形状，不借传输层） | Stage3D 时代的 AS3 无对应物 |
| D26 | `load` 走 `FileLoader`（XHR） | 走 `URLLoader` + `URLRequest` 本地文件（`dataFormat="text"`，`COMPLETE`/`IO_ERROR` 事件同 AIR 语义） | as-aot 的 AIR 对齐 IO 通路 |
| D27 | `parse(json:Object)` 收 JS 对象 | `parse(json:Object)` 收 AS3 动态根类；`JSON.parse` 返回 `any` box，传参时解箱顶层对象，内部每次成员/下标读走 `as_dyn_get`/`as_any_get` | as-aot 动态类型表示差异；`ObjectLoaderSmoke` 同时钉了 object literal 与 `JSON.parse` 两条通路（后者记录与字面量运行时表示不同） |
| D28 | 属性数组 `{ itemSize, type, array }`，`array` 是 TypedArray | `array` 转 `Vector.<Number>`（`Vector.<Number>(jsonArray)` 强制转换，itemSize 保留）；`type` 字符串忽略——我们的 CPU 缓冲恒 float | 同 D-array：AS3 `Number`=double，CPU 侧恒 float 语义；`type` 只是 TypedArray 视图信息 |
| D29 | `for (key in attributes)` 重建任意属性 | M3 硬编码 seam 层消费的三个属性 `position`/`normal`/`uv`（AGALRenderer 只读这三个）；缺失属性即缺失（`getAttribute` 返 null，同 D-miss 口径） | 支持子集诚实声明，不静默吞掉未消费属性 |
| D30 | 默认启用完整色彩管理：`ColorManagement.enabled=true`，`setHex` 做 sRGB→线性解码，输出端线性→sRGB 编码（r187 `outputColorSpace=SRGBColorSpace`） | ✅ **已落地**：`Color.setHex` 按 `ColorManagement.js:186-188` 解码存储；`getHex` 按 `:192-194` 编码返回；`setRGB` 按 working space 原样存储（`Color.js:227-233` 默认参数即 working space，与 three.js 不对称语义一致）；输出编码见 R7（standard + basic 都编码） | 输入解码落地后 basic 路径**必须同步编码**（否则纯色「解码了但没编码」会变暗）；`setHex→getHex` 往返为同一公式逆运算，整数 hex 完全往返一致（LSB 不变，已钉在 math-smoke）。AGALMiniAssembler 三份 app 副本已同步至 2015 版（`examples/air-starling-demo/src/com/adobe/utils/`，AGAL2/3 支持 + `nest` 修复） |
| D31 | `MeshStandardMaterial.normalScale` 是 `Vector2(1,1)`（`MeshStandardMaterial.js:238`），法线贴图 xy 乘数 | AS3 `Vector2` 字段，构造默认 `new Vector2(1,1)` | 随 M4 法线贴图采样一起落地；M2 只声明了贴图字段本身 |
| D32 | `responseType` 支持 ''/text/arraybuffer/blob/document/json | ''/text→TEXT（String 载荷）、arraybuffer→BINARY（ByteArray）、**json→`JSON.parse` 后的对象**（阶段 §31 L3）；blob/document 无 AS3 对应物 ⇒ **走 `onError` 报明**，不再静默当 text | 静默降级正是 AGENTS §1.5 禁的那一类：`responseType='json'` 拿到字符串会让调用方的 `data.metadata` 变成 `undefined`，而 `blob`/`document` 在 as-aot 里根本没有对应类型（无 Blob/DOM 解析器） |
| D33 | fetch 去重表（`loading[url]`），重叠加载共享在飞请求 | 不做去重扇出（AS3 无 fetch 级去重表，用它的 loader 每次 load 新建实例，three.js 同形态）。**但每个 `load()` 自己拥有一份在飞 URLLoader 与自己的闭包**（**D158**）：重复/并发调用**互不覆盖回调、互不投递错数据** | 旧实现把 `onLoad`/`onError` 存在实例字段里，第二次 `load()` 会把**第一个文件的数据交给第二个回调**并饿死第一个——既不是 three.js 的扇出，也不是 AIR 的逐 URLLoader 交付（§31 L1 实测） |
| D34 | `mimeType` 设 `Content-Type` 请求头 | 留字段不消费（本地读无 MIME 提示需求） | XHR 关注点，非本地 IO |
| D35 | `Vector3.fromBufferAttribute(attr, i)` 读属性（`Vector3.js:466`） | 不落地，computeVertexNormals 内联 `set(getX,getY,getZ)` | 加它会引入 math→core 反向依赖（项目约定：Box3/Sphere 因此住 core/） |

> **M4 回归修复（M3 demo JSON 绕序坑）**：`apps/loader-scene/` 的 CUBE_JSON 注释声称「与 BoxGeometry 布局完全一致」，但 vertex 顺序是手写的错版——每面第二个三角形绕序反了，被 `setCulling('front')` 剔除一半三角形（M3 验收时旋转角度掩盖了它；冻结姿态下暴露为「前脸只剩一个三角形」）。已用 `BoxGeometry` 实际 dump 的数据逐字节重写 JSON；loader-smoke 新增 4 项断言钉住权威索引序列（`0,2,1,2,3,1...` 与 v0/v3 坐标），防止再手写漂移。

---

## 13. glTF 2.0 加载器分歧明细（D40–D45，2026-10-31 M8 拍板）

`kit/asaot/three/loaders/GLTFLoader.as` 头注释引用的 D40–D45 在此维护。借的是 r187
`examples/jsm/loaders/GLTFLoader.js` 的**解析顺序与数据形状**（GLB 信封 → buffers →
bufferViews → accessors → primitives → meshes → nodes → scene），不是它的 Promise 管道。

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D40 | `GLTFParser.getDependency` 返回 Promise，整图 `Promise.all` 后交付 | AS3/as-aot 无 Promise：`buffers` 先全部就绪（GLB BIN 直接取、`data:` URI 内联解码、外部 `.bin` 走 `FileLoader` 并计数），计数归零后**同步**建图；图像解码**不阻塞**——`Texture` 对象先建好，位图解码完成后回填 `image` 并 `needsUpdate`，渲染器下一帧自动重传。`onLoad` 因此在场景图成型时触发，贴图可能仍在解码 | 语言/运行时限制（同 D24）。不阻塞是刻意的：demo/探针的渲染循环本就按帧探测 `texture.version`，阻塞反而会把单帧拉长到解码耗时 |
| D41 | `DataView.getUint32(4,true)` / TypedArray 视图天然小端 | GLB 头与 chunk 头用 `ByteArray.endian = LITTLE_ENDIAN` 直读；**float32 例外**：as-aot `ByteArray.readFloat` 忽略 `endian` 恒按大端解（实测；见 as3compiler TODO），故 `_readFloatLE` 取四字节倒序回放 | 不照抄 DataView：AS3 对应物就是 ByteArray，而它的 readFloat 有一处与 AIR 不符的实现缝隙；用倒序回放保证语义正确而不是「碰巧能跑」 |
| D42 | accessor 保留原始 TypedArray（Uint8/Int16/…），`normalized` 交给 GPU | 一律落 `Vector.<Number>`：整数分量读取时拓宽为 double，`normalized` 在 CPU 按 1/255、1/65535、1/127、1/32767 归一（有符号截到 -1） | 同 D-array：我们的 CPU 缓冲恒 float，`BufferAttribute` 没有整数视图；归一化放 CPU 才能让 AGAL 的 `FLOAT_*` 顶点格式直接吃 |
| D43 | 交错 bufferView 用 `InterleavedBuffer` + `InterleavedBufferAttribute`（stride/offset） | 解析期按 `byteStride` 去步长，铺成紧凑 `Vector.<Number>` | AGAL 的 `setVertexBufferAt` 只有一个 interleave 偏移参数，`BufferAttribute` 也无 stride 字段；去步长是 seam 唯一能上传的形状（代价是内存翻倍，M8 可接受） |
| D44 | `for (name in attributes)` 全量重建（含 COLOR_0/JOINTS_0/WEIGHTS_0/TEXCOORD_1+） | 只接 `POSITION`/`NORMAL`/`TEXCOORD_0`/`TANGENT`（seam 只消费这四个；`COLOR_0` 与蒙皮属性在 M8 无程序可读）；缺 `NORMAL` 时 `computeVertexNormals()` 补 | 同 D29 口径：支持子集诚实声明。注意不补法线会让 R9 的常量 (0,0,1) 法线把整模型压平 |
| D45 | 灯光节点的 `target` 用 `light.add(target)` 挂在 (0,0,-1) | 一致：`DirectionalLight`/`SpotLight` 的 `target` 作为**子节点**挂在 (0,0,-1)，方向由 `position - target` 世界坐标算出 | 这是 "light points down local -Z" 的 glTF 约定；不挂子节点则 `target` 留在原点，方向会变成「指向世界原点」 |

### M8 明确不落（登记遗留，见 README 路线图备注）

- 压缩扩展：`KHR_draco_mesh_compression`、`EXT_meshopt_compression`、`KHR_texture_basisu`、`EXT_texture_webp`/`avif`。
- 动画/蒙皮/形变：`skins`、`animations`、morph targets（`JOINTS_0`/`WEIGHTS_0` 直接跳过）。
- ~~贴图槽缺口：`emissiveTexture`、`occlusionTexture`~~ → **已补齐**（M8 后续，见 §13.1）。
- ~~`KHR_texture_transform`~~ → **已补齐**（L3/D166，§31.8）；`KHR_materials_*`（clearcoat/transmission/ior/…）、`EXT_mesh_gpu_instancing` 仍不落。
- 透明：`alphaMode` 的 `transparent`/`opacity`/`depthWrite` 已按 API 形状写入材质，但 seam 的标准程序
  尚未做 alpha test/混合 pass，因此 **BLEND/MASK 的视觉结果与 OPAQUE 相同**（诚实声明，不静默）。

### 13.1 emissive / AO 采样槽（M8 后续补齐）

跟进项落地方式与 three.js 语义对齐：

| 槽 | 绑定 | 片元做法 | 为什么这样接 |
|---|---|---|---|
| `fs5` | `material.emissiveMap` | `tex ft11 ← fs5`，`ft11.xyz *= fc7.xyz`（`fc7.xyz = emissive * emissiveIntensity`），`ft4.xyz += ft11.xyz`（在光照之后、sRGB 编码之前） | three.js `emissivemap_fragment.glsl.js:6` 就是 `totalEmissiveRadiance *= emissiveTexel`，再在 `output_fragment` 前加进结果——顺序必须一致，否则自发光会被 Gamma 编两次 |
| `fs6` | `material.aoMap`（+`aoMapIntensity`） | `ao' = mix(1, texel.r, aoMapIntensity)`，只乘环境（间接漫反射）项 | `aomap_fragment.glsl.js` 的语义是把 AO 乘在间接光上；我们目前**只有环境光当间接项**（间接高光要等 envMap，M9），所以先只衰减 ambient |
| 缺图 | 绑 R8 的 1x1 中性白纹理 | 白纹素 → `ao'=1`、`emissive*1`，两条公式退化成恒等 | 与 fs0–fs3 同一套「中性纹理代替变体」策略，程序数不随材质组合爆炸 |

**教训（M8 首屏白团根因）**：只接 `emissiveFactor` 不接 `emissiveTexture` 时，中性白纹素会让
`emissive = factor × 1` 命中整网格——`emissiveFactor=(1,1,1)` 的资产（DamagedHelmet）直接过曝成白模。
中性纹理策略只有在**纹理和因子成对**应用时才成立。已在 `probes/gltf-smoke-m8/` 钉住
（`emissiveMap != null` 与 `emissiveFactor` 同时保留、Duck 一侧两者皆空）。

**指令预算**：标准片元程序 120 → 128 条（含阴影变体 128），离 200 条 decode cap 还有 72 条余量；
`AGALRenderer._buildStandardProgram` 在组装后按 `(agalcode.length-7)/24` 计数并 trace（M9 起改为每次构造都打，见 §14.1）。

---

## 14. 环境贴图 IBL 分歧明细（D46–D48，2026-10-31 M9 拍板）

借的是 r187 的**光照语义**（`ShaderChunk/envmap_physical_pars_fragment.glsl.js` 的
`getIBLIrradiance`/`getIBLRadiance` + `lights_physical_pars_fragment.glsl.js:476/:723-728` 的
split-sum 合成），不是它的 PMREM 生成器与 `dfgLUT` 贴图。

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D46 | `Scene.environment`：`Object`，可为 CubeTexture / equirect Texture / PMREM RenderTarget；`WebGLRenderer` 按 `material.envMap \|\| scene.environment` 逐 draw 取（`WebGLRenderer.js:2228/:2232`） | 只接 `CubeTexture`（六面 `BitmapData`）。`Scene.environment` 是 `CubeTexture` 类型槽；渲染器在 `render()` 里取一次放 `_envCube`，`_renderStandard` 再按 `material.envMap \|\| _envCube` 解析 | equirect 需要在运行时立方体化（一次离屏渲染 + 6 个 view 矩阵），属独立工程；`.hdr`（RGBE）还要 float 贴图，本后端没有。先只支持「六张 LDR 面」这条最短且可验证的路径 |
| D47 | `CubeTextureLoader extends Loader`，`load(urls[], onLoad, onProgress, onError)` | **不继承** `Loader`：自带 `path` + `setPath()`，`load(urls:Vector.<String>, ...)` 返回 `CubeTexture` | AS3 的 override 参数类型是**不变**的（invariant），`Vector.<String>` 无法覆盖基类 `load(url:String, ...)`；强行继承只能留一个静默空实现，比不继承更糟 |
| D48 | ① `textureCubeUV(envMap, R, roughnessToMip(roughness))` 读 **PMREM 预卷积 mip 链**；② DFG 项来自 `dfgLUT` 贴图（`lights_fragment_begin.glsl.js:61`）；③ `computeMultiscattering` 做多重散射能量补偿 | ① 无 PMREM：`R = normalize(mix(reflect(-V,N), N, r⁴))`，再按 `r⁴` 把采样结果向**法线方向的 irradiance** 混合——`r=0` 是镜面，`r=1` 退化成余弦积分量级的平色（与 PMREM 最大 mip 的观感一致，中间档只是近似）；② DFG 用 Karis `EnvBRDFApprox` 解析式（`r = roughness·c0 + c1`、`a004 = min(r.x², exp2(-9.28·NoV))·r.x + r.y`、`AB = (-1.04,1.04)·a004 + r.zw`），AGAL 只有 `exp` 没有 `ex2`，故 `fc13.x = -9.28·ln2 = -6.432405835596292`；③ 不落多散射补偿 | 本后端没有 float render target，也没有离屏渲染 target 的通用通路，PMREM 的 6 级卷积无从生成；`dfgLUT` 是额外的采样槽 + 资产，而解析式在 `[0,1]` 粗糙度内与 LUT 差别 <1%。多散射是 M9 之外的精度问题，登记为遗留 |

### 14.1 采样槽与公式（标准片元程序）

| 槽 | 绑定 | 片元做法 |
|---|---|---|
| `fs7` | `material.envMap`，否则 `scene.environment`；都没有则绑 8×8 **中性白 cube** 且 `fc10.x = 0` | **间接漫反射**（stage 5）：`irr = cube(N)·envMapIntensity·π + ambient`，再 `× diffCont/π`，然后被 AO 衰减（与 three.js 把 irradiance 和 ambient 都归入 indirect diffuse 一致）。`π` 是 `fc13.y`：`getIBLIrradiance` 自带 `PI *`，而 `BRDF_Lambert` 又除 π，缺了它环境相对 `AmbientLight` 会暗 1/π |
| | | **间接高光**（stage 6.5，新增）：`R = 2·dotNV·N − V` → `normalize(mix(R, N, r⁴))` → `radiance = cube(R)·envMapIntensity` → 按 `r⁴` 向 `cube(N)·envMapIntensity` 混合（D48①）→ `spec = radiance·(F0·AB.x + AB.y)`，加到主累加器 |

**为什么仍是「一套程序」**：fs7 无条件采样两次，缺环境时靠中性白 cube × `envMapIntensity=0` 归零——
与 fs0–fs3/fs5/fs6 的「中性纹理代替变体」完全同构，`_standardProgram`/`_standardProgramNoShadow`
两套程序覆盖全部材质组合。

**指令预算**：标准片元 128 → **168/200**（含阴影变体；无阴影 160），余 32 条。新增的 40 条里，
29 条是反射向量 + BRDF，8 条是 prefilter 混合，3 条是 irradiance 的 π 与 N 采样。
`_buildStandardProgram` 组装后按 `(agalcode.length-7)/24` 计数并**每次构造都 trace**
（`Program3D` 没有取指令数的接口，trace 是唯一可观测句柄，探针/demo 靠它钉数）。

**M9 明确不落（登记遗留）**：PMREM 预卷积链与 `roughnessToMip`、`dfgLUT` 贴图、多重散射能量补偿、
`DataTexture`、equirect/HDR 环境源、`environmentRotation`/`environmentIntensity`、
`Scene.background` 天空盒（背景仍是 `clear` 的纯色）。

## 15. 渲染质量：色调映射 / 透明混合 / alphaTest / MSAA（D49–D55，2026-10-31 M10 拍板）

M10 之前 `transparent`/`opacity`/`alphaTest` 只有 API 形状、`toneMapping` 根本不存在：透明材质仍进
不透明 pass 并被后画的东西直接盖住，过曝区域一律砍成平坦死白。M10 让这四件事真的生效。

### 15.1 色调映射

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| R14 | `toneMapping` 取 `No/Linear/Reinhard/Cineon/ACESFilmic/AgX/Neutral` 七种；`toneMappingExposure` 是 `uniform float`（`WebGLRenderer.js:278/:286`，`tonemapping_pars_fragment.glsl.js:8`） | 只落三种：`NoToneMapping=0`（默认，与 r187 默认一致）、`LinearToneMapping=1`（`saturate(exposure·c)`）、`ACESFilmicToneMapping=2`（`tonemapping_pars_fragment.glsl.js:46-73` 逐条对齐：`:62` 的 `exposure/0.6` 预缩放、`:49`/`:56` 两个 mat3、`:35-42` 的 RRT/ODT 系数） | Reinhard/Cineon 是几行算式，但**没有验证过**就没有理由声称支持；AgX/Neutral 需要额外查找表。宁少不假 |
| R15 | tone mapping 在**线性域**做完再进 `outputColorSpace` 编码 | 插在 sRGB 输出编码（D170 起是真曲线 `srgbEncodeBlock`，此前是 `pow(x,1/2.2)`）**之前**，作用于线性颜色 | 顺序反了会把已经伽马编码的颜色再压一次，视觉上是整体灰化——这条顺序是硬约束，不是风格选择 |
| R16 | 一次 draw 里所有光累加完，**最后**一次 tone map | 方向光/ambient/IBL 在主 pass 里一次 tone map；**点光/聚光是逐光 additive pass，每个 pass 各自 tone map 后相加** | 逐光 pass 是 AGAL 指令预算下的既有结构（R10）。把 tone map 从 punctual 片元里拿掉会让点光叠加区亮度失控（无上限），留着则是「先各自压缩再相加」，多灯重叠时比 three.js 略暗。两种都不等于正确解，选**不失控**的那种，并在此登记为已知偏差。单灯场景两者完全一致 |

**同步约定**：`toneMapping` 烘进片元源码，setter 只在值真的变化时置 `_programsDirty`
（下次 `render()` 惰性重建）；`toneMappingExposure` 只是常量，改了不重建。程序也是**懒建**——
构造后第一次 `render()` 才编译，避免「构造时建一遍、设完 toneMapping 再建一遍」的白工。

### 15.2 透明混合与 alphaTest

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| R17 | `WebGLRenderLists` 把 `material.transparent === true` 收进 `transparent` 列表，`reversePainterSortStable` 按 `groupOrder`→`renderOrder`→`b.z - a.z`（远到近）排序（`WebGLRenderLists.js:31-47/:134/:170`） | 渲染循环拆 `_opaqueMeshes`/`_transparentMeshes` 两表：opaque 先画（写深度），transparent 后画（`sourceAlpha`/`oneMinusSourceAlpha`、不写深度），列表内按**相机到对象世界原点的平方距离降序**插入排序 | 平方距离与原位 `b.z - a.z` 同序，但省掉一次世界→视变换；透明物体量级是个位数，插入排序不分配、无 GC 压力。`groupOrder`/`renderOrder` 是材质分组特性，M10 不做（登记遗留） |
| D49 | `depthWrite` 由 `WebGLState.js:771` 的 `depthBuffer.setMask(material.depthWrite)` 控制，深度测试/写入是两个独立开关 | Stage3D 的 `setDepthTest(depthMask, compare)` 两者绑定，故透明 pass 用 `setDepthTest(false,'lessEqual')`：**比较仍做**（远处的玻璃不会盖住近处的），**写入关掉**。pass 结束恢复 `setDepthTest(true,'lessEqual')` + `setBlendFactors('one','zero')` | 关掉比较会让场景里所有透明物按绘制顺序无条件覆盖（视觉上是「最后画的赢」），关掉写入才能让多层玻璃正确叠色。Stage3D 没有分开的开关，只能取两口子都沾的这个挡位 |
| D50 | 所有光在同一个片元里累加，透明材质的多光与不透明材质一样 | **透明材质不参与逐光 additive pass**，只受 ambient + 方向光 + IBL 照亮 | 逐光是**加色混合**（`one,one`），一个半透明物体如果每个光 pass 都混合一次 `srcAlpha`，最终 alpha 会被叠加放大到远超 `material.opacity`——多层玻璃会变成不透明色块。要么每 pass 都只算「光贡献的一部分、alpha 不参与」，要么干脆不参与。选后者：语义可解释、不会失控，代价是透明物看不到点光/聚光的贡献（登记为已知限制）。M6 的 punctual pass 里 `_activePass != 0` 时对 `MeshBasicMaterial` 直接 return，也是同一处判定 |
| R18 | `alphatest_fragment.glsl.js:11`：`if (diffuseColor.a < alphaTest) discard;`，另有 `ALPHA_TO_COVERAGE` 分支用 `fwidth` 做软边（`:6-7`） | 编译成 `sub reg, alpha, alphaTest` + `kil reg`。**`kil` 在任一分量为负时丢弃**，所以 `reg` 必须四分量都填 `a - alphaTest`（不能靠 swizzle 只填一个分量，那会让其余分量的旧值决定去留） | AGAL 的 `kil` 条件与 GLSL `discard` 不同（GLSL 是显式 if），是「寄存器有负分量就丢」；理解错这层语义会得到随机消失的三角形。`fwidth` 是标量导数，AGAL 无对应指令 ⇒ 剪影是**硬边**，与 three.js 的软边有肉眼可见差别（尤其远处小物体），登记为已知差异 |
| D51 | `blending` 支持 `Normal/Additive/Subtractive/Multiply/Custom/...` 六类 + `premultipliedAlpha` | 只实现 NormalBlending（`SRC_ALPHA`/`ONE_MINUS_SRC_ALPHA`）。`Material.blending` 字段在，但不参与状态设置 | 每种混合模式在 Stage3D 里都是不同的 `setBlendFactors` 组合，但没有对应 demo/探针验证就声称支持等于撒谎。additive 混合有一个现成的真实用例（M6 多光 pass 内部在用），材质的 `blending` 面留到有验收场景再接 |
| D52 | `alphaMode: BLEND` 同时暗示 `transparent = true` 与 `depthWrite = false`；`MASK` 只设 `alphaTest = alphaCutoff` | M8 首版把 `alphaCutoff` **误写进了 `opacity`**（MASK 材质会整体半透明）。M10 改为 `alphaTest = alphaCutoff`，`transparent`/`depthWrite` 由 BLEND/OPAQUE 分支各自负责 | `opacity` 是「整体透明度」，`alphaTest` 是「按纹素 alpha 二值裁剪」，两者语义完全不同；混用会让 MASK 模型（树叶/铁丝网这类）既没镂空又莫名透明。这是 M10 修掉的真实 bug，探针里有一条专门钉它 |

### 15.3 4x MSAA（opt-in）

| # | 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D53 | `WebGLRenderer` 的 `antialias: true` 在创建上下文时定，不能事后改 | `ASC_S3D_MSAA=2\|4` 环境变量 opt-in，默认 **1**（Air 等价路径）；Metal 侧分配 multisample color + depth 纹理，`pipelineState.rasterSampleCount = N`，帧末一次零 draw 的 `MultisampleResolve` pass 把结果解析进窗口纹理 | 默认必须是 1：AIR 的 Stage3D 没有等效旋钮，默认开会让「同一份代码在 adl 与我们后端看起来不一样」，违反「对齐 AIR 是底线」。opt-in 是增强，不是默认行为 |
| D54 | — | 带 `renderOverride` 的 pass（阴影 prepass、`drawToBitmapData`）**强制 1 采样** | 阴影贴图 / 位图回读的取样必须是确定性的；MSAA 的 resolve 发生在帧末，中途读 RTT 会读到未解析的样本，语义不清。`s3d_pass_samples()` 是这条规则的唯一落地点 |
| D55 | — | MSAA 只作用于**屏上** pass。pipeline 缓存 key 带 `samples`，同一程序在屏上/RTT 下各建一份 PSO | Metal 的 pipeline state 与采样数绑定，不是运行时状态；不加进 key 会在 RTT 之后复用错采样数的 PSO（表现为整屏黑或画面撕裂） |

`ASC_S3D_MSAA` 是**环境变量**而非 API：`Stage3D.requestContext3D` 之后才能拿到 `Context3D`，
而 MSAA 的分配发生在 `s3d_create`（C 侧），JS/AS3 层没有插话点。要在运行时可控需要给
`Context3D` 加一个非 AIR 的静态开关——那是增强项的形状，M10 不做。

> **后续（M34，2026-11-03）**：RTT 侧的「运行时可控」后来真的做了，但形状不是给 `Context3D`
> 加开关，而是逐目标的 `Context3DNative.setRenderTargetSamples(tex, n)`（§39.17 的 D220）。屏上路径仍走
> `ASC_S3D_MSAA`，两者互不影响：屏上那个是一次性的上下文级配置，离屏这个是应用按 target 决定的
> 同一次绘制能多次切换的状态。

**验证方式**：`temp/msaa_shot.sh` 同场景跑 `ASC_S3D_MSAA` 未设 vs `=4`，差 3390/259200 像素、
最大通道差 581，差异集中在球体剪影边缘（`temp/msaa_diffmask.png` 与 `temp/msaa_edge_ab.png`）。
边缘有差、内部无差，正是 MSAA 该有的样子；差异若落在面上说明采样数没生效而是别的状态被改了。

### 15.4 指令预算：AGAL1 基线 200 → 400

`as3compiler/src/runtime.ts` 的 `agal_instr ins[200]` → `ins[400]`，报错文案同步。200 是 AGAL1 的
基线，不是语言上限；ACES 的 17 条 + alpha test 的 2 条 + 顶点侧若干把标准片元推到 171（无 tone）
/ **188（ACES + 阴影）**。预算余量因此从 32 降到 **212**——M11 的几何族不碰片元，M12 的蒙皮只加
顶点指令，M13 的 PCF 会吃掉几十条，400 足够覆盖到 M14。

**M10 明确不落（登记遗留）**：`Reinhard`/`Cineon`/`AgX`/`Neutral` 色调映射；
`ALPHA_TO_COVERAGE` 软边 alphaTest（无 `fwidth`）；`blending` 多态（Additive/Multiply/Custom）；
`premultipliedAlpha`；`renderOrder`/`groupOrder` 显式排序键；透明材质的点光/聚光贡献；
`scene.background` 天空盒；MSAA 的逐 pass 采样数配置（只有全局 opt-in）。

## 16. 几何族 / 曲线 / 线框 / 视锥剔除（D56–D65、R19–R21，2026-10-31 M11 拍板）

M11 补齐「除 Box/Sphere/Plane 之外的几何」，并把「每帧全量提交」改成真的视锥剔除。三类改动：
纯 CPU 的几何构造（§16.1/§16.2）、渲染器新增的两条通路（线框 §16.3、剔除 §16.4），以及由此暴露的
两个渲染器 bug（§16.5 阴影采样越界、§16.6 线框落在 clip 空间）。

### 16.1 几何族（7 个 `kit/asaot/three/geometries/*.as`）

| 类 | three.js 出处 | 借的形态 | 我们的差异 |
|---|---|---|---|
| `CylinderGeometry` | `src/geometries/CylinderGeometry.js:34`(构造)/`:70`(generateTorso)/`:188`(generateCap) | 躯干 (heightSegments+1)×(radialSegments+1) 网格 + 斜面法线（`(radiusBottom-radiusTop)/height` 归一化），两个盖各自独立 UV，且**每个径向段一个中心顶点**（这样圆盘才能承载径向 UV）；group 0/1/2 = 躯干/上盖/下盖 | **D-fn**：`generateTorso`/`generateCap` 在 JS 里是共享 `scope`/`index`/`indexArray`/`groupStart` 与四个缓冲的嵌套闭包。AS3 无嵌套函数 ⇒ 提为私有方法 + 构造时提升的实例字段，返回前清空（与 `BoxGeometry.buildPlane` 同形）。JS 侧靠闭包变量天然隔离，我们在同一实例上重入，所以**必须**清空，否则第二次 `new CylinderGeometry` 会带上上一次的索引偏移 |
| `ConeGeometry` | `ConeGeometry.js:30` | 一行：`CylinderGeometry(0, radius, height, ...)` | 不复制任何几何代码——锥角三角形与「没有上盖」都由 `CylinderGeometry` 的 `radiusTop==0` 分支自然产出 |
| `TorusGeometry` | `TorusGeometry.js:31` | (radialSegments+1)×(tubularSegments+1) 网格，法线 = 圆心环指向顶点的方向；`arc` 把甜甜圈剪成 C 形，`thetaStart/thetaLength` 旋转/裁剪截面 | 无形制差异。**注意 r187 的新参数化**：环面躺在 **XY 平面、洞沿 Z**（老版本是 XYZ 互换），所以默认朝 +Z 相机，与旧版布局的直觉相反 |
| `LatheGeometry` | `LatheGeometry.js:36` | 2D 折线（`points: Vector2`，x=半径 y=高度）绕 **Y** 轴旋转 `segments` 次；法线取折线段方向、内部点处累加，因此车削出来的花瓶是光滑的而不是多面体 | 无差异，但**继承了两个 three.js 的行为**，不做「修正」：①`prevNormal` 在 `normal.normalize()` **之前**拷贝，内部点累加进的是未归一化的邻法线；②`normal.z` 恒为 0（折线本身是 2D）。改了会改变所有车削件的轮廓高光 |
| `CircleGeometry` | `CircleGeometry.js:35` | 1 个中心顶点 + segments+1 个边缘顶点 → 三角扇；边缘 UV 是位置按半径投影到 [-1,1] 再映射到 [0,1] | 读顶点缓冲时直接用循环局部的 `vertex`，不再学 three.js 的 `vertices[i]` 绝对偏移回读（那是它并行维护 `i` 偏移的产物，我们没有那个约束） |
| `RingGeometry` | `RingGeometry.js:31` | phiSegments+1 圈同心环 × thetaSegments+1，缝成四边形；UV 只按**外半径**投影 | 同 Circle 的直读；UV 只用外半径是刻意的（内外圈才对得齐） |
| `EdgesGeometry` | `EdgesGeometry.js:35` | 每条三角形边按量化端点位置做哈希；同一对端点出现在两个法线夹角 > `thresholdAngle` 的三角形里 ⇒ 硬边，两顶点都发射；只出现一次的边 ⇒ 边界，也发射；共面共享边丢弃（这是盒子出 12 条线而不是 36 条的原因） | **D62**：three.js 用 `Map` 以字符串 key 存边、靠 `set(key, null)` 标记「已配对」并依赖插入顺序输出。as-aot 的 `Dictionary` 没有插入序，且「不存在」与「存了 null」都返回 null ⇒ 我们用显式 `_edgeOrder`（创建序 = three.js 的插入序）+ `_edgeIndex`（key→位置）+ `_edgeConsumed` 复现 `has()`/`get()` 三态。**D63**：`thresholdAngle` 单位是**度**（与 three.js 一致，内部 `DEG2RAD`） |

**几何族的验收口径**：`probes/geometry-smoke-m11/` 不调用被测几何去算期望值，而是**独立重算** r187 拓扑
应有的顶点/索引/group 数再比对；外加包围盒证明「躺在正确的平面」（Torus/Circle/Ring 在 XY、
Cylinder/Cone 立在 Y、Lathe 绕 Y）、法线单位长与朝外符号、UV 角点约定。

### 16.2 曲线与扫掠（`kit/asaot/three/extras/`）

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D58 | `Curve.getPoint(t)` 是抽象方法，子类不实现时 JS 里得到一个 `undefined` 或运行时崩 | 基类 `getPoint` **主动抛 `Error`** | AS3 的抽象方法只能靠抛错表达；让它「返回零点」会把未实现的子类伪装成「曲线塌成一点」，排查成本远高于一进就崩 |
| D59 | `computeFrenetFrames` 返回 JS 对象字面量 `{tangents, normals, binormals}`（`Curve.js:338`） | 返回 `FrenetFrames` 值对象（三个 `Vector.<Vector3>`） | 引擎里不用 AS3 动态对象承载结构化返回值（D-object 口径）；且 `TubeGeometry` 要按名字取三条数组，值对象让类型在编译期就被检查 |
| D60 | `CubicPoly` 是 JS 工厂函数（`CatmullRomCurve3.js:4`），内部 `initNonuniformCatmullRom`/`initCatmullRom` 两个闭包 | 提为 `CubicPoly` 类 + 两个公开初始化方法 + `init(x0,x1,t0,t1)` 求系数 | 无嵌套函数；两个 init 的差别只在切线幅值 (c1,c2) 的算法，正好是两个方法 |
| D61 | `TubeGeometry` 直接用 `tubularSegments` 做除数 | `tubularSegments`/`radialSegments` 夹到 ≥1 | three.js 的 `new TubeGeometry(path, 0)` 会产出全 NaN 顶点（0 做除数），下游是「整块几何消失」这种无提示故障。宁可给一个退化但有限的几何 |
| — | `CatmullRomCurve3(points, closed, curveType='centripetal', tension=0.5)`（`CatmullRomCurve3.js:120`） | 三种参数化（centripetal/chordal/catmullrom）+ `closed` 端点外推全部照搬 | 三种类型的差别只体现在 `initNonuniformCatmullRom` 的 `dt0/dt1` 幂次，照抄成本极低而形状差异明显 |

`TubeGeometry` 的 Vertex 数是 `(tubularSegments+1)×(radialSegments+1)`、索引 `tubularSegments×radialSegments×6`；
**闭合路径**时 last 环复用第 0 环的 frames（`closed ? tubularSegments : tubularSegments+1` 次 `generateSegment`），照搬。

### 16.3 线框：`LineBasicMaterial` + `LineSegments` + 顶点着色器线段扩展

Stage3D 没有 line 图元（既无 `drawLines` 也无 `lineStrip`），所以线框只能展开成三角形。做法：
CPU 侧把每段 `(A,B)` 展开成 4 个顶点（`pos` / `other` / `side` 三组属性，索引 `(0,1,2)(1,3,2)`），
顶点程序在**屏幕空间**把每一对端点扩成 2 像素宽的四边形。

| # | 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| R20 | three.js 用 `gl.LINES` + `LineBasicMaterial.linewidth`（WebGL 下 linewidth 恒为 1） | 顶点程序扩展：`方向 = (ndcB - ndcA) × (半视口宽, 半视口高)` → 2D 归一化 → 垂直向量 `(-dy, dx)` × `side` × `线宽/2` → 除回半视口得 NDC 偏移 | 先乘半视口再归一化，是为了让 `x`/`y` 的**像素密度**一致——直接在 NDC 里归一化会让斜线在非方形视口上瘦成一条；`-dy` 用 `vc.w = -1` 相乘得到（AGAL 源操作数没有一元负号，`AGALMiniAssembler` 的操作数正则也不接受符号） |
| — | — | **线段顶点程序必须用 `vt0..vt7`**，`ft*` 是片元专用 | AGAL1 的顶点临时寄存器只有 `vt`。写成 `ft` 时翻译器不报错但写入被丢弃，表现为「线不出现」 |
| — | — | **矩阵必须用四条 `dp4`，不能用 `m44`** | 常量是按 `setProgramConstantsFromMatrix(..., transposed=true)` 上传的（vc0..vc3 装矩阵**行**，见 R1），这正是 `dp4` 的约定；而翻译器里 `m44` 的矩阵布局与它不一致，用它会把每段线摆到完全错误的位置（M11 现场故障：线框缩成屏幕中心的一小团） |
| — | — | **NDC 偏移必须再乘 `w` 才写进 `op`** | `op` 是 **clip 空间**位置，GPU 会在程序之后统一除以 `w`。偏移是在除过 `w` 的 NDC 上算的，直接 `op.xy = ndc.xy + offset` 会让整段线被缩小 `w` 倍、向相机轴塌缩（≈9.6 倍，肉眼就是「中心一团乱线」）。正确写法：`add vt1.xy, vt1.xy, vt4.xy` 后 `mul vt6.xy, vt1.xy, vt6.wwww`，最后 `mov op, vt6`（`op` 全程只写一次） |

**验收**：`apps/geometry-m11/` 右端 1.1 单位盒子 + `EdgesGeometry` 线框，`DRAW_EDGES` 常量做 A/B
（关掉只剩暗色盒子、打开出现 12 条青色棱）；`probes/geometry-smoke-m11/` 把顶点程序**逐条转写**成断言
（30 条指令、含 `dp4` 不含 `m44`、含 `mul vt6.xy, vt1.xy, vt6.wwww`）——这三条都是「只在屏幕上表现为
错」的坑，源级钉子比截图便宜。

### 16.4 视锥剔除（`core/Plane.as` + `core/Frustum.as` + 渲染器）

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| R19 | `WebGLRenderer.projectObject` 先 `_frustum.setFromProjectionMatrix(_projScreenMatrix)`，其中 `_projScreenMatrix = projectionMatrix * matrixWorldInverse`；再对每个 `object.frustumCulled` 的对象用 `intersectsObject`（世界包围球）判定（`WebGLRenderer.js` 的 projectObject + `Frustum.js:95/:146`） | `AGALRenderer` 用**同一份** `_viewProjection`（= `projectionMatrix × matrixWorldInverse`）抽平面，再测对象的世界包围球 | **这是 M11 的头号 bug**：首版误用 `camera.projectionMatrix` 抽平面，得到的是**相机空间**的六个平面，却拿去和**世界空间**的球比较 ⇒ 绝大多数物体被误剔除（画廊整排消失）。three.js 的 `Frustum.setFromProjectionMatrix` 从来只接受 view-projection，投影矩阵单独喂进去没有意义 |
| — | 平面提取用 `WebGLCoordinateSystem` 的近平面 `me3 + me2` | 用**深度的 [0,1] 口径**（`me2`/`me6`/`me10`/`me14` 直接作为近平面），因为本后端的 NDC z 是 [0,1] | Stage3D/Metal 的深度是 [0,1]（同 D-depth/R13）。照抄 WebGL 的 `me3 + me2` 会让近平面方向反掉，「相机后方」的物体反而通过测试 |
| D56 | `Frustum.planes` 是长度 6 的 JS 数组 | `Vector.<Plane>` | 引擎全局：JS 数组 → `Vector`（D-index），避免装箱与运行期长度漂移 |
| D57 | `Frustum` 另有 `intersectsSprite`（按 sprite 的屏幕矩形扩大球）与 `setFromProjectionMatrix(m, coordinateSystem, reversedDepth)` 的 `reversedDepth` 分支 | 都不移植 | 本引擎没有 `Sprite`；reversed depth 不是本后端的目标形态。留着未验证的分支比缺一个方法更危险 |
| — | `intersectsObject` 用 `geometry.boundingSphere`，未算过就先 `computeBoundingSphere()`（`Frustum.js:146-164`） | 同：`_sphere.copy(geometry.boundingSphere).applyMatrix4(object.matrixWorld)` 后再测 | **坑**：`Sphere(center, radius)` 存的是 `center` 的**引用**。直接对 `geometry.boundingSphere.center` 做 `applyMatrix4` 会把局部包围球改成世界空间的，后续对同一几何复用的剔除/求交全部错位。必须先 `copy()` 到临时球 |

**验收**：`apps/geometry-m11/` 把 40 个盒子堆在 `x=±45` 的两面竖墙（frustum 在该深度的半宽约 26，
所以它们是被**左/右平面**拒绝的，而不是远平面裁剪——远平面在 200，关掉剔除它们会画到视口外），
计数稳定输出 `drawCalls=17 / triangles=5428 / culled=40`；`FRUSTUM_CULLING` 常量做 A/B：关掉后
`culled` 归零、画面像素完全不变（它们在视口外）。

### 16.5 `mergeGeometries`（`kit/asaot/three/utils/BufferGeometryUtils.as`）

| # | 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D64 | three.js 用 `Object.keys(attributes)` 且 JS 对象 key 有插入序 | `BufferGeometry.attributeNames` 显式维护**插入序**的 key 列表（首次赋值时追加，`deleteAttribute` 时同步移除） | as-aot 的 `Dictionary` 没有遍历序。`mergeGeometries` 要按「第一个几何的属性名顺序」去第二个几何里找同名属性，顺序本身不参与语义，但**没有稳定顺序就无法断言「属性组相同」**——两次遍历得到不同顺序会让比较假阳性 |
| D65 | 不兼容时 `console.error` + 返回 `null`（混合 indexed/非 indexed、属性名集不同、同名不同 itemSize） | 同契约，输出走 `trace`（AIR 里没有 console） | 引擎里没有比 `trace` 更合适的诊断出口；契约（返回 null、说明原因）与 three.js 完全一致 |

### 16.6 M11 顺带修掉的阴影 bug：片元必须在阴影盒内才比较

M7 的阴影采样直接拿 `fs4` 的 texel 和当前深度比。方向光 shadow camera 的默认 ortho 是 `±5`
（`DirectionalLightShadow.js:29`），一旦场景比它宽（M11 的画廊约 13 单位），盒外的片元会采到
**clamp-to-border** 的边界 texel，比较结果恒为「被遮挡」——整片区域平白变黑。

**R21**：按 `u ∈ [0,1] && v ∈ [0,1] && z ∈ [0,1]` 三条件判断是否在阴影盒内，盒外直接给满光：
`inFrustum = step(0,u)·step(u,1)·…`，最终 `shadow = max(shadow, 1 - inFrustum)`。这与 three.js
`getShadow` 里 `frustumTest`（`shadowmap_pars_fragment.glsl.js` 的 `shadowCoord` 越界返回 1.0）同语义。

> 顺带说明**为什么 M11 demo 里 `castShadow=false`**：画廊这一排没有地面/受影面，而默认 `±5` 的
> 阴影盒装不下 13 单位宽的一排物体，开了只会得到「远处物体一半黑」。阴影盒适配、PCF、normalBias
> 属 M13 范围，不在这里用调参凑。

### 16.7 顺带修掉的 M7 demo bug：`shadow.bias` 的符号反了

M11 的回归截图（`apps/shadow-m7/`）暴露出地面与立方体表面全是斜向条纹——是典型的 **shadow acne**（表面
和自己比较）。根因不在渲染器，在 demo：

- `fc9.x` 被 **加到片元的阴影空间深度上**，再和采样深度比 `sample >= depth + bias`。所以**正的 bias 让
  片元更可能被判为被遮挡**，那是「制造 acne」，不是治 acne。three.js 的通用配方是
  `shadow.bias = -0.0005`（**负号**：把表面朝光源方向抬一点）。M7 的 demo 写的是 `+0.0005`。
- 需要多大是**深度编码决定**的，不是口味问题：阴影图把 [0,1] 深度存进 8-bit 颜色通道（R11），本 demo 的
  阴影相机 `near=0.5 / far=30` ⇒ 一个深度台阶 = `29.5/255 = 0.116` 世界单位。小于一个台阶的 bias
  无法把地面与自身分开，只能得到条纹。

改为 `-0.004`（≈1.2 个台阶）后条纹消失、立方体的接触阴影仍然贴地（A/B：`temp/regress_shadow_m7*.png`）。
**8-bit 深度是这条限制的源头**，真正的解法（深度打包到 RG 两通道 / 更大 shadow map / `normalBias`）
归 M13。

### 16.8 M11 明确不落（登记遗留）

`ShapeGeometry`/`ExtrudeGeometry`/`TextGeometry`/`PolyhedronGeometry`/`TorusKnotGeometry`/
`CapsuleGeometry`/`RingGeometry` 的 `detail` 级细分；曲线族的 `QuadraticBezierCurve3`/
`CubicBezierCurve3`/`SplineCurve`/`CurvePath`/`Path`/`Shape`；`Line`（连续折线，只做 `LineSegments`）；
线宽 >1 的**设备像素**语义（Stage3D 没有真线宽，我们的 2 像素是屏幕空间近似）；`LOD`/`InstancedMesh`；
阴影盒自动适配视锥（M13）；8-bit 深度编码（M13 的 depth-pack / `normalBias`）。
另外登记一条**分层副作用**：M11 的 `Frustum.intersectsObject(object:Mesh)` 与 `Box3.expandByObject(object:Object3D)`
需要 `core` → `objects` 的引用（three.js 同样在 math 层读 `object.geometry`），因此 **`kit/` 不再能只编译
`math+core` 子集**——探针的编译命令统一改成 `$(find kit -name '*.as')` 全量 sweep（各探针头部的「Run from」段已同步）。

---

## 17. 动画 / 蒙皮 / 形变（D66–D87、R22，2026-10-31 M12 拍板）

M12 的形态与 M6–M11 有本质区别：**动画是纯 CPU 的时间求值 + 属性写入**，不新增任何 AGAL 通路。
所有新代码在 `kit/asaot/three/animation/`、`kit/asaot/three/objects/{Bone,Skeleton,SkinnedMesh}.as`
与 `Mesh` 的形变段，渲染器只增加**一个调用点**（R22）。

### 17.1 动画核心（`kit/asaot/three/animation/`，17 文件）

时间轴分层照 r187：`Interpolant`（按 key 时间定位 + 段内插值）→ `KeyframeTrack`（一条属性的关键帧 +
插值方式选择）→ `AnimationClip`（多条轨道 + 时长）→ `AnimationAction`（一次播放实例：
权重/时间缩放/循环/淡入淡出）→ `AnimationMixer`（时钟 + 轨道绑定 + 双缓冲累加器）。

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D66 | `AnimationUtils.flattenJSON` 把 ObjectLoader 的旧式 JSON 轨道（`{ times, values }` 数组嵌套）压平成平铺缓冲 | **不借** | 那是 io_three 时代 `AnimationClip.parse` 的输入形态；本 kit 的 `ObjectLoader` 只做静态场景图（§6），glTF 直接给平铺 accessor。留着这条通路等于维护一个没有输入源的分支 |
| D67 | 轨道缓冲是 TypedArray，`PropertyMixer` 把 `interpolant.resultBuffer` **别名**到自己的 incoming 区段（零拷贝） | 每份缓冲都是自有 `Vector.<Number>`，`convertArray` 一律拷贝；mixer 直接持有插值器自己的结果向量 | AS3 没有 ArrayBuffer 的**视图**概念，无法让两个不同长度/偏移的 Vector 共享同一段内存。改成「引用结果向量」后语义等价、也没有别名风险（多一次 `for` 拷贝，量级是每条轨道每帧几个 double） |
| D68 | `Interpolant.evaluate` 用 `t1 === undefined` 判「超出末端」 | 区间搜索显式比较 `i1 >= n` | `Vector.<Number>` 越界是**抛异常**，不是给 `undefined`。用哨兵会在正常路径上抛错 |
| D69 | 重复 key 时间（`t1 == t0`）时 `(t - t0)/(t1 - t0)` = 0/0 = NaN，NaN 顺着矩阵污染整个变换 | 退化区间直接 `copySampleValue(i1)`（取段末样本） | NaN 位姿的现场表现是「物体凭空消失/整屏发黑」，排查成本极高；三点关键帧里重复时间是手工数据的常见笔误 |
| D70 | `setInterpolation` 把 `this.createInterpolant` 重新指向 `InterpolantFactoryMethodLinear` 等**方法指针**，靠实例级方法替换分派 | 一个 `int` 选择器（`InterpolateLinear` 等）+ `_createInterpolant()` 可覆盖方法 | AS3 不能在实例上换绑方法。`int` 选择器对 AOT 也更友好（采样热路径上是一次整数比较，不是函数值调用） |
| D71 | `KeyframeTrack.toJSON` / `optimize()`（丢冗余关键帧） | **不借** | 本 kit 没有序列化出口；`optimize()` 会改动用户给的关键帧，调试期反而掩盖数据问题 |
| D72 | `times` 可为数字或字符串数组；`BooleanKeyframeTrack` 的 values 是 0/1 | `times` 恒为 `Vector.<Number>`；布尔值存 0/1；`BooleanKeyframeTrack` 只允许 Discrete | `Vector.<Number>` 装不了字符串；布尔轨道插值没有意义（three.js 同样在 `validate()` 里只接受 Discrete） |
| D73 | `Composite` binding（把一条轨道扇出到 `AnimationObjectGroup` 的每个成员） | **不借** | 它服务的对象组（同材质多实例批量播放）本 kit 没有；留着就是一条永远走不到的绑定类型 |
| D74 | `bindingType` / `versioning` 是**函数指针表**（`_getValue_direct` / `_getValue_array` / `_setValue_*`） | `int` 常量 + `switch` | 同 D70：无实例级方法替换；四个绑定类型的分支体本来就只有几行 |
| D75 | 绑定失败时 three.js 的 `bind()` 把 `getValue/setValue` 指向空函数（`_getValue_unavailable`），于是「名字写错」表现为「动画安静地不生效」 | `bindingType = INVALID`，`AnimationMixer._bindAction` **直接抛错**并点名 track | 静默 no-op 是这类系统最难查的故障形态（读者会以为是 mixin 权重或插值错了）。宁可一进就崩 |
| D76 | `AdditiveAnimationBlendMode`（叠加混合）需要 `addAccu` 区段 + `accumulateAdditive` / `applyAdditive` / 三种 `_setAdditiveIdentity*` | **不借** | 叠加混合的用途是「上半身叠加在跑步循环上」这类分层动画，M12 的验收范围是单层播放 + 交叉淡入淡出。省掉的一整块缓冲也避免了「区域偏移算错但看起来像动画」的隐性 bug |
| D77 | `AnimationClip.CreateFromMorphTargetSequence` / `CreateClipsFromMorphTargetSequences`（把 `morphTarget0..N` 命名约定烘成帧动画） | **不借** | glTF 给的是真 `animations`；命名约定只出现在 `ObjectLoader` 时代的手工资产里 |
| D78 | `blendMode` 是 `NormalAnimationBlendMode` / `AdditiveAnimationBlendMode` 常量 | 字段保留为 `int`（2500/2501），但只有 normal 生效 | 保留字段是为了让 glTF/用户代码能照写；真正实现 additive 需要 D76 的整块设施 |
| D79 | `AnimationMixer` 继承 `EventDispatcher`，派发 `'loop'` / `'finished'` | mixer 上的可选 `onLoop(action, loopDelta)` / `onFinished(action, direction)` `Function` 字段 | 本 kit 没有 EventDispatcher（同 asaotui 口径）；`Function` 字段承载同样的信息与顺序，且只有一个全局汇 |
| D80 | `warp(startTimeScale, endTimeScale, duration)` / `halt(duration)`（时间缩放做渐变） | **不借** | 这是 HaltingProblem 式速度斜坡；M12 需要的是 `fadeIn`/`fadeOut`（权重渐变），已落地 |
| D81 | `AnimationMixer` 把 action 分成 active/inactive 两组，按 `_cacheIndex` 复用槽位，binding 用 `_addInactiveBinding` 池化 | action / PropertyMixer 在整个生命周期内保持引用（`Vector` 查找） | 池化的目的是「每帧大量 action 反复启停时的分配压力」；demo 量级是个位数 action。**可观测行为完全一致**，差的只是分配形态（登记为已知取舍，不是 bug） |
| D82 | `uncacheClip` / `uncacheRoot` / `uncacheAction`（把已不用的 action/binding 从缓存摘掉） | **不借** | 场景内的 clip 集合是有限的常量；没有卸载资产的通路，就没有释放缓存的需求 |
| D83 | — | 轨道绑不上 = 硬错（见 D75），错误文案点名 `track.name` 与 `root.name` | 与 D75 是同一决策的两面：探针要能钉「错误必须可定位」 |
| D87 | `GLTFLoader` 为 CUBICSPLINE 单独定义 `GLTFCubicSplineInterpolant` / `GLTFCubicSplineQuaternionInterpolant`，并在 `loadAnimation` 里**逐轨道**重指 `createInterpolant`（`GLTFLoader.js:2181`/`:2253` 定义，`:4205` 装配） | `KeyframeTrack.InterpolateCubicSpline = 2303`（本 kit 自定常量，glTF 专用）+ `_createCubicSplineInterpolant()` 可覆盖方法；`QuaternionKeyframeTrack` 覆盖成四元数变体 | 同 D70：不能逐实例换绑方法，只能再加一个选择器分支。`getValueStride()` 返回 `getValueSize()/3`（每帧存 `[入切线, 顶点, 出切线]` 三元组），mixer 的 `PropertyMixer` 与结果缓冲都按 stride 分配，而不是按 valueSize |

### 17.2 采样口径（`Interpolant` 家族）

| 插值 | 出处 | 语义要点 |
|---|---|---|
| Discrete | `Interpolant.js:269` | 段内恒取段首样本（`t` 恰为段末时进下一段 → 取下一段首样本） |
| Linear | `Interpolant.js` 基类 + `LinearInterpolant` | 段内 `lerp`，`w = (t - t0) / (t1 - t0)` |
| QuaternionLinear | `QuaternionLinearInterpolant` | 对 4 元组做 `slerpFlat`（不构造 Quaternion 对象，直接分量运算，避免每条轨道每帧分配） |
| Cubic | `CubicInterpolant.js` | Catmull-Rom 式 Hermite，切线由**邻点差分**导出，末端按 `_interpolantSettings` 的 `endingStart/endingEnd`（`zero` / `constant`）退化 |
| CUBICSPLINE | `GLTFLoader.js:2181` | 切线**存在数据里**（前一段的出切线、后一段的入切线），Hermite 基函数乘上段长 |

**二进制与口径**：`getValueSize()` 由 `ValueTypeName` 决定（`number`=1、`vector`=3、`quaternion`=4、`color`=3、`bool`=1）；
`values.length` 必须是 `times.length × valueSize`（CUBICSPLINE 是 `× valueSize × 3`），`validate()` 会检查并抛错。

### 17.3 绑定语法（`PropertyBinding`）

`parseTrackName` 照搬 r187 `PropertyBinding.js:209` 的文法：

```
trackName   = nodeName '.' objectName '[' index ']' '.' propertyName
nodeName    = 任意不含 '.' 的标识符（或 uuid）
objectName  = material | materials | bones | map     ← 白名单，用于消歧 foo.bar.baz
```

白名单的存在理由：`A.b.c` 既可能是「节点 A 的材质 b 的 c」，也可能是「节点 A 的 b 属性的三号分量」。
只有 `material`/`materials`/`bones`/`map` 这四个位置可以继续向下取属性，其余一律按「属性名」收尾
（与 three.js 完全一致，不是简化）。

`findNode`（`PropertyBinding.js:266`）的查找顺序：①根节点自己 → ②`getObjectByName` 递归子树 →
③skeleton 的骨头名 → ④uuid。glTF 的节点名经 `sanitizeNodeName` 清洗（空格→`_`，`[] . : /` 丢弃）
并对重名加后缀（`createUniqueName`），所以 `Hips.quaternion` 这类轨道名能稳定命中。

### 17.4 形变与蒙皮：为什么放在 CPU（D84–D86、R22）

**这是 M12 唯一无法照抄的形态，也是全篇最重要的取舍。**

three.js 的 morph 与 skinning 都在**顶点着色器**里做：

- morph：`morphTargetInfluences[]` 决定每个目标属性的权重，逐顶点求和（`morphtarget_vertex.glsl.js`）。
- skinning：`skinIndex`/`skinWeight` 是**逐顶点**属性，着色器用**相对常量寻址**（`vc[a0.x]`）从骨骼矩阵调色板里
  按顶点自己的骨骼下标取 4 个矩阵（`skinning_vertex.glsl.js`）。

本后端两条路都堵死：

1. AGAL 翻译器不支持**常量表的动态下标**——`vc[a0.x]` 这类相对寻址不会被翻译成任何东西；
2. Stage3D 没有 float 纹理格式，无法把调色板放进纹理再 `tex` 采样（另一条常见替代路）。

所以 `SkinnedMesh.updateDeform()` / `Mesh.updateDeform()` 在 CPU 上跑**与着色器同一套算术**，再把结果写回几何的
`position`/`normal` 属性（`needsUpdate` → 版本号变 → 下一帧重传顶点缓冲）。

| # | 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D84 | morph + skinning 在 GPU，零 CPU 成本 | CPU 逐顶点：morph 先、skinning 后（与 three.js 的 chunk 顺序一致），结果写回属性 | 见上：无相对常量寻址；骨矩阵贴图只能落在 `RGBA_HALF_FLOAT`（16F，且仅 opt-in `standard` 档）上，精度不足（§36）。代价是每帧 `O(顶点数 × 影响数)`；M12 demo 的鞭子 330 顶点 × 4 影响 = 1320 次矩阵-向量乘，单帧约 0.1 ms 量级，可接受。**大规模角色（5 万顶点）会明显变慢**，这条限制登记在 §17.8 |
| D85 | `Skeleton.boneTexture` + `computeBoneTexture()`（把调色板烘成 DataTexture 供着色器采样） | **不借**（`boneTexture` 字段与 `computeBoneTexture` 都不存在） | 没有 float 纹理，烘了也采不了；留一个字段会让人以为 GPU 路径可用 |
| D86 | `boneMatrices` 是 `Float32Array` | `Vector.<Number>` | 同 D67 |
| R22 | 渲染器在 `renderObject` 里按对象逐帧 `mesh.updateDeform(frameId)` | `AGALRenderer._frameId` 每帧自增；`updateDeform` 用 `_deformFrame` 去重 | 同一帧里阴影 prepass 与主 pass 都会碰同一个 mesh，没去重就白算两遍（且 prepass 必须拿到**已摆好姿势**的顶点，否则阴影是绑定姿态的）。放在 `position.version` 检查**之前**，重传自然带上本帧形变 |

`bind()` 的语义照 `SkinnedMesh.js:230`：`bindMode=attached` 时 `bindMatrixInverse` 每帧由 `matrixWorld` 重算
（`updateMatrixWorld` 里），`detached` 时恒为 `bindMatrix` 的逆。glTF 加载器用**单位** bind matrix 绑骨
（glTF 的 `inverseBindMatrices` 已经把「网格空间 ↔ 骨骼空间」烘进去了），并调 `normalizeSkinWeights()`
——导出器给的权重常常不归一到 1，不归一化会让网格整体朝原点缩。

**蒙皮算术**（`applyBoneTransform`，`SkinnedMesh.js:213` 的 CPU 参考实现，探针直接钉它）：

```
base  = bindMatrix · position
out   = bindMatrixInverse · Σ_j  w_j · (bone_j.matrixWorld · boneInverse_j) · base
```

### 17.5 GLTFLoader 的 M12 扩展

| 借什么 | 出处 | 落地 |
|---|---|---|
| `skins`（`joints` + `inverseBindMatrices`）→ `Skeleton` | `GLTFLoader.js:4133`(loadSkin)/`:2830`(skin 依赖前置) | `_loadSkin()`：`inverseBindMatrices` accessor → `Vector.<Matrix4>`；缺失时按 `Skeleton.calculateInverses()` 语义取骨骼世界矩阵的逆 |
| `animations`（`channels` + `samplers`）→ `AnimationClip` | `GLTFLoader.js:4205`(loadAnimation) | `_loadAnimation()`：`path` → `position`/`quaternion`/`scale`/`morphTargetInfluences[n]`，`interpolation` → 2300/2301/2302/2303，装配成 `VectorKeyframeTrack`/`QuaternionKeyframeTrack`/`NumberKeyframeTrack` |
| `JOINTS_0`/`WEIGHTS_0` → `skinIndex`/`skinWeight` | `GLTFLoader.js:2339-2340` | accessor 解析后落到同名属性（4 分量），权重归一化 |
| primitive `targets` + `mesh.weights` → `morphAttributes` + `morphTargetInfluences` | `GLTFLoader.js:2513`(morphTargetsRelative=true) | 目标属性不可变，`relative=true`（glTF 的 delta 语义）；`mesh.weights` 作为初值 |
| 节点名清洗与去重 | `GLTFLoader.js:3838`(createUniqueName)/`:3840`(sanitizeNodeName) | 加载期一次做完，`PropertyBinding.findNode` 才能按名字找骨头 |
| 第二遍 `_attachSkins()` | 无对应物 | three.js 靠 Promise DAG 让 `loadSkin` 等节点图建好；我们没有异步依赖图（D40 已定的「缓冲解析完同步建图」），于是在**节点树建好后**再扫一遍带 `skin` 的节点去 bind + 归一化权重 |

**验收锚点**：demo `apps/animation-m12/` 的 `diag:` 行打印 `actions=3 bones=6 tentacleVerts=330 tentacleTris=640`，
三个 action 分别驱动位置（方块旋转/升降）、四元数（鞭 6 节）、形变权重（球）。

### 17.6 验收（`probes/animation-smoke-m12/`，110 项 ALL PASS）

探针不调用被测类去算期望值，而是**独立重算**参考值再比对，覆盖：

- 五种插值器的段内值与边界（段首/段中/末键/超出末键钳制；退化区间取段末）；
- `PropertyBinding` 文法：白名单消歧（`A.material.roughness` vs `A.b.morphTargetInfluences[0]`）、数组下标、
  uuid 查找、骨头名查找、非法名的 `INVALID`；
- `PropertyMixer` 累加：单 action 权重 1 / 两个 action 各 0.5 的 lerp 与 slerp 口径 / 总权重 < 1 时向原值回混；
- `AnimationAction` 状态机：`LoopOnce` 停在末帧并派发 `onFinished`、`LoopRepeat` 的 wrap 与 `onLoop`、
  `LoopPingPong` 的时间反演、`fadeIn`/`fadeOut` 的权重曲线；
- `AnimationMixer` 双缓冲：连续两帧 `_accuIndex` 交替、`stop()` 恢复原姿势（`restoreOriginalState`）；
- glTF CUBICSPLINE：三元组 stride、Hermite 基函数在中点的数值锚点、四元数变体的归一化；
- 蒙皮：单骨（权重 1）与双骨（0.5/0.5）的顶点位置、`normalizeSkinWeights` 把 (2,2) 归一成 (0.5,0.5)、
  绑在 `bindMatrix` 上的旋转；
- morph：相对目标加权求和、绝对目标 `mix`、`updateMorphTargets` 建立名字字典。

**demo 的 A/B 证据**（不是「看着像在动」）：`frame 60` 与 `frame 120` 的两行日志互为对照——

| 观测量 | frame 60（t=1s） | frame 120（t=2s） | 说明 |
|---|---|---|---|
| `carouselY` | 0.95 | 0.45 | 位置轨道的线性插值 |
| `tip`（鞭尖世界坐标） | (0.187, 3, 0) | (1.4017, 2.3192, 0) | 四元数轨道 + 6 节骨骼链累积 |
| `skinChecksum` | 865.991 | 1061.9015 | 蒙皮后顶点缓冲的加权校验和（改变 ⇒ 缓冲真被重写） |
| `bindChecksum` | 865.991 | 865.991 | 绑定姿态基线（不变 ⇒ 形变是幂等的、没有累积漂移） |
| `morphRadius` | 1.36 | 0.72 | 形变球某中纬顶点的半径（权重 1 ↔ 0） |
| `drawCalls` / `triangles` | 5 / 2826 | 5 / 2826 | 形变不改变拓扑，只有顶点缓冲内容变 |

> **探针口径的一处修正**：形变的「全缓冲加权校验和」几乎不随权重变化（M12 首版就用它，两帧都印 -22.745）。
> 原因不是 bug——形变增量是 3 瓣对称法线场，与按 `i % 7` 取的权重近似正交，求和后抵消到 1e-12 量级。
> 改用**单个中纬顶点半径**后信号清晰（0.72 ↔ 1.36）。形变量必须选对观测量，否则「没有变化」会被误读成「形变没生效」。

### 17.7 指令预算

M12 **不新增任何 AGAL 程序**，也不改动标准片元：morph/skinning 全在 CPU，绑定与插值不碰 GPU。
实测 demo 两个变体仍为 **182/400**（含阴影）/ **163/400**（无阴影），与 M11 逐字节一致——这是 D84 的直接收益。

### 17.8 M12 明确不落（登记遗留）

- **GPU 蒙皮 / GPU morph**（D84）：需要相对常量寻址或 float 纹理，本后端都没有。
- `boneTexture` / `computeBoneTexture`（D85）、`SkeletonHelper`、`AnimationHelper`。
- 叠加混合 `AdditiveAnimationBlendMode`（D76）、`warp`/`halt`（D80）、`Composite` 绑定 / `AnimationObjectGroup`（D73）。
- `uncacheClip` / `uncacheRoot` / `uncacheAction`（D82）、`AnimationUtils.flattenJSON`（D66）、
  `AnimationClip.toJSON` / `KeyframeTrack.toJSON` / `optimize()`（D71）。
- `AnimationClip.CreateFromMorphTargetSequence`（D77）、`CCDIKSolver` / `SkeletonUtils.retarget` 等 examples 级工具。
- `morphNormals` 的**独立权重**（three.js 有 `normal` 目标与 `position` 目标同权重的约定；本 kit 同权重求和）。
- `SkinnedMesh.raycast` / `computeBoundingBox`/`computeBoundingSphere` 的世界空间版本（M14 的 `Raycaster` 一起做）。
- glTF 动画的 `KHR_animation_pointer`、`basisu`/Draco 压缩动画（前者依赖通用指针扩展，后者依赖解码器）。

---

## 18. 阴影质量：PCF / normalBias / 镂空 caster / 深度打包（D88–D93、R23–R24，2026-10-31 M13 拍板）

M7 的阴影是「单采样硬阴影 + 全场景当 caster + 8-bit 深度直存 R 通道」，能用但不可看：边缘锯齿、
曲面自阴影成条、镂空面板投出实心影子、`castShadow`/`receiveShadow` 只是摆设。M13 补齐这四件事，
并如实登记一条**预算红线**（一 draw 只能一张阴影图，D93）。

### 18.1 PCF：3×3 固定 9 抽头（D91、R24）

`LightShadow.radius` 的语义照 three.js：`radius` 是**阴影图像素**半径，世界半径 = `radius × texelSize`
（`shadowmap_pars_fragment.glsl.js:172-174` 的 `texelSize = 1 / shadowMapSize`、`radius = shadowRadius * texelSize`）。
默认 `1`（`LightShadow.js:87`），`DirectionalLightShadow` 继承之。

r187 的 PCF 路径是 **5 抽头 Vogel 盘 + 硬件线性 PCF**（每样 4 个过滤 tap，`:174-186`，注释写明
「Hardware PCF with LinearFilter gives us 4-tap filtering per sample」）。我们**不能**照抄：

- 阴影存储是 BGRA8 **颜色**目标（R11），不是 `sampler2DShadow`，没有硬件比较；
- 对它用 `linear` 会让采样器插值出**两个相邻 texel 的平均深度**——那是「不存在的几何表面」，
  既有假半影也会在掠射面制造痘。故 9 个 tap 全部 `nearest`（探针 D3/D4 钉死）。

实现全在 `AGALRenderer` 的三个公开静态成员里，便于无 GPU 探针覆盖：

| 成员 | 作用 |
|---|---|
| `PCF_TAPS = 9`、`pcfOffsets()` | 静态 3×3 tap 网格（−1..1 两轴），每次返回**独立副本**，渲染器只在 `_programsDirty` 时上传一次到 `fc27..fc35`（`PCF_OFFSET_BASE = 27`） |
| `pcfKernel(radius, w, h)` | 生成 `fc24 = (radius/w, radius/h, 1/9, 0)`；`radius ≤ 0` 退化成点采样，负数夹 0，过大夹到图幅 1/4，尺寸 0 不除零，各向异性图幅 x/y 分开 |
| `shadowFactorBlock(...)` | 生成一整段片元：坐标除 w、加 bias、夹到盒内、9 次 `tex`+`dp3`+`sge`、累加、平均、`receiveShadow` 混合 |

每 tap 6 条指令（`mul`/`add` 算偏移、`tex`、`dp3` 解包、`sge` 比较、`add` 累加）+ 22 条固定
= **76 条**（探针 D8 逐条计数，D9 真汇编 + 真翻译通过）。

### 18.2 `normalBias` 与 `bias` 的符号（D88）

three.js 把接收点**沿世界法线**推出去再投影：

```glsl
// shadowmap_vertex.glsl.js:33
shadowWorldPosition = worldPosition + vec4( shadowWorldNormal * directionalLightShadows[i].shadowNormalBias, 0 );
vDirectionalShadowCoord[i] = directionalShadowMatrix[i] * shadowWorldPosition;
```

我们照做：顶点阶段 `vt1` 存世界法线，`mul vt2, vt1, vc20.xxxx` + `add vt2, vt2, vt0` 后再乘阴影矩阵。
`normalBias` 默认 `0`（`LightShadow.js:74`）。

`bias` 的符号容易写反：r187 是 `shadowCoord.z += shadowBias`（非 reversed depth 分支，
`shadowmap_pars_fragment.glsl.js:162`），也就是**加到接收深度上**——值越大越容易被判成「在阴影里」，
所以**正 bias 是制造 acne，不是治疗**。M7 demo 曾写成 `+0.004`（M11 §16.7 修），M13 demo 用 `-0.002`。

### 18.3 16 位两字节深度打包（D89）

M7 直接把 [0,1] NDC z 写进颜色目标的 R 通道。8 位 = 1/255 台阶，M13 demo 的阴影相机跨 `0.5..40`，
一个台阶就是 **0.155 世界单位**——比整个 bias 预算还大，曲面必然成条自阴影（16-bit 之前无论怎么调
normalBias 都只是一圈圈换地方）。

three.js 用 `packDepthToRGBA`/`unpackRGBAToDepth` 把深度摊到 4 个字节（`packing.glsl.js:15-57`）。
我们用 2 个字节（够用即可，少 3 条指令）：`hi = floor(d·255)/255`、`lo = frac(d·255)`，
解包 `dot(texel.xyz, fc25.xyz)`，`fc25 = (1, 1/255, 0)`。误差 **1/65025 ≈ 0.0006 世界单位**，
比 8 位好 256 倍。

- 打包在 `AGALRenderer.packDepthSnippet(src, dst)`（`mul`/`frc`/`sub`/`mul` 四条），两个深度程序共用；
  `fc1 = (255, 1/255, 0, 1)` 随阴影 pass 上传一次。
- 清屏仍是 `(1,1,1,1)`：解包得 `1 + 1/255 ≈ 1.0039`，大于任何接收深度 ⇒ 背景永远「最远」，
  不会把没画东西的 texel 当成近处遮挡（若清成 (0,0,0,0) 则整屏全黑——探针 E 组与 demo 都锚了这一点）。

### 18.4 `castShadow` / `receiveShadow` 真生效（D88）

- **caster 侧**：shadow pass 只画 `mesh.castShadow == true`（对照 `WebGLShadowMap.js:528`
  `if ( object.castShadow || ( object.receiveShadow && type === VSMShadowMap ) )`）。M7 画全部可见
  mesh，等于把接收面也写进深度图，`castShadow = false` 毫无意义。
- **receiver 侧**：three.js 的 `receiveShadow` 是**每对象 uniform**（`lights_pars_begin.glsl.js:2`
  的 `uniform bool receiveShadow`，`lights_fragment_begin.glsl.js:197` 用它选 `getShadow(...)` 还是 `1.0`）。
  我们单程序多对象，uniform 换不了，于是用 `vc22.x`（每 draw 上传）+ 顶点 `mov v5, vc22.xxxx` 传成
  varying，片元把因子向 1 混合（`sub`/`mul`/`add` 三条）。语义等价：`receiveShadow = false` 的物体
  完全不受阴影影响。默认 `false`（`Object3D.receiveShadow`），与 three.js 一致。

### 18.5 `alphaTest` 镂空 caster（D90）

`AGALRenderer.shadowDepthKind(material, geometry)` 选路，对照 `WebGLShadowMap.js:447-448`
（`material.alphaMap && alphaTest > 0` / `material.map && alphaTest > 0` 才换专用深度材质）：

| 条件 | 深度程序 |
|---|---|
| `alphaTest > 0` 且几何有 `uv` | 镂空版：`tex` 取 base color 的 alpha → 乘 `opacity` → 减 `alphaTest` → `kil` |
| 其余（`alphaTest = 0`、无 uv、材质/几何为 null） | 纯深度版 |

**坑（M13 首版真踩）**：`BitmapData(w, h, transparent = false, ...)` 会把 alpha 强制成 255，
`setPixel32` 写 0 也无效——镂空面板照样投出实心影子。必须 `new BitmapData(w, h, true, 0x00000000)`。

### 18.6 一 draw 只能一张阴影图（D93，红线）

标准 PBR 片元的采样槽已被占满：`fs0` base color、`fs1` normal、`fs2` roughness、`fs3` metalness、
`fs4` shadow、`fs5` emissive、`fs6` AO、`fs7` environment cube。AGAL2 只有 8 个 sampler。

⇒ `MAX_DIR_LIGHTS = 2` 保留（两盏方向光都能照亮），但 `MAX_SHADOW_LIGHTS = 1`。第二盏方向光
**能亮不会投影**：`_secondLightBlock()` 只贡献辐照度，不乘任何阴影因子。M13 顺带删掉了第二张
阴影图的顶点块（`v5`/`vc16..vc19`/`vc21`）与片元 PCF 块，`fc25`/`fc26` 因此归还常量用途
（`fc25` = 深度解包因子）。

要突破这条红线，只有三条路：AGAL3+ 增加采样槽、把 AO/emissive 合并进 base color 的采样、
或落地 E6 原生 shader 直通（**第三条已在 M30 落地，看 §37**；前两条仍未做）。M13 当时把三条都
登记为遗留。

### 18.7 编译期 AGSL 校验（R23）

无效程序在 AOT 后端**不会**在 `upload` 报错，而是在 `drawTriangles` 变成
`draw failed: msg=null id=0` + `Uncaught exception: null`——没有行号、没有 opcode，纯猜。
`_validateAgsl(stage, assembler, dirs, shadows)` 现在在 `Program3D.upload` 之前调
`AGALTranslator.translate(code, "msl")`，失败即抛：

```
AGALRenderer: vertex program rejected (dirs=1, shadows=1): AGAL: vt2 is read before it is written
```

### 18.8 顶点临时寄存器必须整寄存器写（R24）

阴影空间偏移最初写成 `mul vt2.xyz, vt1.xyz, vc20.xxx` + `add vt2.xyz, vt2.xyz, vt0.xyz`，
随后 `dp4 v4.x, vt2, vc12` 读**整个** `vt2` —— 翻译器判定「`vt2` 在读之前未写全」并拒绝整个程序
（就是 §18.7 抓到的那条）。改成整寄存器 + 广播标量：

```
mul vt2, vt1, vc20.xxxx      // w 通道也被写：vc20.w = 0，vt1.w = 0
add vt2, vt2, vt0            // vt0.w = 1 ⇒ vt2.w = 1，后续 dp4 得到正确的齐次 w
```

这条对所有顶点临时寄存器成立：**偏写 + 全读 = 程序被判无效**，不是「未定义行为」而是**硬拒绝**。

### 18.9 验收

**探针** `probes/shadow-smoke-m13/ShadowSmokeM13.as`：**47 项 ALL PASS**。覆盖
`DirectionalLightShadow` 的 PCF 默认值与可写性、`MAX_DIR_LIGHTS`/`MAX_SHADOW_LIGHTS`/`PCF_TAPS`/
`PCF_OFFSET_BASE` 四个常量、`castsShadow(...)` 规则、9 tap 网格几何与「每次返回独立副本」、
snippet 结构（一 tap 一 `tex`、全 `fs4`、全 `nearest`、无 `linear`、因子停在 `.w`、每 tap 一个
`dp3` 解包、`receiveShadow` 混合存在）、snippet 行数 76 与真汇编后的 84 条指令、`pcfKernel` 的
六个边界（radius 1 一个 texel / 0 退化点采样 / 负数夹 0 / 过大夹 1/4 图幅 / 各向异性 x·y 分离 /
尺寸 0 不除零）、`shadowDepthKind` 的五种选路。

**demo** `apps/shadow-m13/`：地面（receiver）+ 旋转环面（曲面 acne 用例，cast+receive）+
悬空镂空薄板（`alphaTest = 0.5`，cast+receive）+ 暖色 key（`castShadow=true`，`radius=2`、
`normalBias=0.02`、`bias=-0.002`）+ 冷色 fill（`castShadow=false`）。

A/B 证据（**同一相机、同一姿势**，用 `ANIMATE=false` 冻结转台；参照系是同一场景 `castShadow=false` 的渲染）：

| 观测量 | 值 | 结论 |
|---|---|---|
| 环面阴影半影占比（`radius=0` → `radius=2`） | 0.0% → 19.3%（1944 个部分遮挡像素） | PCF 真的在多采样，而不是只把边缘抖一下 |
| 环面被错误自阴影的像素占比（`normalBias=0`） | 34.5%（平均压暗 6.14/255） | 无 normalBias 时曲面成片 acne |
| 同上（`normalBias=0.02`、`bias=0`） | 14.1%（平均压暗 2.96） | 只补 normalBias 不够，深度仍需偏移 |
| 同上（`normalBias=0.02`、`bias=-0.002`，即 demo 取值） | **2.6%**（平均压暗 1.57） | 余下的是真自遮挡与半影，不是 acne |
| 镂空薄板投影 | 4 个窗口透光（截图 `temp/m13-hero3.png` 起） | alpha caster 生效；首版整块实心是 BitmapData 无 alpha（§18.5） |
| 两盏方向光 | 冷光把阴影侧提亮，但只有 key 投影 | D93 的采样预算红线 |

**指令预算**（`_validateAgsl` 顺带打印）：

| 变体 | 指令数 |
|---|---|
| 一方向光、零阴影 | 163/400（M12 同值，未新增） |
| 两方向光、零阴影 | 222/400 |
| 一方向光 + 一张阴影图（M7 demo） | 241/400 |
| 两方向光 + 一张阴影图（M13 demo） | **300/400**（余 100） |

其中阴影块 76 条（9×6 + 22），M7 的硬阴影块是 12 条 —— 每张阴影图贵了 64 条，仍留 25% 余量。

### 18.10 M13 明确不落（登记遗留）

- `SHADOWMAP_TYPE_VSM` / `SHADOWMAP_TYPE_PCF_SOFT`（`shadowmap_pars_fragment.glsl.js:195/:262`）：
  VSM 需 float 目标存二阶矩，PSOF 需可分离的大核采样；都超出 400 指令/8 采样槽。
- `shadow.intensity`（r187 的 `mix(1.0, shadow, shadowIntensity)`，`:190`）：字段恒 1，接的话每个
  tap 多一条 lerp；真要弱阴影，现阶段用补光的 `intensity` 模拟。
- `object.customDepthMaterial` / `customDistanceMaterial`（`WebGLShadowMap.js:435`）。
- 点光/聚光阴影（`PointLightShadow` 需 cube 阴影图、`SpotLightShadow` 需第二张 2D 图）：采样槽不够（D93）。
- 级联阴影 CSM / `light.shadow.autoUpdate` / `needsUpdate` 手动刷新：每帧重建整张图，不缓存。
- `shadow.mapSize` 上限提醒：512 是默认，1024 仍可用（每 tap 常数不变），但 8-bit 深度打包后的
  精度优势在 2048 上会被 texel 覆盖率稀释；未做实测断言，不写「支持」。
- caster 的视锥剔除：shadow pass 不跑 `Frustum` 测试，`castShadow` 物体全画（多一次 draw，代价可接受）。

---

## 19. 交互：射线拾取 + 轨道相机（D94–D100、R25–R26，2026-10-31 M14 拍板）

M14 落两件事：**点得中**（Ray → Raycaster → Mesh.raycast）与**转得动**（OrbitControls）。
两者都是**纯 CPU 侧**的代码：不新增 draw call、不改 AGAL，因此 §18.9 的指令预算原样不动
（一方向光 163/400、两方向光 + 一张阴影图 300/400，M14 demo 复测同值）。

### 19.1 拾取链路（`math/Ray` → `core/Raycaster` → `objects/Mesh.raycast`）

| 层 | 文件 | 职责 | three.js 出处 |
|---|---|---|---|
| 射线 | `kit/asaot/three/math/Ray.as` | `at/lookAt/recast/distanceToPoint/distanceSqToPoint/intersectSphere/intersectsSphere/distanceToPlane/intersectPlane/intersectBox/intersectsBox/intersectTriangle/applyMatrix4/equals` | `Ray.js:78/:90/:104/:141/:153/:307/:345/:360/:395/:449/:521/:538/:671` |
| 驱动 | `kit/asaot/three/core/Raycaster.as` | `setFromCamera`（透视/正交两分支）、`setFromPointer`（AIR 桥）、`intersectObject(s)`、`sortByDistance` | `Raycaster.js:119/:200/:220/:248` |
| 三角 | `kit/asaot/three/math/Triangle.as` | `getNormal/getBarycoord/isFrontFacing` | `Triangle.js:66/:94/:223` |
| 命中 | `kit/asaot/three/core/Mesh.as` | `raycast` + `getVertexPosition`，逐三角形 | `Mesh.js:246/:292/:429/:459/:505` |

**顺序不是随便排的**（`Mesh.js:246` 的早退阶梯，照抄）：

1. `geometry.boundingSphere` 世界化后**先试球**：`recast(near)` 后的原点若在球内直接放行，
   否则求交点、并用 `(far-near)²` 截断。这一步让「射线离网格一米远」的 10 万三角形网格
   不必进三角形循环（否则每次指针移动都白跑）。
2. 用 `matrixWorld.invert()` 把射线搬到**局部空间**；局部 AABB（`boundingBox`）再早退。
   局部空间是关键：一个 geometry 被多个 Mesh 复用时，只有局部化才能只写一份循环。
3. 按 `drawRange` 遍历三角形（`count = -1` 是「到底」的哨兵，D7）；索引/非索引两分支。
4. 每个三角形按 `material.side` 决定绕序：`BackSide` 用 `(pC,pB,pA)` 反向 + `backfaceCulling=true`
   （`Mesh.js:433-439`）。**这一条决定「盒子里看得见内壁」能不能被点中**；漏了它，
   从外面点一个 `BackSide` 盒子会点到近面（本该点远面/内壁）。
5. 命中后：世界点、**世界距离**（`Mesh.js:448` 用的是世界点到 `raycaster.ray.origin`，不是局部点）、
   `near/far` 窗口、重心坐标插值 uv 与 normal（法线朝射线一侧翻正，`Mesh.js:487-493`）、
   几何面法线、`faceIndex`（= 三角形序号，索引/非索引一致）。
6. `intersectObject(s)` 后**稳定**按距离升序：用插入排序而不是 `Vector.sort`，因为 AOT 运行时的
   `Vector.sort` 不保证稳定，而 three.js 依赖 `Array.sort` 的稳定性（同距离并列时按遍历顺序）。
   C24/C25 钉的就是这条。

**共享边的双命中是特性，不是 bug**：`Ray.js:538` 的 Möller–Trumbore 变体做了 watertight
（剪切投影 + 符号判定），射线**正好**沿两个三角形的公共边时两者都报（C19 用一个过盒面对角线
的射线钉住：2 个命中、距离相同）。所有其它用例都刻意让射线偏离对角/公共边，否则「命中 1 个」
这种断言会因为这条特性随机变成 2 个 —— 探针里 C1/C12/C18/C36 的射线都带 0.3/0.2 的偏移，
注释写明了原因。

### 19.2 AIR 指针桥（D95）

three.js 从 DOM 指针事件拿 NDC（`Pointer.js` 的 `setPointer`）。AIR 里没有 DOM，指针位置是
`MouseEvent.stageX/stageY`（像素，原点左上、y 向下）。桥只有两个函数：

- `Pointer.toNDC(x, y, width, height, out)`：`x = (px/w)·2 − 1`，`y = −(py/h)·2 + 1`；
  `w/h ≤ 0` 时**不除零**，直接给 `(0,0)`（B4：尺寸为 0 的一帧仍要给出有限值，否则 NaN 一旦
  进 `unproject` 就污染整条射线）。
- `Raycaster.setFromPointer(x, y, width, height, camera)`：唯一的 y 翻转点。放这里而不是各调用点，
  是为了「点击」与「拖拽」对「上」的理解**逐位一致**（19.4 的事件桥只负责搬像素）。

`setFromCamera` 的两个分支照抄 `Raycaster.js:119`：透视在 NDC z=0.5 反投影、原点取相机世界位置、
方向 = 反投影点 − 原点后归一；正交的原点取反投影点、方向恒为相机前向。**z=0.5 与
`projectionMatrix.elements[14]` 都与深度区间无关**：0.5 是管线中点，`elements[14]` 是相机平面
的 NDC z（我们 [0,1]、WebGL [-1,1] 都对），所以 r187 的代码在 M7 的 [0,1] 投影矩阵上原样成立
（B13/B14：正交光线原点恰好落在 z=10 的相机平面上）。

### 19.3 `OrbitControls` 的移植口径（D99）

**出处说明（诚实登记）**：`three-src/` 是只 checkout `src/` 的稀疏克隆，`examples/jsm/controls/
OrbitControls.js` **不在本仓**，因此本节给不出行号。移植依据是 r187 addon 的**公开行为**
（字段名、默认值、状态机、clamp 顺序），并对每条行为配一条探针断言；这是本表里唯一
「有出处路径、无行号」的条目。

- **三个鼠标动作各占一个槽**：`MouseButtons` 类（`left=ROTATE`、`middle=DOLLY`、`right=PAN`），
  不是 JS 的 `{LEFT:..., MIDDLE:...}` 字面量。
- **状态机**：`state ∈ {NONE, ROTATE, DOLLY, PAN}`；`MOUSE_DOWN` 按 `mouseButtons` 决定状态，
  `MOUSE_UP`/`RIGHT_MOUSE_UP` 归 `NONE`；`MOUSE_MOVE` 只在非 `NONE` 时动相机。
- **角度换算**：`rotateLeft(2π·dx/height)`、`rotateUp(2π·dy/height)`——用**视口高度**，不是宽度，
  所以同一个拖拽在宽屏和方屏上手感一致（D25 每像素逐位钉住）。
- **dolly 因子方向**（真实坑）：`dollyIn(x)` 半径**乘** `x`、`dollyOut(x)` 半径**除** `x`，且入参是
  `getZoomScale(Δ)=0.95^Δ ≤ 1` 的**缩放比**，不是「放大倍数」。所以 `dollyIn(0.5)` 的逆是
  `dollyOut(0.5)`（不是 `dollyOut(2)`，那会继续拉近）。D11/D12 就钉这一对。
- **轮子方向**：AIR/SDL glue 的 `MouseEvent.delta` 向上为正，而 DOM 的 `deltaY` 向上为**负**，
  所以 `deltaY = −e.delta`（唯一一处符号适配；D27/D28）。滚轮系数 `zoomSpeed` 只影响指数。
- **damping**：`enableDamping` 时每帧只应用 `dampingFactor` 份 delta，帧末 delta 乘 `1−factor`；
  因此**连续调 `rotateLeft` 会一步到位**（r187 的 `rotateLeft` 是「改 delta + 立刻 update」的便捷
  包装，D16 因此把它当成「已走 1/factor 步」的用例）。
- **pan**：`_panLeft/_panUp` 用相机矩阵的**列**（`setFromMatrixColumn`），因为相机矩阵的列就是
  它的世界基；`screenSpacePanning=false` 时改为 `up × X 列`，把平移约束在水平面内（D22）。
  pan 同时移动 `target` 与相机，因此距离不变（D21）。
- **正交相机**：滚轮改 `camera.zoom` 并 `updateProjectionMatrix()`，**不动半径**（D23）。
- **autoRotate** 只在 `state == NONE` 时生效（拖拽时不叠加自转，D18/D19）。

### 19.4 事件桥：`stage` 就是 `InteractiveObject`（R26）

`OrbitControls(camera, view)` 的 `view` 是 `flash.display.InteractiveObject`；AIR 把鼠标事件投递到
包含指针的显示列表，**Stage 收到全部**，所以传 `stage` 就能接住从任意位置开始的拖拽。
监听：`MOUSE_DOWN` / `MOUSE_MOVE` / `MOUSE_UP` / `RIGHT_MOUSE_DOWN` / `RIGHT_MOUSE_UP` /
`MOUSE_WHEEL`；`connect(view)`/`disconnect()`/`dispose()` 负责挂/摘（D30）。

**R26（测试口径）**：`MouseEvent` 的 `stageX/stageY/delta` 是**可写字段**，所以整条事件桥可以在
**无窗口**的探针里驱动 —— `new MouseEvent(MouseEvent.MOUSE_DOWN)` 设好坐标，
`sprite.dispatchEvent(e)`，控制器的状态机与角度换算就真跑了一遍（D24–D29）。这比「靠
`screencapture` 猜坐标」稳定得多，也让「每像素多少弧度」这种公式性断言可钉。

### 19.5 R25：`Camera` 必须声明 `updateProjectionMatrix`

AS3 没有鸭子类型：`OrbitControls.object` 的类型是 `Camera`，而 `reset()`（还原 `zoom`）与正交
dolly 都要调 `updateProjectionMatrix()`。three.js 的基类 `Camera.js` **根本没有这个方法**——
JS 靠鸭子类型，`PerspectiveCamera.js:353` / `OrthographicCamera.js:195` 各自实现，addon 直接假设
相机有这个成员。AS3 无鸭子类型 ⇒ 必须在基类声明。基类实现为「抛异常」（对应 three.js「基类
没有就是没有」的语义），两个子类覆写。同理把
`isPerspectiveCamera`/`isOrthographicCamera`/`zoom` 三个成员提到 `Camera` 基类 —— 否则
`if (this.object.isOrthographicCamera)` 这类分派在静态类型下根本编译不过。**这是静态类型逼出的
形状差异，不是语义改动**（调用序列与 three.js 一致）。

顺带一条诊断质量注记：同一作用域内用同一个 var 名先后声明两种类型（探针里先 `var down:Raycaster`
再 `var down:MouseEvent`）会被拒绝，但报错文案是 `implicit coercion of a value of type MouseEvent to
a possibly unrelated type ..._Raycaster`，而不是「重复声明」。语义正确（AS3 也不许重名），
文案可读性待改，登记为遗留。

### 19.6 验收

**探针** `probes/interaction-smoke-m14/InteractionSmokeM14.as`：**110 项 ALL PASS**
（A 射线 22 / B 指针桥 15 / C 拾取 37 / D 轨道 36）。分组覆盖：

- **A**：`at/recast`、`distanceSqToPoint`（前方量垂直距、后方量到原点）、三角命中与背面剔除、
  共享边 watertight（两三角都命中且 z 相同）、`applyMatrix4` 的前后变换、球（外部进入 / 内部退出 /
  radius<0 空球 / 背后 / 侧向擦过）、平面（距离 / 平行→NaN / 交点）、盒（进入点 / 背后 / `intersectsBox`）。
- **B**：NDC 四角与中心、零尺寸视口不产 NaN、`isInside`、`near/far` 默认、透视原点=相机位置、
  中心射线=相机前向、右/上偏移的符号、正交的方向与原点（含 z=相机平面、原点随 NDC 平移）。
- **C**：`FrontSide` 单命中 / `DoubleSide` 前后各一且升序 / `BackSide` 只命中远面 / 中心射线双命中
  （共享边）/ 漏射 0 命中 / `near`·`far` 裁剪 / 平移+缩放的**世界**命中点与距离 / `recursive`
  的有无 / 双网格等距时遍历顺序稳定 / 排序单调 / `drawRange`（默认 -1、0、局部 2）/
  非索引几何（顶点偏移 face、无 uv/normal 时不造假）/ `raycast` 返回 true / 旋转地面的正反面。
- **D**：构造后距离与初始极角、`rotateLeft/rotateUp` 的角度与距离守恒、极角/方位夹取、
  `dollyIn/Out` 的互逆与 `min/maxDistance`、`reset`、damping 的「每帧一份」与收敛、
  autoRotate（改角不改距）、pan（沿 -X、距离不变）、正交改 zoom 不改位置、**真事件序列**
  下的 ROTATE 状态与 `2π·dx/height`、MOUSE_UP 归位、轮子正负两向、`enableZoom=false`、
  `disconnect()`、`Spherical` 往返与 `makeSafe`、`Triangle.getNormal` 单位化与退化重心坐标。

**demo** `apps/interaction-m14/`：6 个彩盒围成环 + 中心竖立的环面（多三角形 + 有孔轮廓）+
地面（只接收阴影、不可拾取）+ 暖色 key（`castShadow`）+ 冷色 fill。

三种手势 + 点击，全部用 Quartz 合成**真实系统鼠标事件**驱动，日志为证
（`stdbuf -o0` 让 trace 实时落盘，否则 AOT 的 `trace` 是块缓冲）：

| 手势 | 日志/画面证据 |
|---|---|
| 左键点击绿色盒顶面 | `PICK #1 at (325,440) -> box2 distance=9.943 point=(-1.947,1.5,4.107) face=4 normal=(0,1,0)` |
| 左键点击环面管体 | `PICK #2 at (505,372) -> torus distance=11.951 point=(0.387,1.573,1.72) face=21 normal=(0.193,0.969,0.156)`（法线是插值后的管面法线，不是轴对齐面法线） |
| 左键拖 271px | `M14 drag released after 271px -- no pick (drag, not click)`，相机绕行 |
| 滚轮 4 格 | 距离变近（截图 `temp/m14-4-orbit-zoom.png`） |
| 右键拖 | 目标与相机同步平移（`temp/m14-5-pan.png`），且**不触发拾取**（右键不是点击） |
| 窗口改到 720×508 后再点击 | `M14 resize -> 720x508 aspect=1.417` + `PICK #1 at (245,350) -> box2 distance=9.784 point=(-1.992,0.959,4.566) face=1 normal=(1,0,0)`：`Event.RESIZE` 同步后缓冲/投影宽高比/控制器像素比例，命中点反解回局部正好落在 +X 面（|x| = 0.750 = 半边长），且 `face.normal` 是**局部**法线、`point` 是**世界**点、`distance` 是**世界**距离（three.js 同口径） |

截图序列：`temp/m14-1-baseline.png`（未选中）→ `m14-2-green.png`（绿盒高亮）→
`m14-3-torus.png`（环面高亮）→ `m14-4-orbit-zoom.png`（绕行 + 拉近，选中态保持）→
`m14-5-pan.png`（平移）。高亮 = 把 `material.emissive` 置 `0x2c4a86`，走的是 M8 的 fs5 通路，
不新增程序。

**指令预算**：`163/400`（一方向光）、`300/400`（两方向光 + 一张阴影图），与 M13 同值 —— 拾取与
轨道全在 CPU 侧，一个 uniform、一条 AGAL 都没加。

### 19.7 M14 明确不落（登记遗留）

- **hover 高亮**：每帧对全部网格射线 = 每秒数千次三角形测试，只为装饰效果；点击拾取才是
  M14 的契约。要 hover 就该先在 renderer 里做「拾取缓冲/GPU picking」，不是把 CPU 循环塞进
  `MOUSE_MOVE`。
- `Raycaster.layers` / `Raycaster.params`（`params.Line.threshold`、`params.Points.threshold`）：
  后端没有 `Layers`，也没有 Line/Points 拾取（D97）。
- `Sprite` / `Line` / `Points` / `InstancedMesh` / `SkinnedMesh` 的 `raycast`：只有 `Mesh` 实现了
  三角形拾取；`SkinnedMesh` 的形变已在 `updateDeform` 求和进 position 属性，所以**拾取用的是上一次
  渲染后的姿势**，不是绑定姿势（见上方 `getVertexPosition` 注释）。
- 多材质 `groups` 的逐组材质拾取：`Intersection.face.materialIndex` 恒 0，`geometry.groups` 不参与
  选材质（当前后端也只支持单材质 draw）。
- `Ray.distanceSqToSegment`（`Ray.js:180`）与 `Ray.intersectTri`/`Ray.intersectTriangle` 的
  `uvw` 输出：M14 没有用例，不实现（D94）。
- `OrbitControls` 的触摸/多点（AIR 单指针）、`keys`/`listenToKeyEvents`、`cursor`、
  `zoomToCursor`、`zoomToCursor` 的 dollying 分支、`ScreenSpacePanning` 的 `Pan` 之外的模式、
  `minTargetRadius`/`maxTargetRadius`（r187 新增）：未移植。
- `Raycaster` 的 `firstHitOnly`（three.js 是 `raycaster.firstHitOnly = true` 的 addon 约定）。

---

## 20. 性能 HUD：Stats 面板（D101–D104、R27，2026-10-31 M15 拍板）

three.js 自带一个性能小面板：`examples/jsm/libs/stats.module.js`（addon，内部
`REVISION: 16`，即 stats.js r16）。它画一个 **80×48** 的方块，一次只显示一个 74×30 的滚动图，
点一下换下一个面板。M15 把它借成 `kit/asaot/three/extras/hud/{Stats,StatsPanel}.as`，默认放在
**右上角**（three.js 的 DOM 版是 `top:0;left:0`）。

**出处口径**：该文件在 `examples/` 下，本仓 `three-src/` 只 sparse-checkout 了 `src/`，所以
**没有行号可引**（与 D99 的 OrbitControls 同一情形）。可核对的常量与时间窗全部逐条写进本节的
表，并由 `probes/stats-smoke-m15/` 76 项钉住——引用它的唯一方式是把数字变成断言。

### 20.1 借的形态（一字不改的部分）

| stats.module.js | 我们 | 说明 |
|---|---|---|
| `WIDTH = 80 * PR`、`HEIGHT = 48 * PR` | `StatsPanel.WIDTH/HEIGHT = 80/48` | PR 见 D103 |
| `TEXT_X/TEXT_Y = 3/2` | `TEXT_X/TEXT_Y` | 标签左上角 |
| `GRAPH_X/GRAPH_Y = 3/15`、`GRAPH_WIDTH/GRAPH_HEIGHT = 74/30` | 同名常量 | 图区 |
| `min = Infinity, max = 0`，**终生不重置** | `StatsPanel.min/max` | 「min-max」是面板生命期的极值，不是 500ms 滑窗 |
| `round(value) + ' ' + name + ' (' + round(min) + '-' + round(max) + ')'` | `StatsPanel.labelFor()` | 三个数都 `Math.round` |
| `msPanel.update(time - beginTime, 200)` 每帧 | `Stats.end()` | MS 的归一化是 **200** |
| `time >= prevTime + 1000` 才 `fpsPanel.update(frames*1000/(time-prevTime), 100)` | 同 | FPS 窗口 1 秒、归一化 **100**，窗口边界重置 `frames` |
| `memPanel.update(usedJSHeapSize/1048576, jsHeapSizeLimit/1048576)` 每秒 | `System.totalMemory/1048576`（D101） | 每 1 秒随 FPS 一起更 |
| `begin()` 记时、`end()` 计时、`update()` = `beginTime = this.end()` | 同 | `update()` 是「一帧一次」的便捷入口 |
| 点击 `showPanel(++mode % container.children.length)` | `Stats.cycle()` | 图标一次一个 |
| 图区先铺 fg、再用 bg 盖住 `(1 - value/maxValue)` 以上部分 | `barHeight(v,max) = clamp(v/max,0,1) * 30` | 两种画法等价（见 20.2） |

### 20.2 绘制：为什么不用 `drawImage(self)`

stats.js 把 `canvas` 自己画进自己（`drawImage(canvas, GRAPH_X+PR, …, GRAPH_WIDTH-PR, …)`）
左移一列，再在右端补一列。Stage3D 的显示列表没有「把自身光栅画进自己」的原语，所以
`StatsPanel` 保留 **74 槽 `Vector.<Number>`**（最旧在前），每 `update()` 左移一格、右端写新值，
然后整块重画。

代价是每次 `update()` 有 74 次 `drawRect`（一列一根 1px 宽的柱子，柱子为 0 高时跳过）。这个
量级在 60 Hz 下是每秒 ~4400 个矩形命令——`AGALRenderer` 的 draw 是 8 个，HUD 的 `Graphics`
走的是软件矢量路径，实测一帧开销 ≤1ms（见 20.9 的 A/B）。若将来 HUD 要更便宜，应当换成
**一块 `BitmapData` + 每帧只写一列像素**，而不是把 74 根矩形换成 74 个 Sprite。

`barHeight()` 还额外处理了三个退化输入（stats.js 会画出 NaN 矩形或负高）：`maxValue <= 0`
或 `NaN` 时返回 0、`value <= 0` 返回 0、`value > maxValue` 饱和到满高。满高饱和与 stats.js
一致（那里也是整列 fg）。

### 20.3 D101：`MB` 面板的替代物

stats.js 的 `MB` 面板只在 `performance.memory` 存在时（Chromium）才创建，读
`usedJSHeapSize / jsHeapSizeLimit`。AIR 没有 `performance.memory`：

- 分子用 **`System.totalMemory`**（AIR 同义 API，字节）÷ 1048576；
- 分母没有对应物（AIR 不暴露堆上限），取名义常量 **`MEMORY_SCALE_MB = 1024`**（1 GiB）。

这条是**形态借、数值不借**：它给的是「堆用了多少 / 相对一个固定上限有多满」的形状，不是
Chrome 的真实占比。所以 `MB` 面板默认存在（不像 stats.js 那样按平台条件创建），
`new Stats(false)` 可关掉。**登记**：本构建的 `System.totalMemory` 是 GC 堆镜像
（`gc_all_bytes`），ARM 上实测 2–3 MiB，与 AIR 描述符上的「进程内存」量级不同——面板显示的是
**本运行时的堆**，不是进程 RSS。

### 20.4 D102：右上角锚定

DOM 版是 `position:fixed;top:0;left:0`（左上、贴边）。M15 要的是**右上角**，因为 3D demo 的
注意力中心在画面中部偏下，左上又是 FPS 常见的调试文字位：

```
x = stageWidth - WIDTH - margin        // Stats.anchorX(stageWidth, margin)
y = margin                             // 默认 margin = 8
```

- 锚定发生在 `layout()`，由 `ADDED_TO_STAGE`、`addPanel()`、`stage.RESIZE` 三处触发，所以
  窗口拉伸后 HUD 仍贴右边（demo 日志 `M15 resize -> WxH HUD x=…`）。
- `autoPlace=false` 把 HUD 钉回左缘（`x = marginX`）——那是 stats.js 的位置，探针用它做 A/B
  （F5）。`layout()` 在**没有 stage** 时也安全（脱离显示列表时退回左缘，F4）。
- 锚定公式是**纯函数**（`Stats.anchorX`），所以「右上角」这件事不进 GPU 断言也能钉住。

### 20.5 D103：不加 `devicePixelRatio`

stats.js 的每个常量都乘 `PR = min(devicePixelRatio, 2)`，并在 `canvas.style` 上写死
`80px×48px`，让 9px 的标签在高 DPI 屏上仍是 9 个 CSS 像素。

我们的窗口画布**已经**按设备倍率放大：`ASC_window_render` 用 `contentsScale` 建后缓冲，
960×720 的 stage 在 Retina 上是 1920×1440 的像素。若这里再乘一次 PR，HUD 会变成 160×96 的
CSS 尺寸、实际 320×192 像素——两倍大。所以 **PR 恒为 1**：`80×48` 是 stage 单位，字号 9 是
stage 单位，落地到屏幕自然就是 18 个物理像素（截图 `temp/m15-tiles.png` 即 2 倍实拍，字号
清晰）。这条与「不引入第二个缩放因子」是同一条红线，不是省事。

### 20.6 R27：HUD 必须吞掉按下

three.js 里 HUD 是 `position:fixed` 的 `<div>`，盖在 `<canvas>` 之上，指针事件天然只到 div，
canvas 收不到 `pointerdown`——这正是「在 HUD 上拖拽不会转相机」的原因。

我们的 HUD 是显示列表里的 `Sprite`，而 **`OrbitControls` 的事件源就是 `stage`**（D99/R26）：
点在 HUD 上的 `MOUSE_DOWN` 会冒泡到 stage，被控制器当成「开始旋转」。所以 `Stats` 在
`MOUSE_DOWN` 与 `CLICK` 上都 `stopPropagation()`。这不是可选的礼貌：**漏掉按下**就会出现
「在面板上拖动 → 相机跟着转」，而且点击换面板的同时相机也转了，两个行为互相污染。

探针 G2/G3 钉住「点击/按下在 Stats 处被截断」，demo 用真实系统事件给出端到端证据（20.9）。
注意 AIR 的 `CLICK` 只在按下与抬起都落在同一目标上时发生，所以在 HUD 内按下再拖 30px 抬起仍会
**换一页**（stats.js 的 div 也是同一行为）——这是契约，不是 bug。

### 20.7 `CALLS` / `TRIS` 是增量，不是 three.js 的 HUD

three.js 的 HUD 只有 FPS/MS/MB 三页；draw call 数与三角形数在 `renderer.info.render` 里，靠
应用自己去读。我们照这个分工：`Stats` 提供 `addPanel()`（对应 `Stats.addPanel`），
`AGALRenderer.drawCalls` / `triangles` 由 demo 每帧喂给两个自建面板（`CALLS` 归一化 40、
`TRIS` 归一化 8000）。这两个面板的颜色与名字都是 demo 选的，`Stats` 不认识它们。

这样「面板数量」是开放的（ARRAY 版本里 5 页），而 HUD 的核心契约不变：一次一页、点一下翻页。

### 20.8 验收（`probes/stats-smoke-m15/`，76 项 ALL PASS）

A 8 / B 8 / C 21 / D 17 / E 11 / F 5 / G 6：

- **A** 面板几何与标签文法（含负数、`Infinity` 首帧、名字长度不截断缓冲区）；
- **B** `barHeight` 的饱和、零高、`maxValue<=0`/NaN 退化；
- **C** `update()` 的 74 槽滚动窗口、min/max 终生单调、读回的列高与画的一致；
- **D** `begin/end/update` 的时钟：MS 每帧（归一化 200）、FPS 每 1000ms（归一化 100）、
  边界重置、`update()==begin();end()`——用 `setTimeSource` 装假时钟，断言是**精确值**；
- **E** 面板轮换（一次只显一页、`cycle()` 环绕、`showPanel()` 可跳转）；
- **F** 右上角锚定与 margin 默认值、`autoPlace=false`、无 stage 回退；
- **G** 事件桥（点击冒泡到 Stats 并翻页、Stats 截断点击/按下、按下本身不翻页）。

**demo** `apps/stats-m15/`：M13 的英雄场景（地面 + 6 箱环 + 环面 + 两盏方向光 + 一张阴影图）
+ HUD + `OrbitControls`。用 Quartz 合成真实系统鼠标事件驱动，日志与截图：

| 证据 | 内容 |
|---|---|
| 锚定 | `M15 demo: Stats HUD in the top-right, 5 panels (click the tile to cycle); anchor x=872 y=8`（960 宽 stage） |
| 帧统计 | `M15 frame 300 rawMs=41 ms=41 fps=24 calls=8 tris=1834 az=0` |
| 五页轮换 | 5 次点击日志 `FPS → MS → MB → CALLS → TRIS → FPS`，截图 `temp/m15-1..6-client.png` 按面板底色分类断言（`temp/m15-panel.py`，5/5 与日志一致） |
| 面板外观 | `temp/m15-tiles.png`（5 页并排，2 倍实拍）：`24 FPS (24-24)`、`42 MS (2-120)`、`2 MB (2-3)`、`8 CALLS (8-8)`、`1834 TRIS (1834-…` |
| HUD 上拖拽不转相机 | `m15-7-hud-drag.png` 之后连续两帧 `az=0`；随后场景拖拽 → `az=-1.396`（`temp/m15-hud.log`、`m15-scene.log` 单变量对照） |
| HUD 的开销 | 同一二进制开/关 HUD 各跑 ~14 秒、各两次采样：开 `rawMs=42, 42`，关 `42, 41`（`temp/m15-hud-on.log` / `m15-hud-off.log`）⇒ 面板成本落在测量的抖动里（<1ms），24 fps 是场景（PBR 片元 300 指令 × 1920×1440）本身的 |

`1834 TRIS (1834-` 的截断是**照抄**：stats.js 也不量文本宽度，80px 之外直接被 canvas 裁掉。
要避免只能改 `name`（demo 用 `TRIS` 已经是最短的，`TRI` 也省不下几个像素）。

### 20.9 指令预算

不变：`163/400`（一方向光）、`300/400`（两方向光 + 阴影）。HUD 是显示列表 `Graphics` +
`TextField`，一个 Stage3D 程序都没加，`drawCalls` 仍是场景的 8。

### 20.10 M15 明确不落（登记遗留）

- **`Stats.dom` / `domElement`**：DOM 容器在 AS3 里没有对应物，HUD 自己就是显示对象；
  `setMode` 的向后兼容别名也不提供（用 `showPanel`）。
- **`PR = devicePixelRatio`**：见 D103，本后端恒 1。
- **统计口径的外置**：`renderer.info`（`memory.geometries/textures`、`render.calls/triangles/
  points/lines`）没有整体移植，只把 `AGALRenderer.drawCalls`/`triangles`/`culledObjects` 三个
  已有计数喂给面板。`points`/`lines` 在本后端没有对应 draw。
- **HUD 的鼠标交互只有「点击翻页」**：拖拽移动面板位置、透明度调节、双击复位都不做
  （stats.js 也没有）。
- **`performance.memory` 的真实上限**：见 D101，`MEMORY_SCALE_MB` 是名义值。

## 21. 应用宿主：显示刷新率同步 + 窗口 resize（D105–D108、R28，2026-10-31 M16 拍板）

到 M15 为止，15 个 demo 各自把自己的 Stage3D 引导抄了一遍：`stage.align/scaleMode` →
`requestContext3D` → `CONTEXT3D_CREATE` → 建场景 → `ENTER_FRAME` 里 `render()` + `present()`。
同形的代码抄 15 份本身只是难看，真正的问题是**漏一步就白屏/卡死**：M5 的整片白屏根因就是
`present()` 漏调，而 AIR 应用还需要两件浏览器替你做的事——把应用时钟对齐到显示器刷新率、
在窗口尺寸变化时重建 back buffer 与投影。M16 把它们收进**一个宿主基类**
`seam/asaot/three/app/Stage3DApp.as`，15 个 demo 全部 `extends Stage3DApp`。

**为什么是基类而不是 helper**：这三件事共享同一份状态（`stage`、`context3D`、`renderer`、
`camera`），而且都必须发生在「场景建好之前 / 每帧渲染之后」这两个精确时点。静态 helper 只能
被每个 demo 手动调用，一旦调用点写错顺序（比如在 `CONTEXT3D_CREATE` 之前注册 resize）就退回
今天的问题；基类让「时点」由构造顺序保证。代价是 demo 不能再继承别的显示类——当前没有 demo
需要，这一条在 21.5 登记为约束而不是限制。

子类契约（R28）：

| 成员 | 何时被调用 | 必须做什么 |
|---|---|---|
| `createScene()` | `CONTEXT3D_CREATE` 之后一次 | 设 `_scene` 与 `_camera`；基类为空则抛错 |
| `updateFrame(ms)` | 每帧渲染前 | 动画、controls 推进。首帧 `ms=0` |
| `afterFrame(ms)` | 每帧 `present()` 之后 | HUD 更新等「渲染后」工作 |
| `onViewportResize(w, h)` | 每次 resize，投影已重建后 | `controls.setSize(w,h)`、正交相机取景、HUD 重锚 |

### 21.1 D105：刷新率来自事件，不是猜的常量

AIR 没有「查询显示器刷新率」的 API。后端在面板频率可知时派发一次
`VsyncStateChangeAvailabilityEvent.VSYNC_STATE_CHANGE_AVAILABILITY`，事件带 `refreshRate`；
窗口被拖到另一块刷新率不同的屏幕上时**会再派发一次**。宿主的处理就是把这值写进
`stage.frameRate`：

```
stage.vsyncEnabled = true;                       // 显式，虽然它是 AIR 默认
stage.addEventListener(VsyncStateChangeAvailabilityEvent.VSYNC_STATE_CHANGE_AVAILABILITY,
                       onVsyncRefreshRate);
...
stage.frameRate = e.refreshRate;                 // application-wide 单值
```

三条口径：

- **`stage.frameRate` 是应用级单值**（`[SWF(frameRate=N)]` 或 24 起步），多窗口不叠加；
  宿主写一次即对所有窗口生效，与 AIR 一致。
- **`vsyncEnabled` 必须在写 `frameRate` 之前就为 true**，否则 pacer 会按旧节拍跑满一帧再改；
  显式赋值是为了让这条依赖在代码里可见，不靠默认值。
- **事件没来就不动**：web/离屏后端从不派发该事件，此时应用保持自己的 `frameRate`
  （demo 里是 24），行为与 M15 之前完全一致——增强不得改写既有语义。

`frameRateForRefresh()` 把「无法查询」归一成 `0`（哨兵），宿主见到 `0` 直接 return。
**不能把 `0` 写进 `stage.frameRate`**：AIR 的赋值下限是 0.01 fps，写 0 等于把应用冻住；
本运行时的 `frameRate <= 0` 另有一层「跟随本窗口显示器」的含义。两种结局都不是「保持原样」，
所以「不知道」只能表现为「不写」。

### 21.2 D106 / D107：resize 必须同时改 buffer 和投影

宿主把 `stage.scaleMode` 钉死在 `NO_SCALE` + `TOP_LEFT`（21.0 的前提）。在这个模式下
**stage 尺寸就是 back buffer 尺寸**，于是 resize 要做两件互不替代的事：

```
_renderer.setSize(w, h);                     // back buffer 跟着窗口
cam.aspect = w / h; cam.updateProjectionMatrix();   // 投影跟着宽高比
```

只做第一件 → 画面被拉伸（渲染目标是旧宽高比，合成器按新窗口铺）；只做第二件 → 渲染进旧
buffer，边缘被裁或被黑边补齐。`applyViewportSize()` 一次做完两件，再调 `onViewportResize()`
让 controls/HUD 跟上。

**正交相机刻意不自动改**（D107）：`OrthographicCamera` 的 `left/right/top/bottom` 是应用自己
选的取景框，自动按 aspect 缩放会改变「看到多少世界」。宿主只处理透视相机的 `aspect`，正交的
跟随策略留给子类在 `onViewportResize()` 里写——这是 three.js 的分工（`camera.aspect` 由应用
赋值），不是省事。

resize 可能早于 `CONTEXT3D_CREATE` 到达（窗口已经在屏幕上，而 context 请求还在飞），此时
`_renderer == null`，宿主直接返回：没有 back buffer 可改，投影也会在 `CONTEXT3D_CREATE` 里按
当时的 `stageWidth/Height` 重建。

### 21.3 D108：`present()` 归宿主

`render()` 只把结果编码进 render target，`present()` 才把它 blit 到窗口。M5 的白屏就是漏了
这一句。宿主在 `ENTER_FRAME` 里固定成 `updateFrame → render → present → afterFrame` 一条链，
子类拿不到「忘了 present」的机会；`afterFrame` 放在 `present` 之后正是为了让 HUD 的
`Graphics` 改动落在**下一帧**的合成里（与 stats.js 在 rAF 末尾更新面板等价）。

首帧 `elapsedMs = 0`：没有上一帧可差分，给 0 而不是 `getTimer()` 的绝对值，否则 delta 驱动的
demo 第一帧会跳一大步。

### 21.4 验收（`probes/apphost-smoke-m16/`，30 项 ALL PASS）

无 GPU 也能钉死行为的部分（A 7 / B 7 / C 6 / D 4）：

- **A** `frameRateForRefresh`：120/60/59.94 原样采用；0、负数、NaN 归 0（哨兵），宿主不写；
- **B** `aspectFor`：4:3、16:9、正方形；宽/高为 0 或负数返回 0（拒绝，不产 NaN/Infinity）；
- **C** 投影重建：`elements[0] * aspect == elements[5]`（只改一半就是拉伸/错切）、y 缩放不随
  aspect 变、逆矩阵同步、820×568 这条真实 resize 路径、竖直 fov 在重建后保持 60°；
- **D** 无 stage 时构造宿主不抛、`renderer == null`、`refreshRate == 0`——即 Stage3D 请求确实
  推迟到 `ADDED_TO_STAGE`。

**运行期证据**（`apps/` 15 个 demo 全部重编后逐个起窗）：

| 证据 | 内容 |
|---|---|
| 刷新率 | 15/15 日志首行 `Stage3DApp ready: <w>x<h> frameRate=120 refresh=120`；前置 `Stage3DApp: display 120 Hz -> stage.frameRate=120 (vsync true)`（本机 120 Hz 面板） |
| 节拍确实是面板率 | `AnimationM12` 用 delta 驱动：第 420 帧 `mixerTime=3.475` ≈ 420/120，证明应用时钟按 120 Hz 走，不是 24 Hz |
| HUD 重锚 | `StatsM15` 960×752 → 820×600 窗口：`M15 resize -> 820x568 HUD x=732` + `Stage3DApp: resize 820x568 aspect=1.444`，截图 `temp/m16-stats-resized.png` 面板仍贴右上、场景按新宽高比重排 |
| 拾取在新尺寸下仍准 | `InteractionM14` resize 后点击屏幕中心：`M14 resize -> 820x588 aspect=1.395` → `PICK #1 at (410,294) -> torus distance=11.872 point=(0,1.772,1.728) face=1752`，截图 `temp/m16-m14-resized.png` 环面高亮（投影没重建的话射线会打偏） |
| 不拉伸 | `RotatingCube` 640×512 → 900×420 窗口：`Stage3DApp: resize 900x388 aspect=2.32`，截图 `temp/m16-cube-resized.png` 里立方体仍是方的（2.32 的宽高比下没被横向拉长） |

15 个 demo 的逐帧统计与 M15 完全一致（`drawCalls=8 / triangles=1834`、`drawCalls=17 /
triangles=5428 / culled=40` 等），说明宿主重构没有改变渲染结果。

### 21.5 M16 明确不落（登记遗留）

- **不做显示器刷新率探测**：AIR 无此 API；`System.capabilities` 里也没有等价物。事件不派发
  就是没有（web/离屏后端），不猜、不用 `getTimer()` 反推。
- **不做每帧 resize 轮询**：resize 只由 `Event.RESIZE` 驱动；`stage.stageWidth` 每帧读一次再比较
  是纯浪费，且会和 `NO_SCALE` 的即时尺寸打架。
- **不改 `stage.scaleMode`**：`SHOW_ALL`/`NO_BORDER` 会让 stage 与 back buffer 脱钩，宿主的
  「stage 尺寸 = buffer 尺寸」前提失效，因此不提供选项。
- **不处理 `contentsScale` 变化**（窗口拖到不同 DPI 的屏）：那是后端合成层的事，
  `AGALRenderer.setSize` 收的是 stage 单位，物理像素由 window glue 按 `contentsScale` 放大，
  HUD 也因此不用乘 PR（§20.5）。
- **正交相机不自动 refit**（D107）、**不提供 `Stage3DApp` 的多窗口管理**：多窗口 + 多个
  `Stage3DApp` 实例目前没有 demo 需求，登记为未验证组合，不宣称支持。

### 21.6 宿主 HUD：统计面板归宿主，只有「画了多少」归 demo（D210，2026-11-03）

M24 时 FPS/MS/MB/CALLS/TRIS 五块面板写在 `PanelM24` 里。M34 起这套统计要跨 demo 复用，
于是上提到宿主，**默认全开**：

- `Stage3DApp` 在 `createScene()` 之后建 HUD，每帧在 `present` 之后更新（与 `afterFrame`
  同一时序理由：`Graphics` 改动落在下一帧合成里）。
- 子类用**保护方法 `showStats():Boolean` 关闭**（默认 `true`）。目前唯一的关闭者是
  `StatsM15` —— 那个 demo 的主题就是自己搭 HUD，宿主再叠一层就重复了。
- `stats` getter 暴露 HUD 实例，`hudCallsMax` / `hudTrisMax` 是给面板条形图用的归一化上界。
- **draw 计数与三角数由 demo 记账**：`frameDrawCalls()` / `frameTriangles()` 两个钩子默认
  返回 renderer 自报值。M34 必须覆盖——它的帧里既有 `renderer.render()` 的场景，也有一堆
  手工 `NativeShaderRenderer` pass（FFT 级联、反射、焦散、水面、合成），renderer 的计数器
  只看得见前者。M34 的实际做法是帧内 `_draws` 自增、`frameTriangles()` 返回
  `renderer.triangles + _draws*2`（每个手工 pass 都是一个全屏四边形），实测 76 CALLS / 75–77。
- **不要把 HUD 写成 demo 责任**：统计的刷新率、delta、显存估算、面板点击切换都是宿主知识；
  让每个 demo 抄一遍，只会得到 N 份彼此不一致的实现。

## 22. 纹理状态真的生效：wrap / filter / mip / flipY / colorSpace（D109–D114、R29–R31，2026-10-31 M17 拍板）

M17 的起点不是一个「新特性」，而是一次**静默失效的盘点**：`Texture` 自 M2/M5 起就带着
`wrapS/wrapT/magFilter/minFilter/flipY/generateMipmaps` 六个字段，`Scene` 带着 `background`/`fog`，
`Material` 带着 `blending`，`Object3D` 带着 `renderOrder` —— 它们的 getter/setter 都在，端口
代码照抄 three.js 也不会报错，但**渲染器一个都没读**。这类字段比缺少 API 更危险：调用方以为
自己已经改好了，画面却不变，且没有任何提示。

### 22.1 D109：这些字段各自映射到哪一层 Stage3D

| three.js 字段 | 本后端落点 | 说明 |
|---|---|---|
| `wrapS` / `wrapT` | `Context3D.setSamplerStateAt(slot, wrap, ...)`，在 `setProgram` **之后**调用 | Stage3D 每个 unit 只有**一个** wrap 旗标（`"repeat"` 或其余一律 clamp）；AGAL 里内联的 `<2d,clamp,...>` 也在写同一份状态，实测**后写者胜**（as3compiler `docs/zh-cn/display3d.md` §9.5） |
| `magFilter` / `minFilter` | 同一个 `setSamplerStateAt` 的 filter 参数 | Stage3D 只有一个 filter；取 `minFilter` 推导（缩小才是质量损失的那一侧），`nearest` 系 → `"nearest"`，其余 → `"linear"` |
| `generateMipmaps` + mip 系 `minFilter` | `setSamplerStateAt` 的 `mipfilter` + 上传时生成 mip 链 | 两个条件缺一不可：**没有链却要 mip 过滤，AIR 会整条 draw 丢弃**（后端据此实现了同样的行为，见 `s3d_draw` 的 mip-drop），所以 `mipFilterFor()` 把「要 mip」和「有链」锁在一起 |
| `flipY` | 上传前 `BitmapData` 行翻转 | Stage3D 的 `t=0` 是位图**首行**（顶行），three.js 的 `flipY=true` 表示 `t=0` 是**底行** |
| `colorSpace` | 片元的 `pow(x, 2.2)`（每个颜色槽一条），编译进按需变体 | 见 22.3 |
| `Scene.background`（Color） | `Context3D.clear(r,g,b,1)` | 见 22.4 |

`AGALRenderer` 把它们收成一组**纯函数**（`wrapModeFor` / `samplerFilterFor` / `mipFilterFor` /
`mipLevelCount` / `decodeMaskFor` / `clearColorOf`），就是为了让无 GPU 的探针能把判定钉死，
GPU 侧只剩「照判定执行」。

### 22.2 D110：mip 链是 CPU 生成后逐级上传，不是「让 GPU 自己生成」

- 生成方式：`BitmapData.draw(src, scaleMatrix, null, null, null, smoothing=true)` 逐级折半，从
  level 0 派生，一直到 `max(w,h)>>n == 1`；`mipLevelCount`/`mipDimension` 与运行时的链长度规则
  **同一套公式**（`1 + floor(log2(max(w,h)))`），所以不会出现「上传了一个不存在的 level」。
- 生成时机：与 level 0 同一次上传（`texture.version` 变化时），**不在每帧**做。
- 顺序不可换：`flipY` 必须先翻转再派生链，否则 level 0 与其余各级方向相反。
- `createTexture(..., mipmapped=true)` 的那个旗标在 AIR 与后端里都**不决定**「有没有链」——
  实测（as3compiler `temp/mipprobe` T3）只要 level 0 单独上传，mip 采样就整条 draw 被丢弃。
  真正的判据是「有没有传过 level > 0」，本后端用 `Texture.mips` 记账并在绑定时告诉后端。
- **立方体例外**：`CubeTexture.uploadFromBitmapData(side, miplevel>0)` 在本运行时是
  `if (miplevel != 0) return;`（立方体面不接收分级上传），而后端在六面齐了之后用 blit 自己
  `generateMipmapsForTexture` 建链。所以 cube 的 mip 过滤**天然可用**，渲染器不需要（也不应该）
  自己造链；`generateMipmaps=false` 的 cube 只是不要求 mip 过滤而已。

### 22.3 D111：颜色空间 —— 之前是「双重 gamma」，不是「颜色偏亮」

R7 定的是 three.js r187 的默认输出口径（`outputColorSpace = SRGBColorSpace`），两个程序的
片元最后都做 `pow(x, 1/2.2)`。与之配套的**输入侧**解码原先只有一条路：`Color.setHex()` 把
sRGB 十六进制解码到线性工作空间。**纹理没有这条路**——颜色贴图的纹素直接进了光照数学，
出来又被编码一次，等于曲线做了两遍。

- 判定：只有 `colorSpace == SRGBColorSpace` 才解码；`NoColorSpace`（three.js 的默认值）与
  `LinearSRGBColorSpace` 都不动。roughness/normal/metalness/AO 贴图是线性数据，即便存成图片
  也不解码。
- 落点：`pow(reg.xyz, reg.xyz, fc36.xxx)`，`fc36 = (2.2, 0, 0, 0)`——`fc35` 是最后一个 PCF tap
  （**历史**：D170 起解码改真 sRGB 曲线、常量移 `fc41/fc42`，`fc36` 在 D177 后退役，见 §34.1/§35.5）
  偏移，36 是第一个空闲寄存器。
- **变体化**（D112）：解码按槽位掩码编译（`DECODE_MAP` / `DECODE_EMISSIVE` / `DECODE_ENV`），
  标准程序缓存键从 `(dirs, shadows)` 扩成 `(dirs, shadows, decode)`，点/聚光程序按
  `(spot, decodeMap)`。没有 sRGB 贴图的场景仍走原来的变体，**指令数一分不涨**（实测：基础
  163/400，只有 base-color 解码 164，环境立方体三处解码 166）。
- 谁打这个标：`CubeTextureLoader.load()` 按 three.js r187 `CubeTextureLoader.js:62` 设
  `SRGBColorSpace`；`GLTFLoader` 只在 `baseColorTexture` 与 `emissiveTexture` 上设（glTF 规范里
  就这两个槽是编码色），metallicRoughness/normal/occlusion 保持线性；`TextureLoader` **不设**，
  由使用者按数据实际编码决定（demo 里显式写）。
- `glTF` 的 `flipY=false` 早就写好了（GLTFLoader.as 注释），M17 之后它**第一次有了效果**：
  之前因为不翻转而恰好正确，现在因为显式不翻转而正确。

### 22.4 D113：`Scene.background` 用 sRGB 三重清屏，不是线性

后台缓冲里存的是**已编码**值（每个程序都以 R7 的编码收尾），所以清屏色也要按编码值给：
`Color.getHex()`（r187 默认按 sRGB 取回）除以 255 直接进 `context.clear`。若改用线性值清屏，
同一个颜色做背景会比做几何暗一档。`background` 是 `Texture`（天空盒）时**没有实现**：渲染器
一次性 `trace` 报明并退回黑屏，不静默当作没设。

### 22.5 D114：`Scene.fog` 仍不生效，但不再沉默（`blending`/`renderOrder` 已在 M19 补齐）

`Scene.fog` 是 three.js 有、本后端没有的**真特性**（需要逐片元 mix），不是缺一个字段读取。
M17 的做法是给它一次性诊断（`_warnOnce`，只打一次）：`Scene.fog` 非空时明确说「本后端没有
fog pass，场景按未加雾渲染」。这样 porting 的人第一次跑就能看到差异，而不是对着截图怀疑人生。

> **勘误（M19）**：本节原先把 `Material.blending` 与 `Object3D.renderOrder` 也列进「不生效但
> 有诊断」——**当时的代码并没有为这两个字段打任何诊断**，是文档写在了实现前面。M19 直接把
> 它们做成真状态（§24.3 / §24.4），所以这条只剩 `fog` 一项；现在「有诊断的」与「有实现的」
> 一一对应。

### 22.6 R29–R31：三条必须守住的顺序/口径

- **R29**：`setSamplerStateAt` 必须在 `setProgram` **之后**、`draw` 之前。反过来会被程序的
  内联 sampler 旗标覆盖（同一份状态，后写者胜）。
- **R30**：任何绑到「无 mip 链」资源上的槽（阴影图、中性 1×1、深度图）都要**显式**把该槽的
  mip 过滤清成 `"none"`，否则上一个 draw 留在该槽的 `miplinear` 会让整条 draw 被丢弃。阴影图
  槽 `fs4` 因此在每次基 pass 绑定后立即 pin 成 `clamp/linear/none`。
- **R31**：中性纹理（未绑材质贴图时的 1×1 白/法线贴图）同样要重置该槽的 wrap/filter/mip，
  否则会继承上一个 draw 的 REPEAT。

### 22.7 验收

- **探针** `probes/texstate-smoke-m17/`：**51 项 ALL PASS**（A wrap 8 / B filter 9 / C 链几何 8 /
  D 颜色空间掩码 14 / E 清屏色 7 / F 行翻转 5）。无 GPU 也能钉死的判定全部覆盖，包含
  「mip 过滤必须有链」「`DECODE_CONST == 41`」（D170/D177；当年是 36）「翻转不改源位图」这类边界。
- **示例** `apps/texstate-m17/`：五块面片一屏说清五件事——A 默认状态（uvgrid 渐变，绿在上）、
  B `RepeatWrapping` + uv×4（tiling 真的重复了，旧代码是一张被拉伸的 clamp）、C uv×32 且放在
  `z=-6`（缩小采样，无 mip 链会噪点/摩尔纹，有链是平滑过渡）、D 纯 `0x808080` 的 sRGB 贴图、
  E 同一灰度的材质色。
- **mip 的 A/B**（`temp/m17-mip-ab.png`，左 `generateMipmaps=false`／右默认线性 mipmapped，同一相机、
  同一 uv×32）：左侧出现高频摩尔纹与饱和条纹（缩小时每像素只采到少数纹素），右侧是平滑的均值过渡。
  这是「链真的存在且真的被用上」的直接证据，不是「指令数变了」这种间接推断。
- **D vs E 是颜色空间的判据**：两者像素实测 **117 / 116**（差 1 个 LSB，来自 2.2 近似与 8bit
  舍入）。没有解码时 D 会走 `pow(0.502, 1/2.2) = 0.731`，即 **186 vs 116**——差 70 个色阶，
  肉眼一眼可辨。
- **flipY 的 A/B**（`temp/m17-flipy-ab.png`，同一姿势、同一相机，左 `flipY=false`／右 `flipY=true`）：
  源图 `uvgrid.png` 是「绿在上、蓝在下」（实测 `(5,250,5)` / `(5,250,250)`）。屏幕上 A 面片中心列的
  上/下沿实测：`flipY=false` → `(117,116,213)` / `(117,116,53)`（蓝上绿下，**倒的**）；
  `flipY=true` → `(117,116,45)` / `(117,116,192)`（绿上蓝下，**与源图一致**）。即 M17 之前**平面几何
  上的贴图是上下颠倒的**，M17 修好了。（同一位置 D/E 的读数不受影响，说明这不是颜色空间造成的差异。）
- **指令预算**：基础变体 **163/400** 不变；shadow 变体 **300/400** 不变；新增的只有解码位
  （每槽 +1：环境三处 166、单张贴图 164）。
- **回归**：`apps/` 16 个 demo 全部重编起窗、日志 15/15 `Stage3DApp ready`（`texstate-m17` 另算）、
  错误行 0；`probes/` 20 组全绿（**885** 项 PASS + `loader-smoke-m5`/`asset-load-probe` 两组
  自带格式的「all assertions passed」）；`gltf-m8` 的鸭子/头盔纹理明显更接近源图（之前是发白的
  二次编码结果），`env-m9` 的 IBL 变暗到与立方体贴图本身一致的亮度，`shadow-m13` 的镂空窗影与
  环面接触阴影不变（R30 生效），`animation-m12` 的背景由纯黑变成实测 `(14,16,21)`（作者写的 `0x0d1016`，逐通道 ±1 LSB 来自编码/解码曲线近似）（D113 生效）。

### 22.8 M17 明确不落（登记遗留）

- ~~**没有 `texture.repeat`/`offset`/`rotation`/`matrix`/`center`**：AGAL 贴图程序还没有 UV 变换
  环节，tiling 只能靠**几何的 uv 属性**放大（demo B/C 就是这么做的）。这是下一步，不是靠
  `setSamplerStateAt` 能解决的。~~ **M18 已补上**（见 §23）：UV 变换在顶点程序里做，与采样器状态
  无关；`apps/texstate-m17/` 的 B/C 面片仍保留 uv 放大写法，作为「M18 之前只能这么做」的对照。
- **`MirroredRepeatWrapping` 退化成 repeat**：Stage3D 没有镜像模式；且后端**每个 unit 只有一个
  wrap 旗标**，`clamp_u_repeat_v` / `repeat_u_clamp_v` 这类逐轴组合无法表达——`wrapIsLossy()`
  负责报告，渲染器 `_warnOnce` 打一次日志，不静默。
- **没有各向异性过滤**（`anisotropy`）：Stage3D 无此状态。
- **没有 `Scene.background` 的天空盒/equirect 通路**，**没有 `Scene.fog`**，**没有
  `Material.blending` 的自定义因子**，**没有 `renderOrder` 排序插入点**：见 22.5，均已登记并带
  一次性诊断。
- ~~**没有 sRGB 精确实传递函数**~~（**D170 已解决**：入/出都是真 sRGB 曲线 `fc41/fc42`，见 §34.1）：入/出都用 `pow(·, 2.2)` / `pow(·, 1/2.2)` 近似（与 R7 一致），
  不用 sRGB 分段函数——AGAL 无分支，分段近似要多几条指令且收益在 8bit 输出下不可见。

---

## 23. UV 变换真的生效：`repeat` / `offset` / `rotation` / `center` / `matrix`（D115–D118、R32–R34，2026-10-31 M18 拍板）

M17 收官时把「字段在、渲染器不读」的清单列在 §22.8，头一条就是 **UV 变换**：
`texstate-m17` 的 demo B/C 要 tiling，只能把**几何的 uv 属性**放大到 ×4 / ×32——那是「用模型
假装贴图在重复」，不是贴图真的在重复。纹理状态（wrap/filter/mip）在采样器上，UV 变换却在
**坐标**上，两者不是一个层：`setSamplerStateAt` 再怎么写也变不出 UV 变换。

### 23.1 D115：UV 变换落点是顶点程序的 `dp4`，不是采样器状态

three.js r187 的做法是给每张贴图配一个 `mat3`，在顶点着色器里乘坐标
（`ShaderChunk/uv_vertex.glsl.js:9-11`：`vMapUv = ( mapTransform * vec3( MAP_UV, 1 ) ).xy`），
矩阵由 `Texture.updateMatrix()`（`Texture.js:451-455`）调
`Matrix3.setUvTransform(offset.x, offset.y, repeat.x, repeat.y, rotation, center.x, center.y)`
（`Matrix3.js:394-410`）现算。本后端照抄这个**分工**：顶点程序变换 → varying → 片元采样。

AGAL 没有 mat3 乘，但**仿射** UV 变换只需要两次四分量点积：

```
u' = m00·u + m01·v + m02        rowU = (m00, m10, 0, m20)
v' = m10·u + m11·v + m12   <=>  rowV = (m01, m11, 0, m21)
                                u' = dot((u,v,0,1), rowU)
                                v' = dot((u,v,0,1), rowV)
```

`uvRowsInto()` 就按这个排布打包（`Matrix3` 是列主序，`m00=e[0]`、`m10=e[3]`、`m20=e[6]`）。

### 23.2 R32：`dp4` 之所以够用，靠的是 Stage3D 的 `FLOAT_2` 属性默认分量（z=0, w=1）

`va2` 是 `FLOAT_2`（八个顶点流里 uv 只有两个分量）。`dp4` 会读满四个分量，而顶点流没有
z/w —— 缺的分量由**硬件的通用属性默认值**补齐：z = 0、w = 1。三个后端各自的格式枚举都在
来源里核过：Metal `MTLVertexFormatFloat2`（`as3compiler/vendor/stage3d_glue.mm:1168`）、
GL `glVertexAttribPointer(..., components, GL_FLOAT, ...)`（`vendor/stage3d_webgl.cc:1279`，
未指定分量取 `(0,0,0,1)`）、D3D11 `DXGI_FORMAT_R32G32_FLOAT`
（`vendor/stage3d_d3d.cc:1187`，缺省同为 `(0,0,0,1)`）。

这条假设要是错了，`m02`/`m12` 的**平移项会整条消失**（`w=0` 时点积不含 m2x）。

这不是「照着规范推的」，是**截图证过**的：demo C 面片只改 `offset`（`repeat` 仍是 1），若 w=0
则该面片与 A 面片逐像素相同；实测它整体平移了半个贴图，接缝落在**宽度 50.5%** 处（§23.7）。

### 23.3 D116：六个槽各有一套系数，不是一个共享变换

three.js 是**逐贴图**的（`WebGLMaterials.refreshTransformUniform` 对 map / normalMap /
roughnessMap / metalnessMap / emissiveMap / aoMap / envMap … 各调一次），因为作者完全可以让
底色平铺 4×4 而自发光平铺 3×3。本后端同样按槽上传：

| 槽 | `UV_*` 常量 | 顶点常量 | 片元读的 varying |
|---|---|---|---|
| base color map | `UV_MAP` = 0 | `vc40`, `vc41` | `v2.xy` |
| normalMap | `UV_NORMAL` = 1 | `vc42`, `vc43` | `v2.zw` |
| roughnessMap | `UV_ROUGHNESS` = 2 | `vc44`, `vc45` | `v6.xy` |
| metalnessMap | `UV_METALNESS` = 3 | `vc46`, `vc47` | `v6.zw` |
| emissiveMap | `UV_EMISSIVE` = 4 | `vc48`, `vc49` | `v7.xy` |
| aoMap | `UV_AO` = 5 | `vc50`, `vc51` | `v7.zw` |

`uvVaryingOf(slot)` 是这张表的**唯一**来源：`uvTransformBlock()` 生成 mov 的顺序、片元的采样
坐标、探针的期望都从它取，所以「改打包」不可能只改一半。

`vc0..vc3` MVP、`vc4..vc7` 模型、`vc8..vc10` 法线矩阵、`vc12..vc19` 阴影矩阵、`vc20..vc22`
阴影 bias / `receiveShadow`——40 起是第一个足够大、且离 AIR 128 上限还有余量的整块。

### 23.4 R33：法线贴图的 uv 从 `v3.zw` 搬到 `v2.zw`（切线帧的导数必须与采样同一套 uv）

旧程序里 `v2` 只写了 `.xy`（map uv），`v3` 写了 `.xyz`+`.w`（世界位置 + 别的），切线帧用
`ddx ft6.xy, v2.xy` / `ddy ft6.zw, v3.zw` 算 uv 的屏幕导数。M18 之后 normalMap 有了**自己的**
uv，`ddx`/`ddy` 必须都取**法线贴图那一路**的坐标——否则「用贴图 A 的导数去扰动贴图 B 的采样」
会在两者 `repeat` 不同时给出完全错误的凹凸方向。所以：

- `v2` = (map u, map v, normal u, normal v)
- `v3` = (世界位置 …)，切线帧不再从它读 uv

### 23.5 D117 / R34：常量每 draw 上传，但永不每帧分配

`_uvRows`（48 个 float，六个槽 × 8）是渲染器的常驻 `Vector.<Number>`，每次 draw 由
`_fillUvRows(material)` 就地覆写、`setProgramConstantsFromVector(VERTEX, vc40, _uvRows, 12)`
一次上传——与法线矩阵、灯光常量同一条通路，**不新建对象**。`uvMatrixOf()` 只在
`matrixAutoUpdate` 为真时调 `updateMatrix()`（= `WebGLMaterials.js:13-22` 的
`refreshTransformUniform`），作者把 `matrixAutoUpdate` 设 false 后手写的 `matrix` 原封不动。

### 23.6 D118：alpha 镂空 caster 也要用同一个变换

`alphaTest` 的阴影程序要采 base color 判断镂空（M13 的 D90），它采样的 uv 必须是**经过 base
color 贴图变换的** uv，否则「贴图平铺 4×4 的镂空叶子，影子却按 1×1 裁」。该程序因此也只上传
`vc40`/`vc41`（两个寄存器，`setProgramConstantsFromVector(..., 2)`），顶点里同样两条 `dp4`。

### 23.7 验收

- **探针** `probes/uv-smoke-m18/`：**39 项 ALL PASS**——A `setUvTransform` 数值 8（identity /
  repeat 只动对角 / offset 落平移列 / 90° 映射 `(1,0)→(0,-1)` / 绕 `center` 不动中心 / 2π=单位 /
  底行恒 `(0,0,1)`）、B `updateMatrix` 与 `matrixAutoUpdate` 契约 13、C 常量打包 3、D
  **打包行必须等价于 `mat3·(u,v,1)`** 2（含「纯 offset 也要活过点积」）、E 六槽 varying 表 6、
  F `uvTransformBlock` 结构 7（16 条指令 / 12 `dp4`+4 `mov` / `vc40..vc51` 逐个出现 / 写
  `v2`·`v3`·`v6`·`v7` / **不为 null**）。
  F1 是给 AS3 的**自动分号插入**立的钉子：`return` 换行 = `return undefined`，那条 bug 让顶点
  源码里多了一行字面 `null`，流水线报的却是
  `fragment input(s) ... not written by vertex shader`——症状与根因隔了三层。
- **示例** `apps/uv-m18/`：六块面片**共用同一个 `PlaneGeometry`、uv 属性一个像素都没改**，差别
  全在 `Texture` 上：

  | 面片 | 作者写法 | 截图实测（横穿面片 9 点取 R 通道） |
  |---|---|---|
  | A 参照 | 默认 | 102 → 199 单调升（一张完整渐变，无接缝） |
  | B `repeat(4,4)` + Repeat | `t.repeat.set(4,4)` | 接缝在 **25.5% / 50.5% / 75.5%** ⇒ 正好 4 格 |
  | C `offset(0.5,0)` + Repeat | `t.offset.set(0.5,0)` | 接缝在 **50.5%**，R 由 210 掉到 101 ⇒ 位移恰好半张 |
  | D `rotation=π/4, center=(0.5,0.5)` | 三个字段 | 中心像素 `(117,117,116)` 与 A 的中心 `(116,117,117)` **相同** ⇒ 旋转轴确在贴图中心；外围是转过 45° 的斜向扫掠 |
  | E 手写 `matrix`（`matrixAutoUpdate=false`） | `matrix.setUvTransform(0,0,-1,1,0,0,0)` | 剖面 `200,177,155,135,117,103,96,95,103` = A 的 `102,96,96,102,116,133,154,176,199` **逐点镜像** |
  | F 底色 1×1 + `emissiveMap.repeat(3,3)` | 两个槽两套变换 | 三组采样值 `(156,236,177)(173,171,172)(224,135,171)` **原样重复三次**，接缝在 33.5%/66.5% ⇒ 3 格，而底色仍是平的 |

  E 与 F 是 M18 的两个关键判据：E 证明**镜像（负缩放）**只有手写 `matrix` 这一条路（`repeat`
  是「格数」，写不出负数），也证明 `matrixAutoUpdate=false` 时作者矩阵不被覆盖；F 证明**两槽
  独立**——底色平铺 1 次、自发光平铺 3 次，共享一套 uv 的渲染器只会画出单张。
- **回归**：`apps/` **17 个 demo** 全部重编链接成功、起窗无错；`probes/` **22 组全绿**
  （**924** 项 PASS + `loader-smoke-m5`/`asset-load-probe` 两组自带格式的「all passed」），
  上一轮 21 组 885 项，本轮 +`uv-smoke-m18` 39 项。
- **指令预算**：片元**一分未涨**（基础 163/400、shadow 300/400、`env-m9` 166、`gltf-m8`
  223/224、`alpha-m10` 180，与 M17 逐个相同）——UV 变换全在顶点侧，新增 16 条顶点指令 / draw。
- **肉眼看不出回归**：`texture-maps` 的法线鼓包仍在（切线帧导数改读 `v2.zw` 之后与 M17 截图
  同形）、`shadow-m13` 的镂空窗影四面透光不变、`interaction-m14` 的环面高光与六彩盒不变、
  `gltf-m8` 的鸭子/头盔与 M17 基线同形同色。

### 23.8 M18 明确不落（登记遗留）

- **不做 UV 集选择**：three.js 的 `Texture.channel`（配合 `uv2`/`uv3` 属性与 `*_UV` 宏）在本后端
  没有对应物——`BufferGeometry` 只有一路 `uv` 属性，`va2` 就指它。多 UV 集是独立特性，
  登记为遗留，不假装 `channel` 有数。
- **不做各向异性过滤**（仍同 §22.8）：`Texture.anisotropy` 无后端状态。
- **不做 `envMap` 的 UV 变换**：环境采样是 `reflect()` 得到的方向向量，不是 uv；three.js 那边
  `envMapTransform` 只在 equirect/球面映射（本后端未实现）里有意义。
- **`Scene.fog`** 仍不生效（D114 不变）；`Material.blending` / `Object3D.renderOrder` 已在 M19
  做成真状态（§24.3 / §24.4）。

## 24. 渲染状态真的生效：side / depthTest / depthWrite / blending / renderOrder / flatShading / wireframe（D119–D125、R35–R39，2026-10-31 M19 拍板）

M17 修的是纹理状态、M18 修的是 UV 变换，M19 修的是**第三批「字段在、渲染器不读」**：

| 字段 | M19 之前 | 后果 |
|---|---|---|
| `Material.side` | 渲染写死 `setCulling('front')`（只在 `Mesh.raycast` 拾取里读过） | **唯一肉眼可见的 bug**：`DoubleSide` 的薄片从背面看直接消失；glTF `doubleSided:true`（`GLTFLoader.as:1281` 设了 `DoubleSide`）也无效 |
| `Material.depthTest` | `setDepthTest` 全是各 pass 硬编码 | `depthTest=false` 无效 |
| `Material.depthWrite` | 写不写深度只跟 `transparent` 走（D49） | 不透明物体 `depthWrite=false` 无效 |
| `Material.blending` | 只实现 `NormalBlending`（D51），因子写死 | `Additive`/`Multiply`/`NoBlending` 无效 |
| `Object3D.renderOrder` | 只在 `Object3D.copy()` 里被赋值 | 排序键不存在 |
| `MeshStandardMaterial.flatShading` | `seam/` 里零次出现 | 球面永远是光滑法线 |
| `Mesh*Material.wireframe` | `seam/` 里零次出现（`ObjectLoader` 还照常填这个字段） | 线框材质静默画成实心 |

M19 的处理原则与 M17/M18 一致：**每个字段映射到后端的哪一个真实调用/程序变体，写成一个纯函数，
再由探针钉住**——状态调用本身需要 `Context3D`，只能靠画面证明，但「映射表」可以无 GPU 钉死。

### 24.1 D119：`side` → `setCulling`，而且必须**反着映射**

| `Material.side` | three.js 语义 | `setCulling` |
|---|---|---|
| `FrontSide`（0，默认） | 剔除背面 | `"front"` |
| `BackSide`（1） | 剔除正面 | `"back"` |
| `DoubleSide`（2） | 不剔除 | `"none"` |

看着像笔误，其实是**绕序约定**：本后端的正面是 **CW**（Stage3D/Starling 约定），而 three.js 的
几何是 **CCW** 绕序。于是 three.js 的**正面**在本后端是**背面**，要剔除 three.js 的背面就得
`setCulling("front")`。这张表在封闭网格上看不出对错，在**薄片**上错一格就是整片消失——正是
M19 之前 `DoubleSide` 失效时看到的现象。`cullingFor(side)` 是唯一出口，未知值落回 `FrontSide`。

### 24.2 D120：`depthTest` / `depthWrite` 是 `setDepthTest` 的两个半边

Stage3D 的 `setDepthTest(depthMask:Boolean, compareMode:String)` 把 OpenGL 深度状态的两半装进
一个调用：布尔是**写掩码**，字符串是**比较函数**。three.js 表达「不做深度测试」的办法是关掉
`GL_DEPTH_TEST`，而关掉的深度测试**同时也不写深度**，所以：

| `depthTest` | `depthWrite` | `setDepthTest(mask, compare)` |
|---|---|---|
| `true` | `true` | `(true, "lessEqual")` |
| `true` | `false` | `(false, "lessEqual")` —— 只读不写 |
| `false` | 任意 | `(false, "always")` —— 不测也不写 |

**这一条取代了 D49**：M10 的透明 pass 曾经硬编码 `setDepthTest(false,'lessEqual')`，等于「透明
材质一律不写深度」。M19 起写不写由 `Material.depthWrite` 决定（three.js 的默认值是 `true`，
玻璃这类要显式写 `depthWrite = false`）。`apps/alpha-m10` 的三层玻璃是 `transparent=true` 且
没动 `depthWrite`，改后仍按远到近合成、画面只在**镂空面板的贴图半透明边缘**有 0.29% 的变化
（见 §24.8）——因为那些边缘的片元 alpha 是「贴图 alpha × opacity」，现在**真的参与混合**了。

### 24.3 D121：`blending` → 五个模式，`CustomBlending` 一次性诊断

映射按 three.js `WebGLState.setBlending`（r187）逐条抄：

| `Material.blending` | three.js 因子 | `setBlendFactors(src, dst)` |
|---|---|---|
| `NoBlending` 0 | 关混合（替换） | `("one", "zero")` |
| `NormalBlending` 1（默认） | `SRC_ALPHA, ONE_MINUS_SRC_ALPHA` | `("sourceAlpha", "oneMinusSourceAlpha")` |
| `AdditiveBlending` 2 | `SRC_ALPHA, ONE` | `("sourceAlpha", "one")` |
| `SubtractiveBlending` 3 | `ZERO, ONE_MINUS_SRC_COLOR` | `("zero", "oneMinusSourceColor")` |
| `MultiplyBlending` 4 | `ZERO, SRC_COLOR` | `("zero", "sourceColor")` |
| `CustomBlending` 5 | 逐材质的 `blendSrc/blendDst/…` | **不支持** → 按 `NormalBlending` 画 + 一次性诊断（R35） |

因子名是**字符串**，写错一个字母不是编译错误，而是一整屏黑（后端把未知名字退化成 `one`）。
所以这十个合法名字在探针里有一张白名单表逐个比对（D9）。混合状态**每 draw 一次**（不是每
pass 一次），与 three.js 的 per-material 语义对齐。

### 24.4 D122：`renderOrder` 是两张列表的**首**排序键

three.js 的排序谓词是 `painterSortStable`（不透明：`groupOrder → renderOrder → id`）与
`reversePainterSortStable`（透明：`groupOrder → renderOrder → z 远到近`）。本端口没有
`groupOrder`（没有多材质 group 分桶）和 `id`，所以实际口径是：

- **不透明列表**：只按 `renderOrder` 升序，**相等保持遍历序**（插入排序天然稳定）。
- **透明列表**：先 `renderOrder` 升序，**相等再按相机到物体原点的平方距离远到近**（R17 的键）。

排序用插入排序（不透明/透明量级是个位数，零分配）。`renderOrderOf()` 读字段，两张列表各有一个
纯谓词（`opaqueOrderSwaps` / `transparentOrderSwaps`）供探针直接钉。

### 24.5 D123：`flatShading` 是**导数面法线**，不是拆几何

three.js 打开 `flatShading` 时用的是 `normal_fragment_begin.glsl.js` 的 `FLAT_SHADED` 分支：
由 `dFdx(vViewPosition)`、`dFdy(vViewPosition)` 叉乘得到**面法线**，几何与法线属性都不动。
本后端没有 `dFdx/dFdy` 指令，但**屏幕空间导数**在片元里已经算好（M4 的切线帧就用它），
世界位置的两个导数分别落在 `ft4`/`ft5`，于是这一段只有两条指令：

```text
crs ft0.xyz, ft4.xyz, ft5.xyz   // N = dPdx × dPdy
nrm ft0.xyz, ft0.xyz            // 归一
```

`ft0` 正是光照读取法线的寄存器，所以直接接在原法线赋值之后即可。代价：`flat=1` 的变体
**+1 条片元指令**（163 → 164/400）。程序变体键加上 `flat` 位，`flatShading` 只在
`MeshStandardMaterial`（含聚光变体）上生效，`MeshBasicMaterial` 本来就不算光照。

### 24.6 D124 / R38：`wireframe` 是真线框，但**不经光照**

three.js 把光栅化器切到 `LINES`。Stage3D 只有 `drawTriangles`，所以与 M11 的 `LineSegments`
同一条路：**每条三角形边在屏幕空间展开成一个四边形**（4 顶点：端点各两份、侧向 ±1），复用
M11 的线段程序。168 面的球 → **504 条边四边形**（不做去重：three.js 的 `WireframeGeometry` 靠
哈希去重，这里共享边被画两遍——在 1px 宽度下看不出来，换来建缓存单趟）。

三条登记的分歧（R38）：

1. **颜色是材质的平色**（`color` × `opacity`）：线段程序没有光照/贴图阶段。
2. **聚光/点光的加色 pass 跳过线框**：一条无光照的线会在每个光 pass 各加一次，越加越白。
3. **阴影 pass 仍按面光栅化**：three.js 会把 `wireframe` 传给深度材质（投出线影），本端口投的是
   实心体影子——因为 caster 那侧走的是独立的深度程序，与主几何无关。

### 24.7 R35–R39：五条必须守住的口径

- **R35**：`CustomBlending` 没有实现（本端口不暴露逐材质 `blendSrc/blendDst`）。它**降级到
  `NormalBlending` 并一次性诊断**，不静默画成别的东西——与 D114「登记 + 说一次」同一手法。
- **R36**：**阴影 pass 的 `shadowCullingFor` 与主 pass 不同，且与 three.js 有一处刻意分歧**。
  three.js 把 caster 的 `side` 经 `shadowSide = {FrontSide: BackSide, BackSide: FrontSide,
  DoubleSide: DoubleSide}` 翻转（`WebGLShadowMap.js:51`），这样封闭 caster 记录**远表面**、不会
  自阴影。本端口 `FrontSide` 仍按正面剔除（`"front"`）：**已验收的镂空 caster 全是单面薄板**，
  翻成 `BackSide` 会把它的每一面都剔掉、影子整块消失（`apps/shadow-m13` 的四窗透光就会退化成
  没有影子）。`BackSide` 与 three.js 的翻转结果一致（`"front"`），`DoubleSide` 不剔除。
- **R37**：**聚光/点光的加色 pass 是唯一覆盖材质状态的地方**。它画的是一盏灯的增量贡献，
  必须 `('one','one')` 加色且不写深度，否则每盏灯都会重写整块像素。three.js 把全部 punctual
  光放在**一个** shader pass 里求和，因此没有「逐 pass 状态」这回事——这是实现形态带来的分歧，
  不是语义选择。该 pass 同时跳过线框（R38.2）。
- **R38**：线框的三条分歧见 §24.6。
- **R39**：**混合状态会让 Metal 走「读目标」的 ROP 路径，即使乘数是 0**。`env-m9` 在 M19 前后
  有 0.36% 的像素有差（最大 49/255，散点、肉眼不可见），但**这不是混合算术的差**：把
  `NormalBlending` 的因子换成 `("one","oneMinusSourceAlpha")` 甚至
  `("one","oneMinusDestinationAlpha")`（乘数恒 0）画面**逐点相同**，而 `("one","zero")`
  （目标因子为 `zero`、不走读路径）就与 M17/M18 的基线**逐像素相同**。同一份代码里
  `texstate-m17`/`uv-m18`/`interaction-m14` 三个静态 demo 在 M19 前后**0.00%**。结论：只要
  目标因子非 `zero`，Metal 的读改写路径就有 LSB 级差异，属于后端而非 AS3 语义；登记备查，
  不因此改动映射表。

### 24.8 验收

- **探针** `probes/renderstate-smoke-m19/`：**59 项 ALL PASS**——A `cullingFor` 6（三面 + 未知值
  回落 + 三态互异 + 全是合法参数）、B `shadowCullingFor` 3（R36 三条）、C 深度两半 7（含
  「`depthTest=false` 即使 `depthWrite=true` 也不写」）、D 混合 11（五模式 + `CustomBlending`
  未实现 + 越界值落同一条路 + 十个因子名白名单 + `blending`/`side` 常量与 `constants.js` 对齐）、
  E 排序谓词 5（含「相等保持遍历序」与「透明列表 `renderOrder` 压过深度」）、F 默认值 7
  （`side=FrontSide`、`blending=Normal`、`depthTest/depthWrite=true`、`flatShading/wireframe=false`、
  `MeshBasicMaterial` 同口径）、G `flatNormalBlock` 6（两条指令 / 叉乘后归一 / 写 `ft0` /
  **不为 null**——M18 的 ASI 教训）、H 线框打包 14（半边宽 = `linewidth/2`、宽度非正回落 1px、
  顶点序 `[a,a,b,b]`/`[b,b,a,a]`/侧向 `(-1,+1,+1,-1)`、两个三角 `(0,1,2)`+`(1,3,2)`、第二条边落
  在顶点 4 / 索引 6）。
- **示例** `apps/renderstate-m19/`：九块面板，每块都是**一个字段的最小 A/B**，trace 里同时打出
  该字段映射到的 Stage3D 调用。截图取值（`temp/m19-renderstate.png`，1920×1344）：

  | 面板 | 作者写法 | 实测像素 |
  |---|---|---|
  | A | 薄板转 180°、`FrontSide` | `(51,51,51)` = **只剩背景板** ⇒ 背面真的被剔了 |
  | B | 同一块板、`DoubleSide` | `(104,188,249)` = 板在 ⇒ M19 之前这里是 A 的样子（**唯一肉眼可见的修复**） |
  | C | 近红 + 远绿，近块 `depthTest=false` | 主体 `(111,220,112)` 绿 ⇒ 远块盖住近块（红只剩 1–2px 侧边 `(221,70,62)`） |
  | D | 近红 `depthWrite=false` + 远绿 | 同样 `(111,220,112)` ⇒ 只测不写，远块照样通过 |
  | E | 三条同样的条带、`opacity=0.4` | Normal `(107,57,92)` / Additive `(128,77,112)` **更亮** / NoBlending `(195,72,156)` **不透**（忽略 alpha） |
  | F | 两块共面，先红后绿；`red.renderOrder=1`、`green.renderOrder=-1` | `(221,70,62)` 红在上面 ⇒ 排序键压过遍历序（没有 `renderOrder` 时是绿） |
  | G/H | 同一个球 `12×8`，`flatShading` false / true | 中心 `(162,167,174)` 光滑 vs `(140,144,150)` 且**大块平直切面** |
  | I | 同一个球开 `wireframe` | 168 面 → **504 条边四边形**，半宽 0.5px，线色 `(170,213,251)` = 材质色 |

- **回归**：`apps/` **18 个 demo** 全部重编链接、起窗无错（18/18 `Stage3DApp ready`、
  `grep -ciE "error|mismatch|not written by vertex|dropped"` 全 0）；`probes/` **23 组全绿**
  （**983** 项 PASS + `loader-smoke-m5`/`asset-load-probe` 两组自带格式的「all passed」），
  上一轮 22 组 924 项，本轮 +`renderstate-smoke-m19` 59 项。
- **指令预算**：标准片元**一分未涨**（163/400；shadow 300/400；`env-m9` 166、`gltf-m8`
  223/224、`alpha-m10` 180、`animation-m12` 222、`shadow-m7` 241 与 M18 逐项相同），新增只有
  `flatShading` 的变体 **164/400（+1）**。线框不新增程序（复用 M11 线段程序）。
- **像素级回归**：静态场景里 `texstate-m17`、`uv-m18`、`interaction-m14` **逐像素相同
  （0.00%）**；`alpha-m10` 0.29% 集中出现在镂空面板贴图的半透明边缘（§24.2 已解释：片元 alpha
  现在真的混合）；`env-m9` 0.36% 是 R39 的后端读改写路径差。其余 demo 都有逐帧旋转，**同版本
  两次截图的差反而更大**（`asset-load` 13.77% vs M18→M19 13.42%、`gltf-m8` 20.36% vs 15.44%、
  `pbr-cube` 11.67% vs 9.68%、`stats-m15` 8.84% vs 10.31%、`shadow-m7` 2.90% vs 2.15%、
  `shadow-m13` 5.1% vs 4.54%）⇒ 差异来自帧相位，不是回归。`shadow-m13` 的镂空窗影四面透光、
  `geometry-m11` 的盒线框、`uv-m18` 的六面片判据全部原样。

### 24.9 M19 明确不落（登记遗留）

- **不做 `Material.depthFunc`**：比较函数固定 `lessEqual`（`depthTest=false` 时 `always`）。
  three.js 的 `GreaterDepth`/`EqualDepth` 等在本后端只能映射到 `setDepthTest` 的那几个字符串，
  但没有用例，先不铺开。
- **不做 `colorWrite` / `stencilWrite` / `polygonOffset` / `alphaToCoverage`**：都是独立特性，
  与「字段静默失效」不同——本端口**没有**这些字段，所以不会误导 porting 的人。
- **不做 `CustomBlending` 的逐材质因子**（R35）。
- **不做 `renderOrder` 的 `groupOrder` 分桶**（没有多材质 group 渲染），也不给 `LineSegments`
  列表排序（M11 的单 pass 按收集序）。
- **不做线框的光照/贴图/去重/线宽语义**（R38）：线宽是屏幕空间像素半宽，不是 x 分数。
- **不做阴影 pass 的 `shadowSide` 翻转**（R36，刻意分歧）。
- **`Scene.fog`** 仍在（D114 不变）：它是需要逐片元 mix 的真特性。

## 25. 四条静默失效补齐 + 场景雾 / 背景（D126–D132、R40–R45，2026-10-31 M20 拍板）

M17 修纹理状态、M18 修 UV 变换、M19 修渲染状态，M20 把**同一类「字段在、渲染器不读」的最后
四条**清完，再把 M17 时被一次性诊断挡住的 `Scene.fog` / `Scene.background` 做成真特性：

| 缺陷 | M20 之前 | 后果 |
|---|---|---|
| 不透明材质照样走 alpha 混合 | `_applyMaterialState` 无条件 `setBlendFactors(sourceAlpha, oneMinusSourceAlpha)` | `transparent=false` + `opacity<1` 画成**半透明**（three.js 是纯不透明）——「忘了写 `transparent`」这种最典型的写法在本端口看起来是「写了也没用」 |
| 阴影 pass 不剪隐藏子树 | `_renderShadowObject` 只查 mesh 自己的 `visible`，`Group.visible=false` 时照常递归 | 藏起来的组**还在投影**。主 pass 的 `_collectMeshes` 剪得对 ⇒ 症状是「看不见但影子在」，最难查的一种 |
| `geometry.drawRange` 渲染侧不读 | `seam/` 里 `drawRange` 命中 **0** 次，一律画 `index.count/3`；只有 `Mesh.raycast` 读它 | 作者设 `drawRange` 想画子集 → 画面**一点不变**，而拾取变了（更迷惑） |
| `MeshBasicMaterial` 没有 `map` | `GLTFLoader` 注释写着「keep the texture load so the decode is warm but **do not attach it**」 | `KHR_materials_unlit` + `baseColorTexture` 的模型（很常见的导出形态）渲染成**纯色团** |
| `Scene.fog` | M17 登记为「未实现 + 一次性诊断」（D114） | 雾是**逐片元 mix**，不是开关，只能用程序变体做 |
| `Scene.background` 贴图 / skybox | 只有 `Color` 走 `clear()`（D113） | 天空盒与 2D 背景是独立 draw，不是清屏色 |

### 25.1 D126：不透明材质的 `NormalBlending` 必须退化成 `NoBlending`

three.js 只解**一种**情况（`WebGLState.js:763-766`）：

```js
( blending === NormalBlending && transparent === false ) ? NoBlending : setBlending(blending)
```

注意它**只**管 `NormalBlending`：`AdditiveBlending` 写在 `transparent=false` 的材质上，
three.js 照样按 additive 画（作者的意图很明确，不该替他改）。所以门禁是一个纯函数：

```as3
public static function effectiveBlending(blending:int, transparent:Boolean):int
{
    if (!transparent && blending == Material.NormalBlending) return Material.NoBlending;
    return blending;
}
```

除了语义正确，这一条还让不透明 draw 不再进入「读目标缓冲」的 ROP 路径（目标因子成了 `zero`），
也就是 §24.7 / R39 记录的那条路径。**但 LSB 噪声没有因此消失**：M19 → M20 的 `env-m9` 仍有
**0.611%** 的像素差 1–2 个色阶（差 >8 色阶的只占 0.052%，且集中在窗口边框），说明除 ROP 之外
还有别的舍入来源（sRGB 编解码往返、`exp` 近似、MSAA 解析）。R39 继续按「后端精度、非语义」
登记，不撤。

### 25.2 D127：阴影 pass 在递归**之前**剪掉隐藏子树

three.js `WebGLShadowMap.js:522` 是 `if (object.visible === false) return;`——判在遍历里、
判在递归之前，所以整棵子树都不进阴影图。本端口照抄这个位置：`_renderShadowObject` 的第一行
就是 `if (!object.visible) return;`。**判在 mesh 层是不够的**（M20 之前就是这样）：`Group` 上
的 `visible=false` 在 three.js 里是「这个分支整个不画」，阴影也不例外。

### 25.3 D128：`drawRange` 是**渲染**约束

`BufferGeometry.drawRange = {start, count}`，单位是**索引**（非索引几何是顶点），`count` 取
「无限」在本端口用 `-1` 哨兵（D7 的同一约定，拾取侧早就这么用了）。映射成 Stage3D 的
`drawTriangles(indexBuffer, firstIndex, numTriangles)`，**不需要重传缓冲**——第三、四参本来
就吃偏移与个数。四条防御：

| 情况 | 处置 |
|---|---|
| `start < 0` | 夹到 0 |
| `start` 落在三角形中间 | **向下取整到三角形边界**（`int(start/3)*3`） |
| `count` 超过剩余容量 | 夹到 `totalIndices - first` |
| 剩余不足一个三角形 / 越界 | 画 **0** 个三角形（返回前直接 return，不调 draw） |

两个调用点都必须走同一对函数：主 pass（`_renderMesh`）与**阴影 caster pass**（否则「画一半的
网格投完整影子」）。表现上有个容易误判的地方：索引是**几何自己的发射顺序**，`PlaneGeometry`
是行主序，所以 `setDrawRange(0, 450)`（600 索引 / 200 三角形）缺的是**尾部 2.5 行**，画面是
一条阶梯缺口而不是「切掉右三列」（demo `apps/scene-m20` 的面板 F 就是这条，见 §25.10）。

### 25.4 D129：`MeshBasicMaterial.map`（unlit 贴图不再被丢）

`map_fragment.glsl.js` 是 `diffuseColor *= sampledDiffuseColor`——**rgb 和 alpha 一起乘**。所以
`map` 不是装饰：它让 unlit 材质有镂空（`alphaTest`）与透明度，这正是 glTF `KHR_materials_unlit`
带 `baseColorTexture` 时该有的样子。程序变体键 `map:decode:fog` 三段（有没有贴图 / 要不要
sRGB 解码 / 要不要雾），三者都是编译期常量，无贴图的场景指令数一分不涨。

### 25.5 D130：`Scene.fog` 是逐片元 mix，且**只加在 base pass**

three.js `fog_fragment.glsl.js` 是 `mix(gl_FragColor.rgb, fogColor, fogFactor)`，`fogFactor`：

| 类型 | 公式 |
|---|---|
| `Fog` | `smoothstep(fogNear, fogFar, vFogDepth)` |
| `FogExp2` | `1 - exp(-density² · vFogDepth²)` |

`vFogDepth` 在 three.js 是 `-mvPosition.z`（视图空间深度）。本后端没有 `vViewPosition` 这个
varying，所以用**世界位置差分再点乘相机前向**算同一个量：`depth = dot(worldPos - camPos, camForward)`，
相机前向取 `matrixWorld` 第二列取负（`+Z` 是相机背后）。常量 `fc37..fc40`：

```text
fc37 = (near, far, density, 0)
fc38 = (camPos.xyz, 1)      // w 也当常数 1 用（1 - exp / 1 - f）
fc39 = (camForward.xyz, 3)  // w 借位当常数 3（3 - 2t）
fc40 = (fogColor.rgb, 0)
```

两条 AGAL 现实约束：**没有 `smoothstep`** ⇒ 手写 `clamp → t²(3-2t)`；**没有底数为 2 的指数**
⇒ 用自然 `exp`（与 D48 的 EnvBRDF 同一处理）。`fogFactorAt()` 是这段 AGAL 的 CPU 镜像，探针
用它把 shader 钉在参考实现上（无需 GPU）。

**只加在 base pass**（R40）：本后端的 punctual 是**逐光 additive pass**，每 pass 都加一次雾色
会把雾的颜色叠 N 次（灯越多雾越亮）。所以 `fogOn = material.fog && _fogMode != FOG_NONE && _activePass == 0`。
`Material.fog`（three.js 同名，默认 `true`）是逐材质 opt-out，与 `scene.fog` 相同作用域语义。

### 25.6 D131：`Scene.background` 三态

| `scene.background` | 本端口做法 | 与 three.js 的对齐点 |
|---|---|---|
| `Color` | `clear(color)`（D113：按**已编码**的 sRGB 值清） | 一致 |
| `CubeTexture` | 单位立方体 + **只留旋转**的视图矩阵（相机位清零）画在相机位置，`culling "back"`（相机在盒内）、深度不测、不混合，`fs0` 绑 cube | three.js 是 `BoxGeometry` + `side=BackSide`；我们是「盒子不动、相机位置从视图矩阵里抹掉」，等价且不用求逆 |
| `Texture` | 一个 clip-space 四边形，uv 走**贴图自己的**变换矩阵（`vc40/vc41`，与 M18 同一套），深度不测、不混合 | three.js 是 `PlaneGeometry(2,2)` + `depthTest=false`；我们把「近平面裁剪」交给 NDC 直接出 |
| 其它对象 | 一次性诊断 + 清黑（R42） | three.js 会当错误静默忽略；我们**报明** |

背景**先画**（clear 之后、场景之前），与 three.js 的 `autoClear` 语义一致。色调映射有个反直觉
的地方见 R42：sRGB 背景贴图走 **decode 变体不做色调映射**（three.js 给背景贴图设
`toneMapped = false`），普通变体才走「色调映射 → R7 输出编码」。

### 25.7 R43：深度清除曾整帧丢失（后端 glue 缺陷，M20 顺手修）

M20 的 blend 面板一开始「半透明那块看不到背后的绿条」，查下来**不是 AS3 侧的问题**，而是
Metal 后端的 pass 编码：

- 症状：`(transparent=false, opacity=0.45)` 的 D 面板背后那条绿条**完全消失**，把面板的
  `depthTest` 关掉又「好了」。
- 根因：pass 是否挂**深度附件**原本只看「本次 draw 需不需要深度」，而 M20 新加的背景四边形是
  `depthCompare = "always"`（全屏、不测深）⇒ 本帧的深度附件不挂载 ⇒ 挂在它上面的 pending
  **深度清除被一并丢弃** ⇒ 深度缓冲保留**上一帧**的内容 ⇒ 后画的不透明面被「上一帧的深度」
  拒绝。之前的 demo 之所以没暴露，是因为没有「本帧第一个 draw 不需要深度」这种情形。
- 修法（`as3compiler/vendor/stage3d_glue.mm`）：只要本帧有 pending 的 depth/stencil clear，
  就**强制挂载**深度附件，让 load action 真的执行那次清除：
  `if (c->clearPending && (c->clearDepth || c->clearStencil)) dsNeeded = 1;`
  同一处顺带补上 MSAA 路径的 depth-stencil 附件（此前 `ASC_S3D_MSAA>1` 时深度无人承接）。

这是**运行时后端**的修复，不是 asaot3d 的语义改动；影响面覆盖全部 19 个 demo 与 Starling
基准（31,344 个对象、120 fps、无异常，见 §25.10）。

### 25.8 R44：寄存器超过 AGAL1 上限时**必须**按版本 2 汇编

`AGALMiniAssembler` 默认 version 1，**寄存器操作数索引上限是 28**。M20 新程序用到 `vc40/vc41`
与 `fc36..fc40`，default 版本下汇编器**不抛异常**，只产出零长度字节码，于是运行时才炸：

```text
Uncaught exception: AGAL: bytecode too short for header
error: register operand 2 (36.xxx) index exceeds limit of 28.
```

硬不变式：**任何用到 `vc40+` / `fc36+` 的程序都要 `assemble(..., 2)`**。这条已经适用于
standard / punctual（既有），M20 起适用于 `_buildBasicProgram` 与 `_buildBackgroundProgram`。
教训值得单列：汇编失败是**静默**的（长度 0），所以新增程序后必须看 trace 里的 `v=`/`f=` 计数，
而不是只看「有没有异常」。

### 25.9 M20 明确不落（登记遗留）

- **雾**：线段/线框程序不含雾（R41）；punctual additive pass 不含雾（R40）；不支持自定义 fog
  chunk；`FogExp2` 的 `exp2` 用 `exp` 换算（数学等价，指令数略多）。
- **背景**：`RenderTarget` 背景、`VideoTexture` 背景、`CubeTexture` **数组**（three.js 的多层
  背景）、背景 `backgroundIntensity`/`backgroundBlurriness` 都不做（R42）。
- **`MeshBasicMaterial.map`**：不进 punctual pass（unlit 本来不吃光）；不参与 `envMap`
  的 UV 变换（与 M18 留下的同一条遗留）。
- **`drawRange`**：只按索引语义实现；`geometry.groups` 的多材质分段仍不做（`Mesh.material`
  是单值）。
- **`Material.blending` 的逐材质因子**（R35）不变；`depthFunc` 等（§24.9）不变。

### 25.10 验收

- **探针** `probes/scene-smoke-m20/`：**56 项 ALL PASS**——A 混合门禁 9（不透明 `Normal` 退化 /
  透明不退化 / **不透明 `Additive`·`Multiply` 不被降级** / `CustomBlending` 原样透传到
  `setBlendFactors` 那一层 / 门禁后的因子对 `("one","zero")` 与 `("sourceAlpha","oneMinusSourceAlpha")`）、
  B `drawRange` 14（默认 0 与 `-1` 哨兵、`start=3`/`count=6`、`-1` 到底、超容量夹取、起点在末尾 /
  越过末尾画 0 个、三角形中点向下取整、尾部残缺三角丢弃、负 `start` 夹 0、空缓冲）、
  C 雾模式与因子 16（三模式互异 + 未知对象回落 `FOG_NONE`；线性 near=0 / far=1 / 中点 0.5 /
  两端夹取 / 四分之一处 = `smoothstep(0.25) = 0.15625`；`exp2` 在 0 处为 0、对上
  `1-exp(-(d·density)²)`、单调、值域）、D 雾默认值 7（`Fog` 白 / 1 / 1000、`FogExp2` 0.00025、
  `isFog`/`isFogExp2`、雾色**解码到线性**）、E 默认值 9（`Material.fog=true`、
  `MeshBasicMaterial.map=null`、`scene.fog`/`scene.background=null`、`Color` 背景可存、
  `fogModeOf` 不把背景对象当雾）。
- **示例** `apps/scene-m20/`：一块屏九组判据（`temp/m20b-scene-m20.png`，2400×1864）：

  | 面板 | 判据 | 实测 |
  |---|---|---|
  | A / B | `map` = 条纹 vs `null` | 条纹 `(240,240,240)`/`(63,126,187)` vs 纯灰 `(127,127,127)` |
  | F | `setDrawRange(0,450)` / 600 索引 | trace `150 of 200 triangles drawn`；画面缺尾部 2.5 行（阶梯） |
  | D | `transparent=false, opacity=0.45` over 亮绿条 | 填充 **`(235,72,113)` 纯粉**（绿条只留在格子外侧）⇒ 不透 |
  | E | 同参数但 `transparent=true` | 填充 **`(147,162,132)`**（粉与绿混）⇒ 真的混了；绿条本底 `(125,251,154)` |
  | G | 两条同样的长盒，上 `fog=true` 下 `fog=false` | 上条远端**染成雾色棕**、下条全程保持蓝 ⇒ 逐片元 mix + 逐材质 opt-out 同时成立 |
  | H | 右组的 caster 在 `Group.visible=false` 里 | 左墙阴影覆盖 **15.89%**（最暗 sum 237）vs 右墙 **0.00%**（最暗 sum 509）⇒ 幽灵影子消失 |
  | 背景 | `Scene.background = 2D 棋盘 Texture` | 棋盘 `(20,22,27)`/`(33,35,43)` 铺满视口；`CubeTexture` 版（`temp/m20-skybox.png`）是紫色渐变天 + 白色地平带 |
- **回归**：`apps/` **19 个 demo** 全部重编链接、起窗无错（19/19 构建 OK，`grep -ciE "error|too short|exceeds limit"` 于运行日志全 0）；`probes/` **24 组全绿**（**1060** 项 PASS + `loader-smoke-m5`/`asset-load-probe` 两组自带格式，0 FAIL），上一轮 23 组 983 项，本轮 +`scene-smoke-m20` 56 项。
- **指令预算**：标准片元 `163/400`（`fog=0`）、`241/400`（阴影、`fog=0`）、**`256/400`（阴影 + 雾，
  +15）**；`env-m9`/`gltf-m8`/`alpha-m10`/`shadow-m7` 与 M19 逐项相同。新增变体只有
  basic（`map`/`decode`/`fog` 三段键）与四个背景程序。
- **像素级回归（M19 → M20）**：`texstate-m17` **0.03%**、`uv-m18` **0.03%**、
  `interaction-m14` **0.04%**——与**两次独立构建各自截图的噪声底 0.03% 相同**（同一份源码重编重拍），
  即为测量噪声（窗口位置 1px 抖动 + 后端舍入）；
  `env-m9` **0.76%** 里强差（>8 色阶）只占 0.051%，集中在窗口边框像素；`alpha-m10` **0.38%**，
  强差掩膜**只有高光边缘一圈 1px 轮廓**与窗口边框（球面与玻璃逐点相同，见
  `temp/z-adiff.png`）；`shadow-m7` 1.74% / `shadow-m13` 3.71% 而**同版本两次截图差
  2.90% / 5.42%**（更大）⇒ 逐帧动画的帧相位，不是回归。
- **Starling 冒烟**（R43 是后端改动，必须跨引擎验）：`Starling-Demo` 基准跑到 **31,344 对象、
  ~120 fps**，`fail` 计数恒 0，无异常（`temp/m20-starling.png`）。

---

## 26. AIR 参考运行通道 + 双后端构建（D133–D137、R46–R53，2026-10-31 M21 拍板）

M1–M20 的所有验收都跑在 **as-aot** 上。AIR（`mxmlc` + `adl`）一直是「语义基线」，
但从未真正跑起来过——不是不想跑，而是它启动就把门关上了：AGAL 版本、profile、
操作数合法性、流/采样器绑定、纹理完整性，AIR 逐条查，as-aot 逐条放行。本轮把这些
差异一次性摊平，并把「跑 AIR」做成一键操作。

### 26.1 双后端构建：`apps/<demo>/build.sh`

```
./build.sh              # AOT（默认）：.as → C → Mach-O
./build.sh air          # .as → build/<Main>.swf（mxmlc），用 adl 跑
./build.sh aot --run    # 构建后直接启动（阻塞）
./build.sh --help
```

- **实现只有一份**：`tools/build-demo.sh`；每个 `apps/<demo>/build.sh` 是一个 5 行转发
  入口（`exec "$HERE/../../tools/build-demo.sh" "$HERE" "$@"`）。19 个 demo = 19 个入口，
  一份实现 ⇒ 两个后端不可能在 demo 之间漂移。
- **任意 cwd 可用**：脚本自己算出仓库根，并**在仓库根执行**两个后端。这不是洁癖：demo 用
  相对路径读资产（`assets/models/gltf/Duck.glb`），而 `adl` 以描述符所在目录解析
  `<content>`，只有「cwd = 仓库根」时两条路径才指向同一批文件。
- **描述符与主类从文件名推导**（`<Main>-app.xml` → `src/<Main>.as`），并断言两者都在；
  重命名漏改会在脚本里立刻报错，而不是掉进编译器的深层报错里。
- **AIR SDK 必须被找到，不能被假设**：`$AIRSDK_HOME` → 常见安装路径（`sort -rV`，新的
  优先）→ `PATH` 上的 `mxmlc`；每个候选都验 `bin/mxmlc` 可执行。找不到就**报错退出**，
  绝不静默跳过——「构建绿了但从没跑过要对齐的运行时」是本项目最不能接受的结果。
- **必须用 AIR 的 playerglobal**：`-load-config=frameworks/air-config.xml` +
  `-external-library-path=frameworks/libs/air/airglobal.swc`。默认 Flex 配置面向浏览器
  player，`flash.display3D.*`、`VsyncStateChangeAvailabilityEvent`、`getTimer` 全部不认识。
- `-debug=true` 仍然要有：release SWF 会把 `trace()` 整条剥掉。但**别把 AIR 的可观测性
  押在 `trace()` 上**——`adl` 在 macOS 不转发它（§26.7）。要在 AIR 侧看到日志，写
  `System.output()`；`-debug=true` 的作用是「万一将来换到有 trace 转发的运行环境还能看见」。
- `-compiler.strict=false` **只**为 SWC 滞后于运行时的少数成员开（`setCubeTextureAt`、
  `refreshRate`）；缺 import、缺 `override` 这类**真缺陷一律改源码**（见 §26.2）。

### 26.2 AIR 编译期暴露的真缺陷（不是被 strict 关掉的噪音）

| 症状（mxmlc） | 真因 | 处理 |
|---|---|---|
| `找不到类型 … Texture/VertexBuffer3D/Dictionary/getTimer` | 缺 import；`AGALRenderer` 里用全限定名声明 `flash.display3D.textures.Texture` 却没 import 该包 | 补 import（D133 附带） |
| `覆盖没有为 override 标记的 function` | `Mesh.raycast`、`OrthographicCamera/PerspectiveCamera.updateProjectionMatrix` 确实在覆盖父类 | 补 `override` |
| `不兼容的 override`（`TextureLoader.load`） | 基类 `Loader.load():void`，子类返回 `Texture`。AS3 没有「`void` ↔ 具体类型」的协变，`*` 也救不了（`void` 不是 `*` 的子类型，mxmlc 同样报错） | **D133**：`Loader` 不再声明 `load`，各 loader 各自声明；去掉 `override` |
| `与继承的定义 name 冲突`（`StatsPanel`） | `StatsPanel extends Sprite`，又声明 `public var name:String`——遮蔽了 `DisplayObject.name` | **D134**：删掉该字段，用精灵自己的 `name` |
| 单文件里多个包级类 | AIR 只认一个文件一个包级类，且 `flash.display3D.*` 的解析与包声明绑定 | 拆分 GPU 缓存类到独立文件（`GPUMeshResources`/`GPUTextureResources`/`GPUCubeResources`/`GPULineResources`，D135） |

### 26.3 AGAL 版本与 Context3D profile 是**一对**决策（R46）

实测矩阵（AIR 51.4.1，逐格用同一段 `mov`+`add` 程序上传）：

| profile | AGAL v1 | v2 | v3 | **v4** |
|---|---|---|---|---|
| `baseline` | ✗ | ✗ | ✗ | ✗ |
| `baselineExtended` | ✗ | ✗ | ✗ | ✗ |
| `standard` | ✗ | OK | ✗ | ✗ |
| `standardExtended` | ✗ | OK | OK | ✗ |
| **`enhanced`** | ✗ | OK | OK | **OK** |

- 该项目要 `vc40` 起的 UV 变换行、`fc36` 的解码指数、`fc37+` 的雾常量、`fs7` 的环境立方体，
  早已越过 v1/v2 的寄存器文件 ⇒ **v4 + `enhanced`**：
  `stage.stage3Ds[0].requestContext3D("auto", "enhanced")`，
  `AGALRenderer.AGAL_VERSION = 4`。两处必须同时改，改一处就是 `#3725`（版本与 profile 不匹配）。
- as-aot 侧同步放宽：`as_agal_translate()` 的头部检查由 `version > 3` 改为 `version > 4`
  （v1–v4 的指令编码/槽位布局一致，本项目不发射 v4 独有 opcode），指令预算 200 → 400。
  钉子：`test/unit/stage3d.ts` 的 `stage3d/agal-versions`。

### 26.4 常量源操作数必须在装配期消解（R47，D136）

AIR 对「源操作数是常量」的检查比想象中严：

- **两个源都是常量** → `#3625`（"Both are constants (this must be precomputed)"）。
  本轮真实命中：雾的 `sub ft2.z, fc37.y, fc37.x`、PCF 的 `mul ft11.xy, fc24.xy, fc27.xy`。
- **单源算术指令拿常量源同样非法** → 同样 `#3625`；逐 opcode 实测
  `rcp/rsq/sqt/frc/nrm/abs/neg/sat/exp/log/sin/cos` 全拒，`mov` 是唯一例外。

处理分两层，**都不改变数值语义**：

1. **能上 CPU 就算在 CPU**（AOT 也更快，用户要求「AOT 性能优先」）：线段程序里两个
   `rcp vt5.x, vc4.x`（每帧不变的视口倒数）改成 CPU 预算的 `vc5 = 1/(halfW, halfH)`，
   顶点指令从 `rcp+rcp+mul` 变成一条 `mul`；雾的 `1/(far-near)` 同理预计算进 `fc37.w`。
   这类「结果的输入全是常量」的算式，GPU 再算一遍纯属浪费。
2. **其余交给装配器统一改写**：`AGALMiniAssembler` 新增
   `validateAirOperands()`（先查，报错带行号）+ `hoistConstantOperands()`（把其中一个常量
   `mov` 进空闲临时寄存器，再原样执行原指令）。装配器产出的字节码因此**同时**是 AIR 合法、
   as-aot 可译的，不必在渲染器里逐个 AGAL 字符串打补丁。改写对合法程序是 no-op。
   临时寄存器不够用时（如 AGAL1 的 8 个 vt 全占）装配器**报错**而不是悄悄跳过。
   > **踩过的坑**：第一版改写只把 `args.join(",")` 拼回去，于是**操作码和目的寄存器都丢了**
   > ——主循环把它当坏行跳过，指令**从程序里消失**而不是被修好。症状极具欺骗性：只多一行
   > `warning: bad line 2:  ft1.xy,ft2, fc27.xy`，程序照常上传、照常出画面（因为丢的是
   > 已经不合法的那条指令）。现在按「整行重建」写：`head + " " + 逐参数（只替换选定源）`，
   > 探针 `temp/agalprobe2/HoistProbe` 钉住「N 行源码 → N+常量改写条数」的算术。

### 26.5 绘制状态必须与当前程序**精确**一致（R48、R49）

- **顶点流**：AIR 对「设了但程序不读」的流报 `#3607`。渲染器原先无条件绑 va0/va1/va2，
  而 unlit 程序不读 va1 ⇒ 第一帧就炸。现在装配每个 `Program3D` 时扫描其顶点源，记一张
  `Program3D → {va0,va1,va2}` 掩码表，绘制前**按掩码绑定**，未读的槽显式 `null` 解绑
  （阴影 pass 也走同一条路，深度程序只读 va0）。
- **采样器**：同理由片元源扫出 `fs0..fs7` 掩码 ⇒ 绘制前解绑未采样的槽（`#3697`：绑了但
  程序不采）。阴影 pass 用的是不采样任何纹理的深度程序，所以在 `setRenderToTexture` 之后
  `_unbindAllSamplers()` 清掉主 pass 留下的绑定。

### 26.6 纹理完整性：立方体要**整条** mip 链（R50）

- AIR `#3700`"incomplete texture"：采样器开了 mip 过滤而链不全。本轮实际命中的不是 2D 贴图，
  而是 **环境立方体**——即使采样器写 `mipnone`，AIR 仍要求六个面**每一级**都上传。
  `uploadCubeChain()` 逐面逐级折半上传（`BitmapData.draw` 双线性，与 2D 链同一公式）。
- 顺带纠正一个挂了很久的参数误用：`createTexture(w,h,fmt,第4参数)` 的第 4 个参数是
  **`optimizeForRenderToTexture`，不是 mip 开关**。此前把「要不要 mip 链」传进去，AIR 便按
  渲染目标分配、没有 mip 存储，采到非 0 级就报 `#3700`。2D 采样贴图一律传 `false`，
  mip 链完全由 `uploadFromBitmapData(level)` 决定。

### 26.7 adl 的可观测性与环境陷阱（R51、R52）

- **`adl` 在 macOS 既不转发 `trace()` 也不打印未捕获错误** —— 但
  **`flash.system.System.output()` 到 stdout**（[System 文档](https://airsdk.dev/reference/actionscript/3.0/flash/system/System.html#output())）。
  这是本轮找到的最重要一条可观测性事实：日志通道从此统一到 `System.output`，两端同一格式。

  实测（AIR 51.4.1 / macOS arm64 / `adl`）：同一段输出（`A-1\n` / `B\t2\n` / `C1.5\n` /
  `D 42 true\n`，含 `String(1.5)`、`+` 拼接、空串与制表符）在 AOT（`as_system_output` =
  `fputs`+`fflush`）与 AIR（`adl` 的 stdout）上**字节完全一致**；同一份源码里的 `trace()`
  在三行里**一行都没出现**（stdout、stderr 都没有）。

  - `System.output` **不加换行**，也不做任何格式化：换行、缩进、`\t` 全由调用方写。
  - 因此宿主把它收成一个私有出口 `Stage3DApp.logLine(s)`（`System.output(s + "\n")`），
    `ready` / `display Hz` / `resize` / `Stage3D error` / `frame error` + 堆栈全走它。
  - **不要**在 `logLine` 里同时 `trace()`：as-aot 的 `trace` 也写 stdout，实测把每行打了两遍。
  - AIR 侧冒烟现在**可以只看 stdout**（`grep "Stage3DApp ready"` 判起窗、
    `grep "frame error"` 判失败），不必截屏读标题。窗口标题（`render error: …`）降级为
    **第二通道**保留：stdout 被启动器吞掉时它还在，旧的回归脚本也仍在读它。
  - 失败时的堆栈也走这条通道。实测抓到过：
    ```
    Stage3DApp frame error: Error #1502: A script has executed for longer than the default timeout period of 15 seconds.
        at asaot.three.math::Matrix4/copy()[.../Matrix4.as:73]
        at asaot.three.core::Object3D/updateMatrixWorld()[.../Object3D.as:198]
        at asaot.three::AGALRenderer/render()[.../AGALRenderer.as:650]
    ```
    在只有窗口标题的年代，这条只能看见 `render error: …` 的第一句，堆栈要靠改代码去拿。
- **`#1502` 不是 App Nap，是脚本看门狗**（本条的旧结论已修正）：窗口在屏内、在屏外、
  前台、后台、`-debug=true`、`-debug=false`、`<scriptTimeLimit>0|3` —— 六种组合下
  「约 15 s 后 `#1502`」都一模一样；只有 `ENTER_FRAME` 计数的极简探针能跑满 30 s。
  ⇒ 计的是**累计脚本执行时间**，我们的渲染器单帧脚本开销吃满帧预算才会被砍。
  完整测量与下一步见 **§26.11.6**。
- **仍需把窗口拉进工作区**：`adl` 有时把窗口放在屏幕外（实测
  `position = (747, -969)`、`height = 900`）。此时 `refresh` 读数为 0、`frameRate` 停在 60，
  且截图拿不到内容。判读前先读一次窗口坐标并 `set position` 归位。
- **`adl` 从不报告面板刷新率**：AIR 侧的 `refresh` 恒为 `0`（放在屏内跑满 20 s 也是 0），
  所以 AIR 下 `stage.frameRate` 停在默认 60，而 AOT 侧同一份代码读到 120 并同步为 120。
  这不是回归也不是缺陷：`refreshRate` 的可用性取决于后端，宿主已按「0 ⇒ 保持现值」处理
  （见 §M16 `frameRateForRefresh`）。**因此帧率不能作为双端一致的判据**，画面才是。
- 增强/私有字段（`VsyncStateChangeAvailabilityEvent.refreshRate`）一律**动态访问**并加
  try/catch，不静态引用：SWC 里没有的成员静态访问会让 `mxmlc` 报「可能未定义」。

### 26.8 钉子（探针）必须钉渲染器的**真源**

探针里有三处「手抄一份渲染器的 AGAL 源」，本轮全部暴露成假绿：渲染器改了、探针还停在旧
口径，于是「探针红」和「渲染器坏」分不开。

- **线段程序**：`AGALRenderer.lineVertexSource()` 成为唯一源（`_buildLineProgram` 与
  `probes/geometry-smoke-m11` 汇编同一段文本）。此前副本漂移过两次（`mov op` 那次、
  `rcp`-on-constant 那次），所以副本被判为不可接受。
  > 顺带踩到 AS3 的**自动分号插入**：把 `return` 单独换行、表达式写在下一行，等于
  > `return;`。`lineVertexSource()` 第一版就这么写，返回 `undefined` → 装配器在
  > `source.replace` 上抛 `#1009` → **19 个 demo 的第 1 帧全炸**（后续帧恢复，所以
  > 只看截图完全看不出来）。报错信息来自 `err.getStackTrace()`，而 as-aot 的
  > `Error.getStackTrace()` 是 shell stub，于是只留下一行
  > `[as3-aot] not implemented by this build`。定位手段：把栈写进窗口标题，在 AIR 里读
  > 真实行号（`AGALMiniAssembler.as:132`）。
- **探针里手写的片段尾**：`mov oc.xyz, …` + `mov oc.w, …`（`agal-m6`、`alpha-smoke-m10`）
  改成 `mov ftN.w, …` + `mov oc, ftN`（#3701，`oc` 必须一条指令写全）；
  `kil ft1` 补标量 swizzle 成 `kil ft1.xxxx`（#3703）。
- **指令数钉子**：线段程序 30 → **28**（两个常量 `rcp` 和那个 `mul` 由一条 `vc5` 的 `mul` 取代）；
  PCF 片段 84 → **85**（装配器把 `fc24.xy` 提进临时寄存器的那一条 `mov`）。
- **`mipFilterFor` 的「无链」拼写**：`"none"` → `"mipnone"`（#2008）。
- **`asset-load-probe` 的 `Loader`**：写成 `flash.display.Loader`——`asaot.three.loaders.Loader`
  与它在同一编译集里，短名会解析到我们自己的类，而 `contentLoaderInfo`/`loadBytes` 只在
  built-in 上。

### 26.9 验收（本轮）

- **构建**：**38/38**（19 个 demo × AOT + AIR）全部通过。
- **运行**：AOT 19/19 起窗、stderr 无错误行；AIR 19/19 起窗、窗口标题无 `render error`。
  `scene-m20` 双端截图逐项对上（棋盘背景 / A·B 条纹面板 / drawRange 缺口阶梯 /
  D·E 混合面板 / G 雾条 / H 阴影对）：`temp/m21-scene-aot.png`、`temp/m21-scene-air.png`。
- **探针**：`probes/` **24/24 组 0 FAIL、1044 项 PASS**（`loader-smoke-m5`、
  `asset-load-probe` 自带汇总文案），其中 6 组跑各自的 `.build.json`（skia 解码）。
- **编译器回归**：`node test.ts` 全量 **589 tests / 589 pass / 0 fail**（+新增
  `stage3d/agal-versions` 3 项）。

### 26.10 R54 / D138：CPU 预算的常量必须**真的上传**（雾失效事故，M22 修）

R47 让「两个常量源操作数」在装配期就被消解，但还有一类更贵的形态：**常量算式本身**。
`far - near` 是两个常量相减，`rcp` 又是单源常量算术 —— 在 AIR 里两样都不合法，在 AOT 里
则是一条白跑的指令。于是这类算式搬到 CPU 预算：

| 位置 | 原 GPU 形态 | 现在 | 收益 |
|---|---|---|---|
| 线性雾 | `sub t0.z, fc37.y, fc37.x` + `rcp t0.z, t0.z` + `mul` | `mul t0.y, t0.y, fc37.wwww`（`fc37.w = 1/(far-near)`，CPU 算） | −2 指令，两端合法 |
| 线段程序 | `rcp vt5.x, vc4.x` + `rcp vt5.y, vc4.y` + `mul` | `mul vt4.xy, vt4.xy, vc5.xy`（`vc5 = 1/halfViewport`，CPU 算） | −2 指令；且 AGAL1 的 `vt0..vt7` 已用满，根本没有临时寄存器可搬 |

**代价与红线（D138）**：预算出来的常量**必须真的写进常量上传**。第一版只改了 shader、
没有改上传（`_fogConst[3]` 还是字面量 `0`），于是 `t = (d-near) * 0 = 0` ⇒ 雾因子恒 0 ⇒
**雾在 AOT 与 AIR 两端同时彻底消失**。而这个失败对当时的全部证据都是隐形的：

- `probes/scene-smoke-m20` 的 C 节验的是 `fogFactorAt()` —— 那是**另一份算术**（CPU 镜像），
  它仍然正确，所以 56 项全绿；
- 双端截图**互相**一致（两端都坏，坏的形状一样），「AIR 与 AOT 像素一致」这条判据照过；
- 没有任何错误、没有任何 `trace`、帧时间与 draw 数都不变。

这正是 §26.8 那条教训的更硬版本：**探针钉的必须是渲染器真正消费的那份数据**。修法不是再加一句
注释，而是把「打包」变成可测的纯函数：

- `AGALRenderer.linearFogScale(near, far)` —— `fc37.w` 的**唯一定义**（`fogFactorAt` 也用它，
  消灭了「镜像 vs shader 两套算术」）；
- `AGALRenderer.packFogConstants(out, fog, matrixWorldElements):int` —— 填 `fc37..fc40` 的纯函数，
  `_resolveFog()` 只是调用它；
- 钉子 `probes/scene-smoke-m20` **C17–C25** 九条：尺度值、退化区（`far == near`、NaN）、
  `fc37` 四分量、`fc38/fc39` 布局、`FogExp2` 不写 `fc37.w`，以及一条直接的回归闸
  （`fc37.w != 0`）。

**复核证据（双端像素）**：`temp/m22-scene-aot.png`、`temp/m22-scene-air.png` 的 G 雾条远端
重新出现雾棕像素簇（与 M20 的 `temp/m20b-scene-m20.png` 同形）；`env-m9` 与 M20 逐像素比对
`mean=0.000 max=0 → 0.00%`，证明这轮 CPU 预算没有波及别处的光照。

**顺带澄清两个不是原因的假设**：

- **HDR**：本构建的默认档位（`baselineExtended`）里 AOT 的颜色附件、RTT、cube 与几何缓冲上传
  全程 `MTLPixelFormatBGRA8Unorm`，**没有 float 渲染目标**；float RT 只在 opt-in 的 `standard`
  档（`ASC_S3D_HALF_TEXTURES`）出现，而 cube 在任何档位都没有 float 存储（实测 §36.2）。
  所以不存在「AOT 有 HDR、为 AIR 降级」这回事；色调映射本来就是在 8 位目标上做的。
- **AGAL 版本**：v2 → v4 只抬高寄存器与指令上限（`vc` 249 / `fc` 199 / `vt`·`ft` 25），
  不改变任何一条指令的算术或精度，画面上不可见。


**唯一的遗留 AOT/AIR 差异是 MSAA**：AOT 侧是 `ASC_S3D_MSAA=2|4` 环境变量 opt-in
（`vendor/stage3d_glue.mm`），AIR 侧对应的是 `Context3D.configureBackBuffer(w, h, antiAlias, …)`
的第三个参数，而渲染器现在传的是 `0`。默认两端都是单采样，所以**不是回归**；要在 AIR 上也开
抗锯齿，需要把同一个 opt-in 暴露成 AS3 侧的静态开关再传给 `configureBackBuffer`（登记为遗留，
未实装）。

### 26.11 日志通道：`System.output()` 取代 `trace()`（R55，2026-11-01）

上一节把 AIR 跑起来了，但「跑起来」和「能看见」是两件事：`adl` 在 macOS 上
**既不转发 `trace()`、也不打印未捕获错误**，所以 M21 的 AIR 证据全靠截屏读窗口标题。
本轮把日志通道换掉，顺带修掉三个被「看不见」掩盖的真缺陷。

#### 1. 通道本身（实测）

[`flash.system.System.output(str)`](https://airsdk.dev/reference/actionscript/3.0/flash/system/System.html#output())
**到 stdout**，`trace()` 什么都不到。同一段源码（`A-1\n`、`B\t2\n`、`C1.5\n`、
`D 42 true\n`，含 `String(1.5)`、`+` 拼接、空串、制表符）两端字节完全一致：
AOT 走 `as_system_output`（`fputs`+`fflush`），AIR 走同一 stdout。

- **不加换行、不做格式化**：换行/缩进全由调用方写。
- 宿主收成一个出口 `Stage3DApp.logLine(s) == System.output(s + "\n")`；19 个 demo 自己的
  证据行（`M17 …`、`M20 …`、`AGALRenderer: …`）也全部改走它，两端**同一行同一格式**。
- **不要**同时 `trace()`：as-aot 的 `trace` 也写 stdout，实测每行打两遍。
- 窗口标题（`render error: …`）保留为第二通道：stdout 被启动器吞掉时它还在。

#### 2. adl 的 stdout 是**缓冲**的

写完不立刻可见：实测一次 10 s 的运行，结束时 419 B，`kill` 之后变 1158 B。
⇒ **判读前先结束进程再读日志文件**，否则「日志还没出来」会被误读成「没有日志」。

#### 3. AIR 的相对资产路径以 **SWF** 为基准（#2032）

`loaderInfo.url` 是 `app:/build/<Main>.swf`，所以 `assets/textures/uvgrid.png` 在 AIR 里变成
`app:/build/assets/...`，五个 demo（`texstate-m17`、`env-m9`、`gltf-m8`、`uv-m18`、`asset-load`）
因此静默丢贴图（只打一条 `IOErrorEvent`，画面照常但贴图缺）。AOT 以 cwd（仓库根）为基准，
所以一直是对的——这就是「双端都绿」的假象来源。

- 修法：`tools/build-demo.sh` 在 AIR 分支把 `assets/` **链接到 SWF 旁边**
  （`ln -sfn "$REPO_ROOT/assets" build/assets`）。真实的 AIR 包本来就是把资产装在包里，
  这不是权宜之计。
- **必须用绝对路径的软链**：播放器**不解析** URLRequest 里的 `..`（实测
  `../assets/...`、`../../assets/...`、`../../../assets/...` 全部失败）。

#### 4. 表达式位置的 FQN 是 AIR 的运行时地雷（#1065）

`new flash.geom.Rectangle(...)`（没有 import）在 AIR 上抛
`#1065: Variable flash is not defined`，as-aot 却正常。**类型位置**的 FQN 没问题
（`var ldr:flash.display.Loader` 两端都对，本仓库 loaders 里那条带注释的写法保持原样）——
区别在于类型位置强制编译期解析到真实定义，表达式位置在 `strict=false` 下退化成名字链查找。

#### 5. `createScene()` 里抛异常过去是**完全静默**的

`texture-maps` 在 AIR 上就是死在 `createScene`：窗口起来了、日志一个字没有、没有报错。
现在 `onContext3DCreate()` 与帧循环同样兜在 `reportFrameError()` 里，一次就抓到了上面那条
`#1065` 的完整堆栈。**「没有日志」和「没有错误」过去长得一模一样**，这条护栏必须留着。

#### 6. 未解决：adl 的 `#1502` 脚本超时（根因未定，已登记）

AIR 侧的帧循环会在**几秒内**被 `#1502: A script has executed for longer than the default
timeout period of 15 seconds` 掐掉（抛点固定在 `onEnterFrame -> render -> updateMatrixWorld`），
画面随之定格。AOT 侧同一份代码 120 fps、无异常。以下是实测矩阵，**结论是「不是我们改的这些」**：

| 变量 | 观测 |
|---|---|
| `-debug=true` / 显式 `-debug=false` | 无差别（`air-config.xml` 自带 `<debug>true</debug>`） |
| 描述符 `<scriptTimeLimit>0` / `3` | **adl 忽略**：写 3 仍报「15 seconds」 |
| 窗口在屏内 / 屏外 / 前台 / 后台 | 无差别（所以**不是** App Nap，§26.7 旧结论已修正） |
| 极简探针（只有 `ENTER_FRAME` 计数） | **30 s 无异常**（`tick 600`） |
| 极简探针 + 启动时 20 次 `System.output` | **12 s 无异常**，20 次输出耗时 **0 ms** |
| 各 demo | 何时触发不一致：`rotating-cube`/`shadow-m7`/`stats-m15` 在 5 s 窗口内干净，
  `uv-m18`/`texture-maps` 等**几秒内**就抛；同一条文案始终是「15 seconds」 |

两个候选解释都还**没有**被证死，所以不写「已定位」：

1. **累计脚本时间**：看门狗计的可能是累计脚本执行时间，重负载 demo（UV 六槽、六贴图）每帧
   脚本开销大，累计更快到阈值——能解释「重 demo 先死」，但**与「几秒内就抛」和
   「8 条 `System.output` 的 demo 先死、写 20 行的探针不死」都对不齐**。
2. **`getTimer()` 时钟异常**：M21 实测过 `getTimer()` 在两采样点之间**倒退**
   （`p2-p1 = -27612`）。看门狗用的是同一个时钟，时钟跳变足以让它在墙钟远未到 15 s 时就判定超时。

⇒ **登记为遗留，不作为「AIR 已验收」的一部分**：在它关掉之前，AIR 侧证据只覆盖
「起窗 + 首帧/首秒正确」（这正是本轮 19/19 拿到的）。下一步的确定做法是：
① 在 demo 里每帧记 `getTimer()` 并与墙钟比对，先判定是不是时钟问题；
② 若确为累计脚本时间，再降每帧 AVM2 开销（常量打包/矩阵更新减少分派与 `Vector` 往返）；
③ 最终判据改成「AIR 连续运行 ≥60 s 无 `#1502`」。
**不要**用「把 `stage.frameRate` 降到 30」来掩盖。

**M26 追记（2026-11-01）**：拿到更窄的抛点，且实测它**间歇**，不是「必然几秒死」——

- 新栈：`SkinnedMesh._skinIntoAttributes()` ← `updateDeform()` ← `_renderShadowObject()`
  （阴影 prepass 的**第一笔** draw）。此前记的 `Matrix4.copy/updateMatrixWorld` 只是同一帧里
  更早的位置。**CPU 蒙皮这一帧的重量**是最可疑的一项（AVM2 上逐顶点乘加 + 写回属性）。
- 间歇性证据：同一条 `gltf-m8` 命令两次跑满 **40 s** 无事，另一次 3 s 内就抛；`env-m9`（无蒙皮）
  20 s 无异常；`walk-m26` 被动跑 25 s 会抛，而把 AIR 时间线压到 ~6 s 时**同一次运行**能完整
  走完「按键 → Walk → Run(warp) → Walk → Idle」并在 `calls=4 / tris=16472` 上稳定。
- 因此第 1 候选（累计脚本时间）仍成立但不完整：「间歇」暗示还叠着一个**偶发长帧**
  （GC 或第一次走蒙皮开销路径）。下一步先按 (1) 量 `getTimer()` 与墙钟差，再在 `updateDeform`
  里加一个「本帧蒙皮耗时」计数器，判定偶发长帧是否出在蒙皮自身。


---

## 27. UI 层接入 + 布局约定：HUD 左上 / 右侧控制面板（D139–D142、R56–R58，2026-11-01 M24 拍板）

M15 把 Stats HUD 放在了**右上角**（照 stats.js 的默认），M21 之后每个 demo 都是「HUD 占右上」。
问题是 three.js 例程里右上是**两个**东西的共同位置：`stats.dom` 和 `lil-gui` 的控制面板。
我们只有 HUD，所以一直没有暴露这个冲突——直到真的要做控制面板：**面板要么盖住 HUD，
要么和 HUD 抢同一个角**。

M24 把座位重新分一次，并把「UI 库怎么进来」定死：

| 区域 | 归属 | 约束 |
|---|---|---|
| **左上** | Stats HUD（FPS/MS/MB/CALLS/TRIS） | 默认锚点，`margin = 8`；`x = margin` |
| **右上 → 右侧整条** | 控制面板（`asaotui`） | 固定宽度 `300px`，贴右缘，全高；`x = stageWidth - 300` |
| **中间** | 3D 视图 | 上述两者都不许盖 |

### 27.1 D139：HUD 默认锚点从右上改左上

`Stats` 的构造签名从 `autoPlace:Boolean` 改成 `alignAt`：

```as3
public function Stats(withMemory:Boolean = true, alignAt:String = "left")
public static const LEFT:String = "left";
public static const RIGHT:String = "right";
```

三点实现细节，都是踩过的坑：

1. **默认值必须写成字符串字面量 `"left"`**，不能写 `Stats.LEFT`——as-aot 目前不在**参数默认值**
   里解析类常量（`mxmlc` 也一样，AS3 的默认值要求编译期常量，而跨类静态常量在我们的前端
   还没在参数位求值）。写常量会在编译期报「未定义」。
2. **非法值抛错，不回退**：`alignAt` 既不是 `"left"` 也不是 `"right"` 时抛
   `ArgumentError`。静默回退到左上会让「面板为什么压住了 HUD」变成一个查不出来的谜
   （§26.8 的同一条纪律：宁可炸，不要沉默）。
3. 锚点算在纯函数里（`anchorFor(align, stageWidth, margin)`），随 `Event.RESIZE` 重算——
   与 M16 的 resize 钩子同一条路径，不在 `Stats` 里缓存 `stage.stageWidth`。

探针 `probes/stats-smoke-m15/` 的 F 节随之从 5 项扩到 **10 项**：默认角是 LEFT（`x == margin`）、
右对齐数学（`x == stageWidth - 80 - margin`）、`anchorFor(RIGHT) == anchorX`、无 stage 时两角都回退左缘、
**未知 align 抛错**（旧断言「回退到左缘」删掉——那正是会被静默吞掉的那种行为）。全套 **81 项 ALL PASS**。

### 27.2 D140：`asaotui` **就地链接**，不复制

控制面板不是 asaot3d 的一部分——它是 `asaotui`（**另一个仓库 checkout**）的 UI 工具包。
把它复制进 `asaot3d/` 是最省事也最坏的做法：副本即分叉，控件修一次要改两处，而且
`asaot3d` 里的那份会慢慢和真库不一致。

所以 M24 给 `tools/build-demo.sh` 加了一个**通用**入口，而不是给这一个 demo 打补丁：

```
apps/<demo>/class-paths     # 每行一个源根，相对仓库根，`#` 起注释；缺文件 = 没有额外源根
        ↓ tools/build-demo.sh
AOT  : as-aot --air-app <xml> --as-class-path ../asaotui/seam --as-class-path ../asaotui/kit
AIR  : mxmlc … -source-path+=../asaotui/seam -source-path+=../asaotui/kit
```

- **同一份清单喂两个后端**，所以「AOT 能编、AIR 缺类」这种漂移在结构上不会发生。
- 路径**相对 asaot3d 根**，`class-paths` 里写 `../asaotui/kit`——`asaot3d` 与 `asaotui`
  是并列 checkout，符合两边各自的工具（`asaotui/tools/*` 传的是同两个根）。
- **`--as-class-path` 只对 `--air-app` 生效**（实测：不带 `--air-app` 的普通编译会忽略它）。
  这不是限制，因为这些 demo 本来就是 `--air-app` 形态。

实测代价：AIR 产出的 SWF 从 95 KB（`scene-m20`）涨到 **196,498 B**（`panel-m24`）——
多出来的就是整个 UI 工具包，符合预期；AOT 侧 `-O2` 从 `main` 出发把没用到的控件剪掉。

### 27.3 D141：**帧循环是唯一写者**

面板 → 场景的数据流只有一条，且只有一个方向：

```
widget 事件 ──► PanelState（纯数据） ──► PanelView.render() 重新描述 ──► UiApp 对账
                     │
                     └────────► Stage3DApp.updateFrame() → applyState()
                                  （唯一写 Scene / Light / Material / AGALRenderer 的地方）
```

为什么不让 widget 的回调直接写材质：那就是 §26.10 那个雾 bug 的形状——**两处都能写同一个
值**，于是「面板显示 34」和「shader 拿到 15」可以同时成立，而且两份都自洽。现在
`applyState()` **每帧无条件跑一遍**（几个赋值而已），故意不做「值变了吗」的脏标记：
脏标记本身就是「上一次应用了什么」的第二个真相来源。

控件覆盖（8 个，全部双向可读回）：雾开关 / 雾 near / 雾 far / 太阳强度 / 太阳角度 /
阴影开关 / 色调映射（None·Linear·ACES）/ 曝光 / 线框 / 重置。

### 27.4 D142 / R56：AOT 与 AIR 的**窗口尺寸语义不同**（32px 标题栏）

同一条 `<width>1200</width><height>900</height>`：

| 后端 | 初始 stage | 说明 |
|---|---|---|
| AOT | **1200×900** | 描述符的长宽被当作**客户区**（= framebuffer 尺寸） |
| AIR | **1200×868** | 描述符的长宽被当作**窗口 frame**，含 32px 标题栏 |

后果不是「差一点像素」：stage 高度 900 vs 868 ⇒ 透视 `aspect` 1.333 vs 1.382 ⇒
**画面中段整体错位**。用 osascript 把两个窗口都设成 frame `1200×900` 也一样
（AOT 侧会收到 resize 变成 868，AIR 侧本来就是 868）——两边最终都是 868，但 AOT 经历了
一次 resize、AIR 没有。

**R56（测量规则）**：跨后端像素比对必须先把 **stage 尺寸**对齐到同一个数（从两边的
`Stage3DApp ready: WxH` 日志读，不要假设窗口 frame 相同），否则差的是投影而不是渲染。
M24 的比对因此只做「同 stage 下肉眼一致 + 面板/场景结构一致」，**不宣称像素级一致**；
逐像素比对留给窗口尺寸可精确对齐的场景（M21 的 `scene-m20`）。

### 27.5 验收（AOT 交互 + 双端起窗）

AOT（`apps/panel-m24/PanelM24`，Quartz 合成真实系统鼠标事件，全部可回放）：

| 动作 | 日志 | 截图 |
|---|---|---|
| 起窗 | `M24 frame 1: drawCalls=5 triangles=50 stats x=8 panelW=300` | `temp/m24-geom.png`（HUD 左上、面板右侧 300px、中间 3D） |
| 点「Wireframe」 | `M24 panel: … wireframe=true` | `temp/m24-wire.png`（三个立方体 + 地面 + 雾柱变线） |
| 点「Cast shadows」+「Enabled」 | `… shadows=false` → `… fog=false` | `temp/m24-noshadow-nofog.png`（影与雾同时消失，地面回到纯灰） |
| 拖 Far 滑杆 34 → 15 | `… fog=true(8..15.9)`，标签变 `Far 15` | `temp/m24-far.png`（雾带前移、远端整片棕色） |

帧率 120 fps / `calls=5` / `tris=50` 全程稳定——面板与场景在同一帧循环里，没有引入额外 draw。

AIR：`./apps/panel-m24/build.sh air` 编译 196,498 B，`adl` 起窗 `Stage3DApp ready: 1200x868`、
面板与场景同形（`temp/m24-air.png`）。`#1502` 仍在 ~240 帧后掐断帧循环（§26.11.6 遗留），
所以 AIR 侧证据仍只覆盖「起窗 + 首秒」。

### 27.6 踩到的坑（写在代码注释里，这里只列清单）

1. **`asaotui` 的样式简写**要直接写在选项上（`divider({ color: …, thickness: … })`），
   `divider({ style: {…} })` 会被当成未知键——那层是给真正的 `StyleRefinement` 留的。
2. **主题要在 `mount` 之前设**：`Theme.setTheme(ThemeTokens.dark())` 之后 `UiApp` 才会用
   深色调色板下沉标签颜色；放在 `mount` 之后第一帧会闪一下浅色。
3. **一个文件一个 public 类**（`mxmlc` 限制，§26.2）：所以 `PanelState`/`PanelView` 分两个文件。
4. **类常量不能当参数默认值**（§27.1 第 1 条）。
5. 面板贴右缘用 `justifyContent: "flex-end"`（根节点占满 stage），而不是给面板算绝对 x——
   这样 resize 时不需要重算，也天然不会盖住左上 HUD。

### 27.7 钉子

- `probes/stats-smoke-m15/` F 节 10 项（默认左上 / 右锚数学 / 无 stage 回退 / 未知值抛错）——**已改并全绿**，全套 **81/81**。
- 本轮的 UI 布局与数据流**不做探针**：它们是 demo 层形状，不是引擎语义；真正的钉子
  （`PanelState` 的取值域、`applyState` 的写入顺序）等 M25 把面板抽成可复用时再补。

---

## 28. three.js 示例对齐审计：walk / lightprobe / glTF（M25–M27 计划）

用户点名三个例程，判定「我们的观感不如它」。逐行把例程用到的 API 抄下来，对照 `kit/` 与
`seam/` 的现状，得到下面三张缺口表。**结论先说**：三者缺的东西并不重合，各指向一条不同的
能力——

- `webgl_animation_walk` → **HDR 环境光** + 骨骼可视化 + 键盘输入（动画本体 M12 已有）；
- `webgl_lightprobe` → **球谐光照（LightProbe）**，这是我们**完全缺失**的光照模型；
- `webgl_loader_gltf` → **HDR 环境光 + KHR 材质扩展**（观感差距的主要来源，见 §28.5）。

### 28.1 `webgl_animation_walk.html`（Soldier.glb 走/跑切换）

| 例程用法 | 现状 | 缺口 / 结论 |
|---|---|---|
| `GLTFLoader` 加载 skinned GLB | ✅ M12（CPU 蒙皮 + `Bone`/`Skeleton`） | — |
| `AnimationMixer` + 多个 `clipAction` + `crossFadeTo` | ✅ M12 + **M26**（`crossFadeTo`/`crossFadeFrom`/`syncWith`/`warp`/`halt`/`stopWarping`） | 已补齐（D147、R60/R61，§29.2） |
| `HDRLoader` → `scene.environment` | ❌ 只有六面 `CubeTexture` | **最大缺口**，见 §28.2 |
| `scene.environmentIntensity` | ❌ 字段不存在 | 与 HDR 一起补（乘进 `fc10` 的 env 强度） |
| `SkeletonHelper` + `setColors`（骨骼可视化） | ✅ **M26**（复用 M11 线段程序 + 新增顶点色变体） | 已落地（D149/D150/R62，§29.3）；glTF 关节靠 `isBone` 标记（D151） |
| `texture.anisotropy = getMaxAnisotropy()` | ❌ `Texture` 无 `anisotropy`，Stage3D `setSamplerStateAt` 也无此参数 | **平台硬边界**：Stage3D 无各向异性过滤 ⇒ 登记为「不可实现」，不假装支持 |
| `texture.repeat` + `RepeatWrapping` | ✅ M17/M18 | — |
| `PointLight`（decay/distance）+ 自发光球 | ✅ M6 | — |
| 阴影相机范围（`shadow.camera.left/right/top/bottom`） | ✅ M7 | — |
| `PCFShadowMap` 类型选择 | ✅ 固定九抽头 PCF（M13） | 无需 `shadowMap.type` 开关 |
| 键盘 `keydown`/`keyup`（走/跑切换） | ✅ **M26**（`Stage3DApp.keys` + `input/Keyboard.as`） | 已落地（D143–D146、R59，§29.1）：桥暴露「按下/边沿」，键位映射归 demo |
| `THREE.Timer` | ❌ | **不需要**：`Stage3DApp` 已给 `elapsedMs`，`Timer` 只是浏览器侧的 delta 包装 |
| `Group` / `followGroup` 跟随 | ✅ | — |
| `GUI` | ✅ `asaotui`（M24） | — |

### 28.2 `webgl_lightprobe.html`（球谐探针 + 光滑金属球）

| 例程用法 | 现状 | 缺口 |
|---|---|---|
| `LightProbe` + `LightProbeGenerator.fromCubeTexture` | ✅ M27（§35.4） | 9 个 SH 系数（L2）由 cube 图按立体角积分，但**求值不在片元里**（D176）：CPU 烘 16×16 irradiance cube（纹素 `E/π`）绑 `fs7` |
| `LightProbeHelper`（SH 可视化小球） | ❌ | 有了 SH 就能画（球面网格 + 顶点色）；未做，登记在 §35.8 |
| `CubeTextureLoader` + `scene.background = cubeTexture` | ✅ M9 + M20 | — |
| `MeshStandardMaterial.envMap`/`envMapIntensity`（metalness 0 / roughness 0） | ✅ M9（粗糙度用 `mix(R,N,r²)` 近似） | 粗糙度 0 时与 PMREM 结果一致；中间粗糙度是我们**已知的近似** |
| `NoToneMapping` | ✅ M10 | — |
| 按需渲染（`controls.change → render()`，无帧循环） | ✅ 渲染器可单帧 `render()`；`Stage3DApp` 是固定循环 | 无需改动（固定循环下多画几帧不影响正确性） |

**判断**：LightProbe 是唯一「three.js 有、我们完全没有」的光照路径。但它**只**贡献低频
环境光，而 M9 的 cube IBL 已经在做同一件事（而且更准）。优先级低于 HDR（§28.3），
排 M27。

### 28.3 `webgl_loader_gltf.html`（DamagedHelmet 等，用户认为「明显更好」）

这条是观感差距的主因，逐项拆开：

| 例程用法 | 现状 | 影响 |
|---|---|---|
| `UltraHDRLoader`（`.hdr.jpg`）→ `scene.background` + `scene.environment` | ❌ 只有六面 8 位 `CubeTexture` | **最大**：金属/粗糙度全由 env 决定，没有 HDR 就没有高光形状 |
| `scene.backgroundBlurriness` | ❌ | 中：背景抢焦点 |
| `ACESFilmicToneMapping` | ✅ M10 | — |
| `envMapIntensity` 逐材质 | ✅ M9 | — |
| `KHR_materials_emissive_strength` | ❌ | DamagedHelmet 的发光标牌差一点 |
| `KHR_materials_clearcoat` / `transmission` / `sheen` / `iridescence` / `volume` / `specular` | ❌ | 只有带这些扩展的模型才看得出 |
| Draco / meshopt / basisu 压缩 | ❌（已登记） | 只影响能否加载，不影响观感 |
| `Box3.setFromObject` + `fitCameraToSelection` | ✅ `Box3.setFromObject/getSize/getCenter` | 我们的 demo 可以照抄这段 |
| `renderer.compileAsync`（等编译完成再加进场景） | ❌ | **不需要**：AOT 在启动前就把 AGAL 编好，没有运行时卡顿 |
| 多模型切换 + `mixer.stopAllAction()` | ✅ | — |
| `antialias: true` | ⚠️ AOT 是 `ASC_S3D_MSAA` **opt-in**，AIR 侧 `configureBackBuffer(..., 0, ...)` 仍传 0 | **双端不一致且默认关**（登记，见 §26.9 末尾） |

### 28.4 里程碑排期

| 里程碑 | 内容 | 为什么排这个顺序 | 验收 |
|---|---|---|---|
| **M25 · HDR 环境光**（最高优先） | `.hdr`（RGBE 扫描线）与 UltraHDR `.jpg` 解码 → equirect 全景 → **CPU 侧转 cube**（六面 + 逐级降采样近似 prefilter）→ `scene.environment` / `scene.background` / `backgroundBlurriness` / `environmentIntensity` | 一张 HDR 同时改善三个例程的观感；且不需要新 AGAL 程序（复用 M9 的 fs7） | `DamagedHelmet` 与 `webgl_loader_gltf` 截图 A/B：金属高光形状、背景不再死平；`probes/hdr-smoke-m25/` 钉 RGBE 解码锚点、equirect→cube 六面朝向、prefilter 单调性 |
| **M26 · 骨骼可视化 + 键盘 + 交叉淡入** ✅ | `SkeletonHelper`（+`setColors`）、`Stage` 键盘事件桥、`AnimationAction.crossFadeTo/From/syncWith` | 三者都是 `webgl_animation_walk` 的硬依赖，且全是 CPU 侧，风险低 | ✅ `apps/walk-m26/`：Soldier.glb 走/跑由真实按键切换并交叉淡入（含 warp）、骨骼线可见；`probes/anim-smoke-m26/` **59 项 ALL PASS**；§29 |
| **M27 · LightProbe（SH9）** ✅ | `LightProbe` + `fromCubeTexture`（SH 积分）+ **CPU 烘 irradiance cube 复用 `fs7`**（片元不求 SH，D176）+ `LightProbeHelper` 未做 | 低频光照 M9 已覆盖，优先级最后；实现时确认「片元 SH 求值」不可行（约 40 条 AGAL + 八槽采样器满员） | ✅ `probes/lightprobe-smoke-m27/` **36 项 ALL PASS**（常数环境 `E = πL`、方向性环境对暴力余弦积分 +Y 0.7%、`E/π` 往返、四种拒绝）；探针与环境互斥 + 一次性警告；§35.4 |

> 三条都遵守 §1.5：**AIR 是底线**。HDR 变体要过 AIR 的 AGAL 校验（第 5/6 采样槽、常量上限）；
> SH 求值要盯指令预算 —— M27 落地时正是这一条把「片元求 SH」否掉了（§35.4：八槽采样器 + 40 条指令）。

### 28.5 为什么「glTF 看起来差」不等于「glTF 加载器不行」

`DamagedHelmet` 的观感几乎**全部**由环境照明决定：它的材质是 `metalness=1`，在 PBR 里
金属**没有漫反射**，颜色全部来自反射。M9 的六面 8 位 LDR cube 图 + `mix(R,N,r²)` 近似，
在「一个亮斑 + 一片暗」的 LDR 环境里看起来就是「灰蒙蒙的一坨」——这不是加载器的保真度问题，
也不是 emissive/AO 的问题（M8 已修），而是**缺少真正的 HDR 环境**。所以 M25 排在第一位，
并且**不要**为了「更像」去调 emissive 或曝光把画面糊亮——那是把缺光照改成假光照。

### 28.6 本轮不动的项

- `Texture.anisotropy`（Stage3D 无对应 setter）——登记为平台边界，不实现。
- `renderer.compileAsync`——AOT 无运行时编译，天然不需要。
- `THREE.Timer`——宿主已给 `elapsedMs`，加一个类只会制造第二个时钟。
- 透明 glTF 模型的排序与 `transmission`——依赖 RenderTarget 链，等 M28+ 的 `RenderTarget`。

---

## 29. 骨骼可视化 + 键盘桥 + 交叉淡入（D143–D151、R59–R62，2026-11-01 M26 拍板）

§28.1 的三条 ❌（`SkeletonHelper` / 键盘输入 / `crossFadeTo`）在本轮补齐，验收 demo 是把
`webgl_animation_walk.html` 整个搬过来：`apps/walk-m26/`（Soldier.glb + 棋盘地面 + 跟随灯光组）。
三条改动全在 CPU 侧，**标准片元的指令数一分没变**（163/400、阴影 300/400），新的程序变体
只有线段程序的 `(vertexColors, toneMapped)` 四选一。

### 29.1 键盘桥（`kit/asaot/three/input/Keyboard.as` + `Stage3DApp.keys`）

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D143 | `document.addEventListener('keydown'/'keyup')`，比较 `event.code`（`'KeyW'`/`'ShiftLeft'`，物理键位） | 桥在 `Stage3DApp`：`stage.addEventListener(KeyboardEvent.KEY_DOWN/KEY_UP)`，比较 **`flash.ui.Keyboard` 键码**（`Keyboard.W`=87、`Keyboard.SHIFT`=16）。键位映射（WASD/方向键同义、Shift=跑）留在 demo 里 | AIR 没有 DOM；`KeyboardEvent` 才是 AIR 的权威形状。用 `event.code` 还是 keyCode 是**平台差异不是语义差异**，所以桥只提供「哪个键按下去了」，映射策略归应用 |
| D144 | `window.addEventListener('blur')` 清空按键表（否则切走再回来，键会「粘住」） | 听 `Event.DEACTIVATE`（窗口失去焦点）→ `reset()` 清空按下表 | AIR 里窗口失焦的权威事件是 `Event.DEACTIVATE`；这是**必须**的，否则 alt-tab 回来角色会一直走 |
| D145 | 边沿（`pressed this frame`）由 DOM 事件天然产生 | `Keyboard` 维护 `_down` 表 + `_pressed` 表；`justPressed()` 读 `_pressed`，`endFrame()` 清掉 `_pressed`。`endFrame()` 由**宿主**在 `afterFrame()` 之后调用 | 事件与帧不同频：一帧内可能收到 2 次 KEY_DOWN。用「帧末清边沿」把事件流折成帧语义，和 `Input` 的常规做法一致；宿主负责调用点（`Stage3DApp.onEnterFrame` 末尾），demo 不需要知道 |
| D146 | 未知 `event.code` 只是不匹配任何分支 | 键码超出 `[0,255]` 时计入 `droppedKeys`（可读诊断），仍不触发按键 | 静默丢弃会让「键位写错」变成「功能不响应」，无法定位 |

规则：

- **R59** 键盘状态是**逐帧快照**：`isDown()` 在整个 `updateFrame` 内稳定，`justPressed()`
  只在 `endFrame()` 之前为真。写 `if (keys.justPressed(X)) toggle()` 的开关必须放在
  `updateFrame`/`afterFrame` 里，不能放进异步回调（那时边沿早已被清）。

### 29.2 交叉淡入 / 相位同步 / warp（`AnimationAction`）

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D147 | `crossFadeTo/From`、`syncWith`、`warp`、`halt`、`stopWarping` | 全部落地，权重曲线与 three.js 一致（`fadeOut` + `fadeIn` 两条插值器，`warp` 另借一条 `_timeScaleInterpolant`）。`warp` 的存的是**相对倍率**（`start/timeScale`），结束时把累计速率折回 `timeScale` | 倍率而非绝对值的写法是 three.js 的原样（`AnimationAction.js` `_updateTimeScale`）：末值写回 `timeScale` 后，**跑/走两组剪辑的周期比会永久保留**（实测 `runTS=0.677 = walkLen/runLen`），这正是「切换后步频仍对得上」的原因，不是 bug |
| D148 | `Quaternion.angleTo/rotateTowards`、`Vector3.applyAxisAngle` | 补上三个方法（demo 需要「朝移动方向转身」）。`applyAxisAngle` 用 Rodrigues 公式内联实现，不借 three.js 的模块级临时四元数 | AS3 没有模块作用域全局变量；Rodrigues 对单位轴精确，且零分配（热路径禁止逐帧 new） |
| — | `syncWith(action)` 取同一个 `time`（秒） | 同样落地（照抄 three.js 语义：`time`/`timeScale` 直接复制）。**但 demo 不走它**：走/跑是**不同长度**的剪辑，同秒对齐反而错相，改为按比例对齐 `incoming.time = outgoing.time × (inDur/outDur)` | 记录的是「API 与 three.js 同语义」与「demo 需要的是比例对齐」两件事；避免后来者以为 `syncWith` 能跨长度对齐 |

规则：

- **R60** `crossFadeFrom` 的 `fadeIn` 是**乘在 `action.weight` 上**的（0→1 的倍率）。所以交叉
  淡入前必须 `incoming.weight = 1`，否则淡入峰值只到旧权重（探针里踩过：权重停在 0.3）。
- **R61** 淡入窗口是按 **mixer 时钟**排的（`warp` 同样用 `mixer.time`）。测试想「从 0 开始」必须
  先 `mixer.setTime(0)` 再排淡入，否则窗口起点是上一轮遗留的时钟值。

### 29.3 骨骼可视化（`kit/asaot/three/helpers/SkeletonHelper.as`）

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| D149 | 顶点色线段（`va3` 颜色属性 × `diffuseColor *= vColor`） | 线段程序新增 `(vertexColors, toneMapped)` 变体：顶点程序可选读 `va3` 进 `v1`，片元可选乘 `v1`；**不用顶点色的 draw 仍走原来的程序**（字节级不变） | Stage3D 没有线图元（M11 起每段边是屏幕空间四边形）。顶点色要真的多一条流 + 一个 varying；做成变体而不是「一律读 va3」，才不会让 M11/M19 的线框路径多绑一条没用的流（AIR 会 #3607） |
| D150 | 包围球只算一次 | 每次 `updateMatrixWorld` 重算 `computeBoundingSphere()` | three.js 里 helper 的骨骼在动而球不动 ⇒ 会被错误剔除。骨骼数是几十，重算比「剔除错」便宜 |
| D151 | 关节节点在**建节点时**就 new `Bone` | `GLTFLoader._loadSkin` 给关节节点置 `Object3D.isBone = true`（`Bone` 除了这个标记没有别的东西） | glTF 没有「这是骨骼」的标记，节点是不是关节**只**由 `skins[].joints` 决定；我们的解析到 skin 阶段节点图已经建好，而 AS3 **不能事后换类**。置标记是唯一既能对齐 three.js 行为、又不重写节点图的做法 |

规则：

- **R62** 顶点色线段要求「几何有 `color` 属性 + 材质 `vertexColors=true` + 渲染器绑 `va3`」三者
  同时成立；缺一就退回无色线段（不是黑线），别指望 shader 自己发现。
- `SkeletonHelper` 必须在**模型之后**加进场景：它读的是本帧已更新的骨骼 `matrixWorld`，而
  `Object3D` 的世界矩阵按加入顺序更新。

### 29.4 验收与遗留

demo `apps/walk-m26/`（Soldier.glb）：Quartz **真实系统按键**驱动，AOT 侧完整链路通过——
`action: Walk`→`action: Run warp=true time=0.333`→`action: Walk warp=true`→`action: Idle`，
淡入淡出权重按帧采样（0.404/0.796/0.16…）、`walkTS=1.476`/`runTS=0.677` 的 warp 倍率可读、
`pos` 单调推进、`skeleton: true` 后 `calls` 3→4、`tris` 16376→16472（48 段骨骼线）；
AIR 侧同一脚本同样拿到 `skeleton: true` 与三次 `action:` 切换、`calls/tris` 与 AOT 逐个相同。
冒烟 `probes/anim-smoke-m26/` **59 项 ALL PASS**。

遗留（不在 M26 范围，已登记）：

1. **AIR 长跑 `#1502`**：本轮拿到更窄的栈——`SkinnedMesh._skinIntoAttributes()` ← `updateDeform()`
   ← `_renderShadowObject()`（阴影 prepass 第一笔 draw）。它**间歇**触发（同一 demo 有跑满 40 s
   无事的记录），且 `env-m9`（无蒙皮）20 s 无异常 ⇒ 与 CPU 蒙皮这一帧的重量相关，不是「所有 demo
   都会死」。AIR 交互证据因此要靠压缩时间线抓（`temp/walk-shot.py` 的 `WALK_SETTLE`/`WALK_T`）。
2. ~~**AOT/AIR 环境贴图观感差异**~~ **已定性并修复**（§29.5）：根因是编译器 AGAL→目标语言的
   写掩码「读后写」别名，与 cube 面朝向、sRGB 编解码都无关。`cubeface-m25` 六面读回与
   `examples/stage346.as` 已把修法钉死。环境贴图之后还剩**一条**与本项无关的分歧（本体材质明度，
   见 §29.6）。
3. `Texture.anisotropy` 仍是平台边界（Stage3D 无 setter），不实现。

### 29.5 阶段三百四十六：AGAL 写掩码「读后写」别名（2026-11-01 收尾）

§29.4 遗留 2 的根因**不是** cube 面朝向，也不是 sRGB 编解码在两端不一致，而是编译器把 AGAL 展开成
**逐分量赋值**时产生的读后写别名：

- 触发形态：`mul ft8.xyz, ft0.xyz, ft8.xxxx`。AGAL 规定「源操作数先全部读出，再写目的地」，但三个
  目标后端（MSL / GLSL / HLSL）共用同一个 `agal_emit_body`，它把 `.xyz` 掩码拆成三条单分量赋值，
  于是从第二条起读到的是**已经被改写过的** `ft8.x`。
- 可观测后果：`cubeface-m25` 的六面体里，凡是红通道为 0 的面（绿/蓝）整面变黑——因为 env 采样结果
  被整体乘以了「自己刚写进去的 0」。同一份 `env-m9`/`walk-m26` 因此表现为 AOT 环境发黑、高光发白；
  `adl` 直接执行 AGAL，永远不踩这条路径，这正是「同源却不同观感」的来源。
- 修法（`as3compiler/src/runtime.ts` 的 `agal_emit_body`）：新增 `agal_mask_clobber(swz, dmask)`
  判定危险别名（读分量序号 `r` 小于写入分量 `c`，且 `r` 落在写掩码里），命中时 `agal_snap_src()`
  先发一条整寄存器快照 `float4 as_agal_s0 = <reg>;`，再由 `agal_src_expr_named()` 把每个使用点改读
  快照；同一处理套到矩阵路径（`m33/m34/m44` 逐行发射）。快照序号按 body 复位（`snap_seq = 0`），
  保证生成的着色器文本可被单元钉子逐字断言。
- 验收：`as3compiler/examples/stage346.as`（8 条翻译文本断言 + Metal 像素读回，窗口未合成时读回
  自动 SKIP）、单元组 `stage3d/agal-write-mask-alias`（7 条）、`apps/cubeface-m25/` 六面逐面读回
  （`(660,408)=(116,248,75)` / `(720,408)=(230,50,35)` / `(800,408)=(127,127,127)` /
  `(720,320)=(1,0,241)` / `(720,500)=(252,252,252)`），以及全量 `node test.ts` **4664 PASS**。

### 29.6 遗留：`walk-m26` 的 AOT/AIR 明度差 —— 已从「材质」改判到「阴影项」

> **本轮结论修正**：早期记录写的是「AOT 比 AIR 暗」，实测是**反的**——AOT 更亮
> （本体框均值 `46.7,44.3,42.4` 对 AIR `30.5,26.4,23.2`）。下面的表按实测重写。

用**静态场景**做因子分解（`apps/texture-maps` 临时钉死姿态 `rotation=(0.35,-0.55)`，把两个旋转立方体
按住不动，避免走路/旋转相位噪声）：

| 因子 | 场景 | AOT | AIR | 判定 |
|---|---|---|---|---|
| `metalnessMap = map`（程序化贴图、无阴影、无 ACES） | 金属盘立方体 | 均值 `31.9,37.8,61.1` | `29.8,37.5,62.0` | **一致**（≤2/255）|
| 同一帧的对照面（灰色立方体） | 同上 | `183.7` | `182.0` | 一致 |
| 再打开 `ACESFilmic + exposure 0.5` | 同上 | `19.1,24.0,42.8` / 灰 `147.8` | `17.1,23.8,43.3` / 灰 `146.5` | **一致** |

⇒ **`metalnessMap` 采样与 ACES 色调映射两条都不背这个锅**，两条路径两端在 1% 内。分歧只在
`walk-m26` 这种**开了阴影**的场景出现，于是嫌疑收敛到阴影项本身。

**决定性对照（本轮实测）**：把本体同时 `castShadow = false; receiveShadow = false`（即场景里再无
任何投影体），两端同一份源码：

| 量 | AOT | AIR |
|---|---|---|
| 地面（阴影相机视锥内、本该完全受光） | `11.8,11.6,11.6` | `31.8,31.7,32.2` |
| 本体 | `63.9,58.8,54.3`（p90 `250` 过曝） | `48.0,39.9,33.1`（p90 `82`） |

AIR 的表现是对的（无投影体 ⇒ 无阴影，地面是干净棋盘格）；**AOT 把整个阴影视锥内的地面压成全黑**。
⇒ 登记一条真缺陷：**当某盏灯的投影体集合为空时，AOT 侧阴影贴图仍被当作「处处被遮挡」**。

**已修（编译器阶段三百四十七，2026-11-01）**：根因不在 `AGALRenderer`，而在 Metal 后端把 `clear()`
做成了**延迟**操作 —— 它只记下颜色/深度/模板值与「待清」标志，真正的清屏动作挂在**下一次
`drawTriangles`** 的渲染通道 `loadAction` 上。零 draw 的 pass 因此从未落地，阴影贴图停在新分配私有
不透明纹理的未定义内容（驱动给全 0），8bit 打包深度解出 `0.0` = 「比任何片元都近」⇒ 整片视锥判遮挡。
`adl` 的 `clear()` 与 draw 无关，空 pass 照样落到贴图上（深度 `1.0` = 最远）⇒ 它不产生阴影。
`s3d_apply_pending_clear()` 现在在 `set_render_target` 与帧末 `flush` 两处补一条零 draw 的清屏通道，
修后同源同帧地面 AOT `34.6` 对 `adl` `32.1`。细节见编译器 `docs/zh-cn/display3d.md` §3 ⑤ 与
`examples/stage347.as` + `unit: stage3d/pending-clear-no-draw`。

下一步（顺序不可颠倒）：

1. ~~先修空投影体这一条~~ —— 已修，见上。
2. 修完再重测本体：此时若仍差，才是真的自阴影精度问题（`normalBias`/16 位台阶在蒙皮网格上的表现），
   届时用「本体也排除在 caster 之外」的同姿势 A/B 定位，而不是再插桩到 shader 里。
3. 插桩**必须先确认寄存器空闲**：本轮曾用 `ft15/ft16` 存中间值，而这两个寄存器在同一变体后半段
   仍被使用，于是「插桩本身污染了结论」——出现过同一变量两次读数互相矛盾。正确姿势是从
   `dumpFragSource` 打出的 AGAL 里挑**该变体**真正空闲的寄存器，或直接扩 dump 让翻译器把中间值
   一并打出来。

**复现方式**（30 秒，不需要改 renderer）：把 `WalkM26.applyReferenceMaterials` 里本体分支的
`castShadow/receiveShadow` 都改成 `false`，两端各跑一次截图——AOT 地面全黑、AIR 仍是棋盘格。

（这一段是**已登记的分歧**，不是静默降级：默认画面与参考一致，缺口只在双端逐像素比对时可见。）

### 29.7 AGAL 的 `exp` / `log` 是以 2 为底 —— 两个后端同错的折算（2026-11-01）

修完阴影项之后 `walk-m26` 的地面/背景框已经对上了，本体框仍差（AOT 更亮、高光核外扩）。排查里先用
一个**只做算术**的最小台子把底数这条排除掉，结果是**排除不掉，反而抓到一个真 bug**。

**实测**（`as3compiler/temp/agalprobe/Exp.as`，同一份源码分别编译到 `adl 51.4.1` 与 AOT）：

| 表达式 | `adl` | AOT | 自然指数的答案 |
|---|---|---|---|
| `exp(-1)` | `0x7F` = 0.498 = `2^-1` | 同值 | 0.368 |
| `log(2)` | `0xFF` = 1.0 = `log2(2)` | 同值 | 0.693 |

⇒ **AGAL 的 `exp`/`log` 就是 `exp2`/`log2`**，翻译器（`op 0x0d → exp2()`、`0x0c → log2()`）本来就对，
错的是**消费方**。

**`AGALRenderer` 里两处按「AGAL 只有 e^x」写的折算都错了**：

1. **EnvBRDFApprox**：`fc13.x` 写的是 `-9.28 * ln2 = -6.4324`，于是
   `a004 = min(r.x², 2^(-6.43·NoV)) · r.x + r.y` 整体偏大；`r.x = 1 - roughness` 一乘，**粗糙度越低
   偏得越多**。修正：直接用 `-9.28`。
2. **FogExp2**：three.js 是 `1 - e^{-(density·d)²}`，我们发的是 `1 - 2^{-(density·d)²}`，雾偏稀。
   修正：`log2(e)` 放进 `fc37.w`（线性雾用它存 `1/(far-near)`，exp2 模式本来空着），片元只多一条 `mul`。
   `packFogConstants` 与 `probes/scene-smoke-m20` 的 C25 同步改写（`fc37.w` 对 exp2 从「期望 0」改为
   「期望 `log2(e)`」）。

**为什么它活了这么久**：两处都是**两端同错**。AOT 与 `adl` 执行同一份 AGAL，差分对比永远看不见，
只有对着 three.js 参考值才显形 —— 与 29.6 里那条「AOT 更亮」是两件不同的事（修完这两处，两端仍然同样亮）。

**顺带修掉的一处诊断缺陷**：`AGALRenderer.dumpFragSource` 在 `adl` 上会抛 `Error #1065: Variable
AGALTranslator is not defined`（`flash.display3D.AGALTranslator` 不在 `airglobal.swc` 里），即一个诊断
开关能把 AIR 端**每一帧**打死。现在先用 try/catch 包住 MSL 转译并**先打 AGAL 文本**（那份两端都拿得到），
转译不可用时只多一行 `MSL-FRAGMENT-UNAVAILABLE`。

**仍未收口（已在编译器 `TODO.md` 遗留表登记）**：本体的光照点积在两端系统性不同。把
`dotNH/dotNL/dotNV` 直接打进 `oc`（紧框统计，冻结姿态，`castShadow=false`、无雾、无色调映射）：

| 量 | AOT | `adl` |
|---|---|---|
| `dotNH` | 0.669 | 0.593 |
| `dotNL` | 0.466 | 0.418 |
| `dotNV` | 0.714 | 0.677 |

三个点积**同向**偏大 0.05–0.08，指向「扰动后的着色法线」或「相机位/光向常量」而不是某一项算术。
GGX 的分母 `1 + dotNH²(a2-1)` 对 `dotNH → 1` **极敏感**（0.99 → 0.94 就足以让 D 变 16 倍），于是这几个
LSB 被放大成「AOT 高光核是一片饱和白、`adl` 是一条细亮带」：`V*D` 视图均值 AOT 77.2 对 `adl` 38.0，
**中位数几乎相同（36 / 35）—— 差在尾部**。

已排除：`metalness`/`roughness` 贴样（两端的贴样图几乎逐像素相同）、`metalnessMap`、ACES、阴影项
（关掉灯的 `castShadow` 后数值一字不变）、`exp`/`log` 底数（本节已证两端一致）。
下一步要先排掉**取样口径**的污染：AOT 的窗口内容区是 1000×800、`adl` 的后台缓冲是 1000×768，
同一「分数框」在两边的 NDC 对应关系并不严格一致，本轮所有统计都受它影响 —— 应改用**固定离屏尺寸**
（`drawToBitmapData` 到一个固定大小的 `BitmapData`）的静态非蒙皮台子重测，再逐个把 `ft1`/`ft2`/`fc1`
打进 `oc` 对比两端。

（本节的两处折算修正在两端**同时**生效，因此不会改变 AOT/AIR 的差异幅度；判据是 three.js 参考值。）

### 29.8 阶段三百五十一：`walk-m26` 明度差结案 —— 是**取样口径**，不是渲染分歧（2026-11-01）

§29.7 末尾留了一句「下一步要先排掉取样口径的污染」。照它做了，结论比预期干净：**AOT 与 AIR 在
同一 stage 尺寸下逐项相同**，此前所有「AOT 更亮 / 点积系统性偏大」的读数都是 1000×800 对
1000×768 的投影差（D142/R56 早就登记过这条，只是当时没把它当成统计口径问题）。

**做法**：把参考实现本身跑起来当基准，而不是拿我们两个后端互比 —— AOT 与 AIR 跑的是**同一个**
`kit`/`seam`，它们互相一致并不能证明谁对。新增 `tools/refscene/`（真源 + 同一统计口径）：

- `tools/refscene/walk-m26.html`：three.js `webgl_animation_walk` 在 **1000×800** 下跑，**钉死姿态**
  （不做逐帧 `mixer.update`），暴露 `window.__stats(box)`；`?fog=0`、`?nonormal=1`、`?t=<s>` 是 A/B 旋钮。
- `tools/refscene/boxstats.mjs`：截图 PNG 上**同一个分数框**的同一组统计（`top` 参数吃掉 AOT 的 32px
  标题栏，AIR 传 0）。
- AIR 侧把描述符高度临时改成 832，让 `adl` 的 stage 也是 1000×800（描述符另存回 800，见 27.4）。

**实测**（本体框 `0.44,0.44,0.56,0.62`、地面框 `0.30,0.80,0.70,0.95`，亮度为 Rec.709 luma）：

| 帧 | 本体 mean | 本体 p50 | 本体 p90 | 地面 mean |
|---|---|---|---|---|
| three.js，雾开 | 20.75 | 8 | 46.0 | 23.65 |
| three.js，雾关 | 11.45 | 0 | 29.1 | 21.10 |
| AOT，雾开 | 44.19 | 21.6 | 72.8 | 28.44 |
| AOT，雾关 | 38.69 | 17.7 | 88.7 | 27.22 |
| AIR（832 描述符），雾关 | 37.80 | 17.0 | 73.7 | 27.28 |

四条判定：

1. **AOT ≡ AIR**：雾关时本体 38.69 对 37.80、地面 27.22 对 27.28。§29.7 那张「`dotNH` 0.669 对
   0.593、三个点积同向偏大」的表**撤回**：NDC 差 4% 就足以让同一分数框落在不同的球面位置，而
   `dotNH → 1` 附近的 GGX 尾部对位置极敏感（当时已注意到「中位数几乎相同、差在尾部」，正是取样
   不同的特征，只是被当成了插桩噪声）。
2. **背景三帧逐像素相同**（`94,93,93`）⇒ 相机、清屏色、输出编码、ACES 曝光全部无关。
3. **真正欠的是对 three.js 的对齐，而且两端同样欠**：金属本体（无环境贴图、无漫反射瓣）雾关时是
   参考的 **3.4 倍**（38.69 对 11.45，p50 17.7 对 0），地面（电介质、`roughness=0.85`）**+29%**。
   分布形状是整体抬升 + 尾部更宽，不是单纯的高光过曝 ⇒ 嫌疑落在**直接光的镜面项**（`BRDF_GGX`
   的 `F·V·D` 归一，含 `V_GGX_SmithCorrelated` 的 1/(4·NL·NV)）与 `metalness=1` 时漫反射是否真的
   被清零（`fc6.w = 1-metalness`）。注意 §29.7 已把 `exp`/`log` 与 EnvBRDF 系数、§29.6 已把
   `metalnessMap`/ACES/阴影项逐条排除，**这一条是本轮新开的口子，不是上面几条的复现**。
4. **我们的雾抬升得不够**：开雾相对关雾，本体参考 +9.30（20.75−11.45），我们只 +5.50
   （44.19−38.69）。这是独立于第 3 条的第二处缺口（雾的线性空间与深度口径）。

**登记**（M26-R1 / M26-R2，`three-api-design.md` 遗留表）：

- **M26-R1**：直接光镜面项比 three.js 亮 —— 判据是上表第 3 条，复现是 `tools/refscene/` 一页对
  `apps/walk-m26/` 一次截图（30 秒，两边都是 `?fog=0` / `DEBUG_NO_FOG`）。下一步不是再比双端截图，
  而是把 `AGALRenderer` 的标准片元与 `lights_physical_fragment`/`RE_Direct_Physical` **逐项对读**。
- **M26-R2**：雾的抬升幅度偏小（+5.50 对 +9.30），先量 `vFogDepth` 的口径（view-space z 还是世界
  距离）与混合是否发生在色调映射之前。

**方法论钉子（写进规则）**：跨端像素比对**必须先对齐 stage 尺寸**；判「谁对」必须用参考实现，
不能用我们的第二个后端。`tools/refscene/` 是这条规则的可执行形式。

> **2026-11-01 补正**：本节表格与 M26-R1/R2 登记已被 §32 取代。截图口径换成进程内
> `drawToBitmapData()` 回读后，参考页自身还查出两个 bug（模块少一个收尾 `} );`、漏设
> `metalnessMap`），上表「three.js 20.75 / 11.45」两行**作废**。§32 的结论是：M26-R2（雾抬升）
> **撤回**（线性空间反解出的混合系数两端差 3%），M26-R1 **重新界定**为「贴图 sRGB 解码用
> `pow(x,2.2)` 近似」（R1a）+「金属高光瓣偏尖」（R1b）。

## 30. M25：HDR 环境贴图（`.hdr` → CPU 烘焙 cube → IBL + 背景，D152–D157、R63–R65）

M9 的 IBL 只吃**已编码的 8 位 cube**（`CubeTextureLoader` 六张 JPEG），而 three.js 的
`RGBELoader`/PMREM 路线是「float panorama → 预滤波 cube」。本后端的硬边界是
**环境 cube 没有 float 存储**（任何档位：`rgbaHalfFloat` cube 接受上传但存 8 位字节，实测
§36.2），且默认档也没有 float render target（`standard` 档才有，§36.1），于是 M25 把整条链路
搬到 CPU：解码 → 重投影 → 8 位编码 → 上传，运行时只做「解码 + 乘系数 + 色调映射」。

### 30.1 D152：不用 PMREM，用 CPU 等距柱状→立方体烘焙

- 输入是 Radiance `.hdr`（RGBE），输出六张正方 `BitmapData`，逐面逐像素按方向取全景。
- 为什么不上 GPU：目标 cube 没有 float 存储（§36.2），`setRenderToTexture` 到 cube 也拿不到
  16F；而预滤波的语义又需要按粗糙度选 LOD，AGAL 片段程序没有 LOD 操作数（§36.6）。两条
  都堵死，才落到 CPU。
- 代价与取舍：面尺寸由调用方定（demo 用 128），时间在 4–17 ms（512×256 全景、单线程）；粗糙度的
  多级预滤波**不做**（见 30.5），所以反射的锐度由材质粗糙度在片元里近似，而不是查 LOD。

### 30.2 `RGBELoader` 的语义（`kit/asaot/three/loaders/RGBELoader.as`）

照 three.js `RGBELoader`（r187）+ Radiance 规范逐条落地：

- **RGBE → 线性**：`scale = 2^(e−128)/255`、`rgb = m·scale`，与 three.js `RGBEByteToRGBFloat` 同式。
- **三种扫描线**：平铺、旧式 RLE（`(1,1,1,count)` 重复上一像素）、新式 RLE（`02 02 hi lo` 逐通道
  字面/重复段）。三种都按行解码，行宽由头部 `-Y h +X w` 定。
- **轴向**：`+Y`/`-Y` 决定行序（`+Y` 表示**文件最后一行是解码后的第 0 行**），`+X`/`-X` 决定横向镜像；
  这两条探针里都有专门的锚点（写反了 panorama 会上下颠倒或左右镜像，但仍是「一张图」，肉眼不刺眼）。
- **`EXPOSURE=`**：解码时乘上。
- **显式拒绝**：`32-bit_rle_xyze`（XYZ 不是 RGB，当 RGBE 解会静默变色）与非 Radiance 文件，一律
  **抛错不猜**（AGENTS.md §1.5「不静默降级」）。

### 30.3 D153/D154：8 位 cube 装的是**伽马编码的线性辐照度**

这是 M25 最容易做错的一处：cube 上屏后既不能当 sRGB 颜色，也不能当线性值用。

- 编码：`texel = srgbOetf(clamp(lin / scale, 0, 1)) · 255`，`scale` 由 `autoScale()` 取
  **99.5 分位亮度**向上取到 2 的幂且不小于 1（三条都进探针）。
  **（D177 后不是 `pow(·, 1/2.2)`）** —— M25 首版用 2.2 近似，而 D170 之后渲染器解码是真 sRGB，
  两者各自自洽却互不匹配，HDR 环境因此在中间调系统性偏色；现在编码/解码是同一对曲线，见 §35.5。
- 解码：`CubeTexture.colorSpace = SRGBColorSpace` 触发 sRGB EOTF（`DECODE_ENV` 变体，`fc41/fc42`），
  还原出 `lin / scale`；`fc36`（当年那条 2.2 存储指数）已退役。
- **还原倍数存在 `CubeTexture.hdrScale`**（D154）：`scale` 本身不是纹理属性，但又必须乘回去，于是
  它作为 cube 的字段随材质走；`hdrScale = 1` 表示普通 8 位 cube（M9 路径原样）。
- 于是 `envIntensityOf(material.envMapIntensity, cube, scene.environmentIntensity)`（D157）在 CPU 侧
  一次性折成 `envMapIntensity · environmentIntensity · hdrScale`，**不新增着色器槽位**。

### 30.4 D155：HDR 背景要「解码 + 乘系数 + 色调映射」三段齐全

M20 的 `background` 变体只做了 sRGB 解码，直接把结果写进 `oc` —— 对 8 位颜色是对的，对 HDR 就少了
两段（辐照度要乘 `hdrScale·backgroundIntensity`，再走色调映射）。M25 把背景程序分成四选一：

| 条件 | 程序 |
|---|---|
| 8 位 cube | `_bgCubeProgramPlain` / `_bgCubeProgramDecode`（M20 原有） |
| HDR cube（`hdrScale ≠ 1`） | `_bgCubeProgramHdr`（解码 + `fc2.x` 乘 + 片元内色调映射） |
| 且 `backgroundBlurriness ∈ (0, 0.5]` | `_bgCubeProgramHdrBlur`（五 tap 锥，`BACKGROUND_BLUR_RADIUS = 0.5` 弧度） |
| 且 `backgroundBlurriness > 0.5` | `_bgCubeProgramHdrBlur9`（九 tap 锥：`±X`/`±Z`/`±Y` + XZ 对角，`fc6.w = 1/9`） |

**踩到的坑（AGAL 硬约束）**：模糊分支原本先写 `ft0.xyz` 再 `mov oc, ft0`，`adl` 直接拒绝
（`Error #3647/#3648`：`ft0` 在写入前被读）。改法是**先写满四分量**再改 `.xyz`：
`mul ft0, ft4, fc4.wwww` → `pow ft0.xyz, ...` → `mul ft0.xyz, ...` → `mov ft0.w, ft4.wwww`。

### 30.5 D156：`backgroundBlurriness` 用**分档**角度锥近似，不查 LOD

AGAL 里**没有** `textureCubeLod`、也没有反馈「按粗糙度选 mip」的手段，所以 three.js 的
「预滤波 cube + LOD」在本后端不可表达。M25 第一版是单一档位：`backgroundBlurriness > 0` 一律走
五 tap 锥（`BACKGROUND_BLUR_RADIUS = 0.5` 弧度）。问题不在于它不精确（那已登记为 D156 的边界），
而在于**它不随强度变化**：`0.01` 和 `1.0` 渲染出同一张图，`backgroundBlurriness` 事实上退化成了
布尔量——调用方按 three.js 语义做 0→1 渐变时，画面在 0 处跳变一次，之后不再变化。

现在按**tap 数分档**，`blurTapsFor(blurriness)` 是选程序的唯一真源（渲染器与冒烟共用它）：

| `blurriness` | tap 数 | 程序 | 轴寄存器 |
|---|---|---|---|
| `<= 0` / NaN / 负 | 0 | `_bgCubeProgramHdr`（清晰） | — |
| `(0, 0.5]` | 5 | `_bgCubeProgramHdrBlur` | `±X`（fc3）、`±Z`（fc4，`w = 1/5`） |
| `> 0.5` | 9 | `_bgCubeProgramHdrBlur9` | 追加 `±Y`（fc5）、XZ 对角（fc6，`w = 1/9`） |

宽档的 `ft0` 累加在 `ft4` 里、最后一次 `mul ft0, ft4, fc6.wwww` 归一，再走 `pow` 解码 +
`fc2.xxx`（`hdrScale · backgroundIntensity`）+ 色调映射，与窄档逐指令同构。锥角仍是 0.5 弧度
（`BACKGROUND_BLUR_RADIUS`），所以最强档也不是 PMREM：**这是「强度可分」而不是「正确」**，
`envMap` 的镜面反射仍然没有粗糙度预滤波（M9 的 `mix(R,N,r²)` 近似继续沿用，M25-R1 未动）。

### 30.6 验收

- 冒烟 `probes/hdr-smoke-m25/`（`HDRSmokeM25.as`，**66 项 ALL PASS**）：A RGBE→线性锚点；B 头部/轴向/
  三种扫描线/`EXPOSURE`/xyze 与非 HDR 的拒绝；C 方向着色全景 → 六面中心与偏心 tap（抓翻转 v 轴、
  面序、经度镜像）；D 8 位伽马编码与 `hdrScale` 互逆；E `autoScale` 分位/2 的幂/下限 1；F 渲染器纯函数
  与 `Scene` 默认值（含 `bgTapAxes` 的 16 槽布局与 `blurTapsFor` 的 0/5/9 分档）；G `.exr` 解码
  （见 §33）。
- demo `apps/hdr-m25/`：只由一张 512×256 的 `assets/textures/hdr/studio.hdr` 照明（无直射光），
  五个金属球 `roughness = 0.05/0.2/0.45/0.7/1.0` + 深色粗糙地面。按键 `1` 背景模糊 0↔1、`2` 环境强度
  1→2→0、`3` 背景强度 1→0.4、`4` 背景切清屏色、`5` 环境开关、`6` 重烘焙 128↔64 px、`7` 全景源
  `.hdr` ↔ `.exr`（§33）。AOT 日志：
  `HDR panorama 512x256 exposure=1` / `bake 128px in 17ms, autoScale=64, hdrScale=64, colorSpace=srgb`。
- 资产生成器 `tools/gen-hdr.js`（合成全景：暖调 softbox 辐照度 60、冷调 rim 25），产物入库，
  保证 demo 不依赖外网。

### 30.7 遗留

1. ~~**M25-R1**：没有 PMREM/多级预滤波 ⇒ 粗糙金属的反射仍然偏「清晰」~~ ⇒ **已做**（§35：CPU 六档
   粗糙度阶梯 + `fs7` 按 `material.roughness` 选档 + `PrefilterJob` 分帧烘焙，D174/D175/D178）。
   仍**不是** PMREM：没有 CubeUV mip 链、没有真正的 LOD 选层、烘焙单线程。
2. ~~**M25-R2**：`backgroundBlurriness` 是固定角度锥~~ ⇒ **已做**（§30.5 分档 5/9 tap + `blurTapsFor`）。
   仍不是 three.js 的 LOD 语义：锥角固定、强度只能分两档（D156 的边界没变）。
3. ~~**M25-R3**：`.exr` 不认~~ ⇒ **已做**（§33：`EXRLoader`，NONE + RLE；ZIP/PIZ/PXR24/B44/DWA
   仍按名拒绝）。
4. **M25-R4**：cube 面烘焙是单线程 CPU，128px 需 4–17 ms；更大面尺寸（256/512）会进百毫秒级，
   应在后台帧分片，本轮未做。

---

## 31. loader 行为对齐审计（L1–L12、D158–D161，2026-11-01）

口径：**AOT 先行**（README §1.1）。参考物是 three.js r187 的 loader 源码（`three-src/src/loaders/`，
`FileLoader.js` / `ImageLoader.js` / `TextureLoader.js` / `CubeTextureLoader.js` / `Loader.js`）；
AIR 侧只作为「AS3 传输层」的既有事实来源（`URLLoader` / `URLRequest`），不作为对齐目标。
本轮把审计落到一张可逐条判定表，其中 **L1/L2/L3/L4 已修并钉住**，其余登记为待办。

### 31.1 L1（已修 · D158）：per-load 状态，不是实例字段

**症状**：`FileLoader` / `ImageLoader` / `TextureLoader` 把 `onLoad`/`onError` 与中间对象存在
**实例字段**里。同一个实例上连续 `load()` 两次时，第二次覆盖字段，于是：

- `ImageLoader`：第一张图解码完成 → 调用的却是**第二个** `onLoad`（`racyCallsA == 0`、`racyCallsB == 2`）；
- `TextureLoader`：两张图都写进**第二个** `Texture`，第一个 texture 永远是空的；
- `FileLoader`：第一个文件的字节交给第二个回调（旧 D33 把它写成「第二次顶替第一次」，实际比那更糟）。

three.js 之所以没这个问题，是因为每次 `load()` 都新建闭包（`TextureLoader.js:46`、`ImageLoader.js:70`）；
AS3 里方法内的闭包同样**每次调用一份**，所以照抄那个形状即可（与 `CubeTextureLoader._loadFace`
为了「循环变量按次捕获」而拆方法同源）。

**修法**：三处都改成「本次调用的局部变量 + 局部闭包」，实例上不留任何在飞状态；
`CubeTextureLoader` 的六面计数与回调也搬进 per-load 的 `state` 对象。
`abort()` 需要「本实例所有在飞请求」，那是**唯一**留在实例上的东西（`_inflight` 数组），
与 three.js 的 per-instance `AbortController` 同形。

**证据**：A/B 变异实验 —— 把 `ImageLoader` 的回调改回实例字段后，
`probes/loader-smoke-m5/` 的第 10 节立刻红（`first onLoad fires exactly once (got 0)`），
恢复后全绿。探针还带反证：两张夹具图 `(10,10)` 像素必须不同，否则「各自拿到自己的图」无法证伪。

### 31.2 逐条判定表

| # | 项 | three.js r187 | 本轮处置 | 依据 |
|---|---|---|---|---|
| L1 | per-load 状态 | 每次 load 新建闭包 | ✅ 已修（D158，三处 + cube） | 并发加载会交叉投递（31.1 实测） |
| L2 | `ImageLoader.load()` 返回值 | 返回 `Image`（`:55`） | ✅ 已修（D159）：返回 `flash.display.Loader`，`COMPLETE` 后 `.content` 就是交给 `onLoad` 的 `Bitmap` | 无返回值时调用方只能等回调，且无法在自己手上持有解码句柄 |
| L3 | `responseType = 'json'` | `response.json()`（`:229-247`） | ✅ 已修：`JSON.parse` 后交付对象 | 静默当 text 会让 `data.metadata` 变 `undefined`，属 §1.5 禁止的静默降级 |
| L4 | `'blob'` / `'document'` | `response.blob()` / `DOMParser` | ✅ 已修：走 `onError` 报明「no AS3 counterpart」 | as-aot 无 Blob/DOM 解析器；报明优于假装 |
| L5 | `setResponseType` / `setMimeType` / `setRequestHeader` / `abort()` | `FileLoader.js:332/347/336/357` | ✅ 已修（D160） | `requestHeader` **不是** XHR 专有：`URLRequest.requestHeaders` 是真状态且运行时真的发（`src/emit.ts:16253`）；`abort()` 有 `URLLoader.close()`（取消后不再派发任何事件）。**D25 就此收窄**为只包含 `priority` / `cache` |
| L6 | `LoadingManager`（`itemStart/itemEnd/itemError/onStart/onLoad/onProgress/onError/setURLModifier`） | `src/loaders/LoadingManager.js` | ✅ 已修（D162–D164，§31.8） | 这是 three.js 唯一能观测「整体加载进度 / 失败聚合」的通道，也是资源路径重映射（`setURLModifier`）的钩子。构造签名用**可选参数**扩展（`new FileLoader(manager)` + `setManager()`），既有调用零改动 |
| L7 | fetch 去重扇出（`loading[url]`）与 `Cache`（`file:` / `image:`） | `FileLoader.js:86-110`、`ImageLoader.js:56-76` | ⬜ 登记（**不做**，D161） | native 每次 `load()` 就是一次本地读，代价可接受；引入去重表会让「谁负责关闭/取消」变复杂，而收益只在同 URL 重载时才出现。口径：**不做，但写清**，不假装有 |
| L8 | `loadAsync`（Promise） | `Loader.js:108` | ⬜ 不借（D24），可选增强 | AS3 无 Promise。若将来要「等一批加载完」，正确形态是 `EventDispatcher` + `COMPLETE` 汇总（**增强**，默认产物不引入） |
| L9 | `priority` / `cache` | `Loader.js:207/222` | ⬜ 不借（D25 收窄后的剩余） | 无客户端调度器 / HTTP 缓存可挂 |
| L10 | `crossOrigin` / `withCredentials` | `Loader.js:136/152` | ⬜ 字段保留、不生效 | native 无同源策略与凭据模型；保留是为了照抄 three.js 代码时不必删行 |
| L11 | `CubeTextureLoader` 六面数量校验 | 不校验（少于 6 时 `onLoad` 永不触发） | ⬜ 保留我们的报错（分歧已登记） | 挂起不报比报错难查；这是**刻意更严格**，不是欠账 |
| L12 | `GLTFLoader.register()` / `pluginCallbacks` | 扩展的公开注册入口 | ✅ 已修（D165，§31.8）：`register(callback)` + `getMaterialType`/`extendMaterial`/`createNodeMesh`/`afterRoot` 四个钩子 | 内建 `KHR_*` 仍是逐个 `if`（它们是**规范内**的，不该走插件通道）；插件通道给的是**规范外**扩展的接入点。压缩扩展（Draco/meshopt/basisu）仍登记为「不落」 |
| L13 | `ImageLoader` 的 `onProgress` | 文档明写不支持，永不调用 | ✅ 已对齐（维持） | 解码没有进度流 |
| L14 | `ObjectLoader` / `BufferGeometryLoader` | 见 §12 D27–D29 | ✅ 既有口径不变 | — |

### 31.3 D159：`ImageLoader.load()` 返回解码句柄

three.js 返回 `Image`，调用方可以把它**立刻**塞进 `Texture` 再等 `load` 事件；我们没有 `Image` 类型，
对应物是 `flash.display.Loader`（`COMPLETE` 后 `.content` 是 `Bitmap`）。
基类 `Loader` 刻意不声明 `load`（D26），所以直接加返回值不会破坏任何签名。

### 31.4 D160：`requestHeader` / `abort()` 从「不借」改为「借」

D25 当初把 `requestHeader` 与 `priority`/`cache` 打包成「XHR/fetch 关注点」一起不借。审计发现这条
**不成立**：`URLRequest.requestHeaders` 是 AIR 的一等属性（数组元素是 `URLRequestHeader`），
运行时在 `net__prepare_request` 里逐条拼进请求（`src/emit.ts:16251-16260`），所以它是**可表达的**；
`abort()` 同理（`URLLoader.close()`，取消后不派发任何事件）。⇒ D25 收窄为 `priority`/`cache`，
新增 D160 承接这两项。

### 31.5 D161：不做 fetch 去重扇出与 Cache

口径与「支持子集诚实声明」一致：**不做**，并在表里写清（L7）。注意这条**不是**能力缺失的借口——
它带来的是可观测差异：three.js 里同一 URL 并发两次只读一次、两个回调都拿到**同一对象**；
我们读两次、两个回调各拿到**不同对象**（内容相同）。凡依赖对象身份（例如「两张 Texture 的
`image` 是同一个 BitmapData」）的移植代码会看到差别。

### 31.6 验收

`probes/loader-smoke-m5/` 新增第 9–13 节（共 **24** 条断言）：

- 9：`ImageLoader.load` 同步返回句柄、句柄 `.content` 就是回调收到的 `Bitmap`；
- 10：同一 `ImageLoader` 实例并发两张图，两个回调各拿到自己的图（带「两图必须不同」的反证）；
- 11：同一 `FileLoader` 实例并发两文件（png 1072 字节 / suzanne JSON），各拿各的字节数；
- 12：同一 `TextureLoader` 实例并发两张图，两个 `Texture` 各持有自己的 `image`；
- 13：`json` 交付对象且链式 setter 返回自身、`'document'` 报明、`setRequestHeader` 不打断传输、
  `abort()` 让两个回调都不触发且**第二次调用是静默 no-op**。

A/B：把 `ImageLoader` 的回调改回实例字段 → 第 10 节红；恢复 → 全绿。
同轮回归：`loader` / `asset-load` / `gltf-m8` / `env-m9` 四个探针全绿。

### 31.7 遗留

1. **L7 去重与 Cache**：按 D161 **不做**，但移植依赖对象身份的代码时要先读这一条。
   探针 §14e 用「同一 URL 并发两次拿到两个不同 `ByteArray`」把这条差异钉成了可证伪的断言。
2. **`TextureLoader` 的 `texture.image` 语义**：three.js 存 `Image` 元素，我们存 `BitmapData`
   （kit 的 `Texture.image` 类型即 `BitmapData`）。探针 §14d 钉住类型，移植依赖 DOM 元素的代码要改写。
3. **`manager.abortController` 不落**（D163）：批级取消需要每个 loader 维护「可解析的在飞表」，
   是独立决策；当前逐实例 `abort()` 已覆盖单 loader 的取消。
4. **`addHandler`/`getHandler`/`removeHandler` 已实现但不被消费**（D164）：形状在、接线未做，
   等真正需要「按扩展名换 loader」时再接。
5. **`KHR_texture_transform.texCoord > 0` 不支持**：与 D44 同源（只采样 `TEXCOORD_0`），
   代码里 `trace` 报明并退化为对 uv0 施加变换。

### 31.8 L6/L12 落地：管理器、插件表与逐引用变换（D162–D166）

三件事一起做，因为它们的触发面重叠（都要在 loader 的 IO 边界上挂东西）：

| # | three.js 形态 | 我们落地 | 为什么 |
|---|---|---|---|
| **D162** | `resolveURL()` 先 `url.normalize('NFC')` 再交给 `urlModifier`（LoadingManager.js:150-166） | 只做 `urlModifier`，**不**做 NFC 归一化 | as-aot 没有 Unicode 归一化数据，调 `normalize` 要么抛错要么是假的。非 NFC 的 URL 按原样交给文件系统（three.js 会按 NFC 形式编码），差异写在此处而不是掩饰 |
| **D163** | manager 级 `AbortController` 并进每个 fetch 的 signal，一次调用可取消整批 | 不落；取消仍是每个 loader 自己的 `abort()`（D160） | 批级取消要求每个 loader 持有「可解析的在飞表」并让 manager 能枚举它们——那是新的一层所有权，不是形状问题。单 loader 取消已覆盖实际用例 |
| **D164** | `addHandler(regex, loader)` / `getHandler` / `removeHandler` | **实现但不消费**：表与匹配（按注册顺序 `String.search`）都在，kit 内没有任何 loader 查询它 | 移植代码里若注册了 handler，不该崩；但「按扩展名换 loader」在本 kit 没有真实用例，接线等于凭空造需求 |
| **D165** | `register(callback)` 后 hooks 是 async，`extendMaterialParams(index, params)` 往**字典**里写 | 同步钩子，直接给**实例**：`getMaterialType(index)->Material\|null`、`extendMaterial(index, material, def)`、`createNodeMesh(index, def)->Object3D\|null`、`afterRoot(root)`。插件拿到的「parser」就是 loader 本身（公开面：`json`/`materialAt`/`meshAt`） | AS3 无 Promise（D24），也没有「类值」可返回（`getMaterialType` 在 three.js 返回构造器）。给实例 + 原地改写等价且不撒谎；触发面（`extensions` 里出现该扩展名）与 three.js 完全一致 |
| **D166** | `KHR_texture_transform` 写 `texture.offset/repeat/rotation`，必要时 `texture.clone()` | 一样，但显式 `clone()` **每个纹理引用**：`offset`/`rotation`/`scale` 落在克隆上，索引缓存的纹理不动 | 两个材质槽可以带不同变换而指向同一张图；直接改缓存纹理会串味（探针 §14i 用「带变换的槽 `repeat=2,3` / 不带变换的槽 `repeat=1,1` 且两者 `map !== map`」把这条钉住） |

**钩子调用必须按声明元数（arity）派发**：AS3 与 AIR 一样，用多于声明的参数调用闭包会抛
`Error #1063: Argument count mismatch`。所以 `_invokeOne("createNodeMesh")` 传 2 个参数、
`_invokeOne("getMaterialType")` 传 1 个、`_invokeAll("afterRoot")` 传 1 个、
`_invokeAll("extendMaterial")` 传 3 个——不是「传三个再用不到的丢掉」。这是实测踩到的
第一版故障（`plugin glTF parses (got #1063)`）。

**顺带修掉一条同类缺陷**：`RGBELoader` 是 L1 审计**之后**写的，把 `_req`/`_onLoad`/`_onError`
又放回了实例字段（同一实例第二次 `load()` 会把第一个文件的字节交给第二个回调）。
按 D158 改成 per-load 局部闭包，探针 §14j 用两个并发 `load()` 各拿一次 `width=512` 钉住。

**验收**：`probes/loader-smoke-m5/` 第 14 节 **22 条断言**（`ALL PASS`）——
批聚合 `onStart` 一次 / `onProgress` 每项一次 / `onLoad` 一次、失败项 `itemError` 命名 URL 且
仍 `itemEnd` 平衡批次、`setURLModifier` 收到的是**已拼 path 前缀**的 URL 且真的改写了读取结果
（1072 字节的 checker 被改成其它长度）、`texture.image is BitmapData`、同 URL 并发两次拿到
**两个不同对象**（D161）、3 个面 URL 走 `onError` 不挂起、`ImageLoader` 永不调 `onProgress`、
插件四钩子各自命中一次且 `extendMaterial` 的改写存活、`KHR_texture_transform` 逐引用生效。

## 32. M26 对拍：确定性回读 harness（`apps/m26-parity/`）与 M26-R1/R2 结案（2026-11-01）

§29.8 的对拍靠**截窗口**，因此每一条读数都要跟三个无关变量搏斗：窗口标题栏（AOT 32px、`adl` 0px）、
截图缩放、以及**动画相位**。M26-R1/R2 一直挂着，根子是量具不是渲染器。本节把量具换成
**进程内回读**，并把两个遗留项各给出判定。

### 32.1 量具：`apps/m26-parity/`

- 400×300 固定 stage；`Soldier.glb` 的 `Idle` 动作**只 `mixer.update(0)` 一次**，姿态全程冻结
  （相位不再是变量）。
- 渲染完用 `Context3D.drawToBitmapData()` 读**后缓冲**，与 `tools/refscene/` 的 `__stats(box)` 用
  **同一组分数框**（本体 `0.44,0.44,0.56,0.62`、地面 `0.30,0.80,0.70,0.95`）与同一统计口径
  （Rec.709 luma 的 mean/p50/p90），不经过窗口、不做截图、不做缩放。
- `tools/refscene/walk-m26.html` 新增 `?w=&h=`，于是参考页可以**渲染成同样的 400×300** —— 尺寸不
  同就不再是比较，§29.8 的撤回正是因为这个。

### 32.2 量具本身踩到的三个坑（都已修，写进代码注释）

1. **回读比渲染慢一拍，而且是「环」不是「一帧」**：同一帧连调两次 `drawToBitmapData()`，第一次
   拿到 0、第二次拿到 28.43（同一像素框）。Metal 的 drawable 是环形复用，读到的是若干帧前的
   surface。做法：每次测量**连读 4 次取最后一次**。
2. **地面的 base-colour 贴图异步解码，落地帧号不固定**（实测 20～65 帧之间），落地前地面**画黑**。
   做法：不是猜一个 warm-up 帧数，而是**每帧读一次地面框，亮起来才开始测**（上限 600 帧）。
3. **单帧读取仍可能撞上「半张图」**：纹理/阴影落地晚一帧只会让区域**变暗**，所以每个状态连读
   3 帧、每个框取**最亮的那个 mean**（配 1 的 4 次读数，5/5 次运行逐字节一致）。

另外 `_renderer.render()` **不要在 `afterFrame()` 里再调一次**：`Stage3DApp` 每帧已经 render +
present，叠加的第二遍会重入延迟清屏路径，地面时有整块变黑。

### 32.3 参考页自身有两个 bug（**旧的「真值」全部作废**）

1. **`<script type="module">` 里 `GLTFLoader().load(..., (gltf) => {` 少一个收尾的 `} );`** —— 整个
   模块语法错误（`node --check`：`Unexpected end of input`），页面**一行都没执行**：`__stats` 是
   `undefined`、`performance.getEntriesByType('resource')` 为空（连 three.js 都没去取）。也就是说
   §29.8 表里那两行「three.js 雾开 20.75 / 雾关 11.45」**不是这个页面在同一状态下给出的数**，不能
   再引用。已补上收尾并加了一行 `window.__errs` 诊断（模块解析失败不再是「白屏没法说」）。
2. **参考页漏了 `metalnessMap = map`**：`webgl_animation_walk` 让金属本体的 metalness 走 base-colour
   图蓝通道，`apps/walk-m26`、`apps/m26-parity` 都照抄了，参考页却没设 —— 同一帧本体 mean
   `26.02`（无 map）对 `42.25`（有 map），**差 1.6 倍**，足以解释一大半「AOT 偏亮」。已改为默认设置，
   并留 `?metalmap=0` 以便对照。

### 32.4 新真值表（400×300、姿态冻结、ACES 曝光 0.5、单 `DirectionalLight` 强度 5）

两个框各自包含背景（雾色 93）与地面，所以「本体框」不是纯本体 —— 两端量的是**同一块屏幕区域**，
这就够比较了。

| 配置 | 本体 mean | p50 | p90 | 地面 mean |
|---|---|---|---|---|
| three.js，金属 + 贴图地面，雾开 | 42.25 | 32.00 | 105.36 | 23.74 |
| AOT，同上 | 46.72 | 22.91 | 236.49 | 28.43 |
| three.js，金属 + 贴图地面，雾关 | 34.22 | 17.00 | 105.85 | 21.20 |
| AOT，同上 | 40.54 | 19.63 | 238.00 | 27.21 |
| three.js，金属 + **纯灰地面**，雾开 | 56.62 | 44.20 | 108.21 | 110.66 |
| AOT，同上 | 60.34 | 22.91 | 236.49 | 108.82 |
| three.js，金属 + 纯灰地面 + **关阴影**，雾开 | 66.70 | 66.23 | 115.42 | 110.66 |
| AOT，同上 | 77.01 | 52.96 | 251.00 | 108.82 |
| three.js，电介质本体（`metalness=0`、`roughness=0.9`、`0x808080`、无 normalMap）+ 纯灰地面 | 39.50 | 21.00 | 107.00 | 110.66 |
| AOT，同上 | 35.07 | 17.42 | 100.21 | 108.82 |

开关在职：`apps/m26-parity` 的三个常量 `DIFFUSE` / `NO_NORMAL` / `NO_SHADOW` / `FLOOR_PLAIN`，
参考页对应 `?mat=diffuse` / `?nonormal=1` / `?noshadow=1` / `?floor=plain`（外加 `?metalmap=0`）。

### 32.5 判定一：**M26-R2（雾抬升偏小）撤回，雾是对的**

雾是「线性空间里朝雾色 `0x5e5d5d`（线性 0.1096）混合」，所以在 luma 空间做减法比较没有意义
（§29.8 的 `+5.50` 对 `+9.30` 就是这么来的）。把两端起止值**反解回线性空间**再求混合系数：

- 参考：本体 `34.22 → 42.25` ⇒ `f = 0.0728`
- AOT：本体 `40.54 → 46.72` ⇒ `f = 0.0705`

**差 3%**。`vFogDepth` 的口径（`-mvPosition.z`，即 `(v1 - camPos)·forward`）与「色调映射之前混合」
都对，M26-R2 不是缺陷 —— 它看着像缺陷，只因为起点亮度不同（雾往亮色拉，起点越亮抬得越少）。

### 32.6 判定二：M26-R1 拆成三条，最可疑的**不是**镜面项

1. **光照基线是对的**：纯灰地面（无贴图、无 normalMap）`108.82` 对 `110.66` = **−1.7%**，雾关
   `110.06` 对 `111.0` = −0.8%。曝光、ACES 三点拟合、输出编码、直接光强度全部落在 2% 内 ⇒
   往后不要再用「整体偏亮」描述这个场景。
2. **贴图地面 +20%**（`28.43` 对 `23.74`）：同一块地面，唯一差别是**采样一张 sRGB 棋盘贴图**。
   我们的解码是 `pow(x, 2.2)`，真 sRGB 传递函数在 0.5 灰上只差 **1.7%**，解释不了 20% ⇒
   嫌疑转到 `repeat`/`wrap`/mip 采样（`anisotropy` 参考取 `getMaxAnisotropy()`，我们不支持）。
   这是 **M26-R1a**：拿 `?floor=plain` 对 `FLOOR_PLAIN` 已排除光照，下一步只需把贴图换成
   「纯色 1×1」与「repeat 1 的棋盘」两级，就能把 wrap/mip 从解码里分出来。
3. **金属高光瓣太尖太热**：`p90 236 对 105`（2.2 倍，接近饱和 251 对 115）、`p50 只有参考的一半`。
   均值反而只差 6.6%～15%，所以**不是能量问题，是分布问题**。注意 r187 的直接光还乘
   `material.multiScatteringCompensation = 1 + F0·(1/Ess − 1)`（`Ess = dfgLUT.x + dfgLUT.y`，白色
   `F0` 时 ≥1，即**参考那边更亮**），我们没有这一项 ⇒ 越发光谱上「我们的高光更热」不能拿补偿解释，
   只能是 `D_GGX`/`V_GGX_SmithCorrelated` 的归一或 `roughness→alpha` 实测不一致。这是 **M26-R1b**，
   量具已经就位（`?noshadow=1` 关掉阴影后 p90 251 对 115，噪声更小）。
4. **顺带登记 N5**：`dfgLUT` 是一张 256×256 的 2D 查表（`lights_fragment_begin` 里按
   `(roughness, dotNV)` 取），我们后端**完全能采一张 8 位 LUT**，不必上 float —— 这既补
   `multiScatteringCompensation`，也补 IBL 的 `F·AB` 精确值（M9 现在用的是解析近似）。

### 32.7 量具自身的教训（别重犯）

- **`Color.setRGB(0.5,0.5,0.5)` 不是「中灰」**：`setRGB` 按工作空间原样存，参考页的
  `color.set(0x808080)` 走 sRGB→线性得 0.216。第一版 harness 拿 `setRGB(0.5)` 对 `0x808080`，
  得出「电介质本体偏亮 53%」的假结论；改成 `setHex(0x808080)` 后同一帧变成 **−11%**。设颜色一律用
  `setHex`（或明确说「我要线性值」）。
- **`drawToBitmapData()` 读到的是环形 drawable**：同帧连读 4 次，前几次是旧帧（0 对 28.43）。
- **就绪判据不能用固定帧数**：地面贴图在 20～65 帧之间任意落地，落地前地面画黑；纯灰地面则没有这个
  等待，于是「等 60 帧」在两种配置下量到的是不同阶段。现在的要求是**两个框连续 5 帧不动**才开始测。

### 32.8 R1a 分层实验：albedo 路径洗清，剩下的在「贴图内容 × 过滤」

R1a 的原假设是「地面 +20% 来自贴图采样（wrap / mip / anisotropy / sRGB 解码）」。要让这个假设可证伪，
先得把 **albedo 本身固定住**，再让「有没有贴图」成为唯一变量。两侧因此各加了三组旋钮：

| 旋钮 | 参考页 | harness |
|---|---|---|
| 无贴图纯色地面 | `?floor=plain&floorcolor=RRGGBB` | `FLOOR_PLAIN` + `FLOOR_COLOR` |
| 1×1 纯色贴图（走解码，但无 mip / 无 wrap / 无空间平均） | `?floor=solid&floorlevel=N` | `FLOOR_SOLID` + `FLOOR_SOLID_LEVEL` |
| 去掉地面法线贴图 | `?floornormal=0` | `FLOOR_NO_NORMAL` |

`FLOOR_COLOR = -1`（参考页同义：`?floorcolor=` 缺省）表示**按模式取默认**——纯色地面 0x808080、
贴图地面 0x404040，所以默认配置仍逐字复现 §32.4 真值。量法：`fog=0`、`noshadow=1`、
`floornormal=0`、roughness 0.85，只动 `albedo = linear(color) × linear(texel)`：

| 地面 | albedo | AOT | three.js（fog=0） | 判定 |
|---|---|---|---|---|
| 纯色 `0x808080` | 0.216 | 110.06 | 111.00 | −0.8% ✓ |
| 1×1 `0x80` × color 白 | 0.216 | 111.31 | ≈111（同上） | +0.3% ✓ |
| 1×1 `0xff` × color 白 | 1.000 | 207.00 | 209.00 | −1.0% ✓ |
| 纯色 `0x404040` | 0.0513 | 46.30（3/3 稳定） | 43.00 | +7.7% |
| **棋盘格 16×16** × `0x404040` | 内容相关 | 27.21 | 21.20 | **+28.4%** |
| 棋盘格 `repeat=1`（放大，无 minification） | 同上 | 24.95 | 19.45 | **+28.3%** |

**结论一（原假设部分作废）**：albedo 相同的纯色 / 1×1 贴图对照全部落在 ±1%，其中就包含 sRGB 解码
（`pow(x,2.2)` 对 0x80 的偏差只有 1.7%）。所以「wrap / anisotropy / decode 把地面整体抬高」**不成立**，
`albedo` 的合成（`pow(texel,2.2) × fc4`）可以结案。

**结论二（剩下的问题收窄了）**：把贴图换回**真的棋盘格**，同样的 color、同样的 UV，就从 −0.8%/+7.7%
跳到 +28.4%，而且整条分布一起平移（p50 24.07 对 18.00、p90 34.07 对 29.72），说明是
**采样到的 albedo 均值比 three.js 高约 1/4**，不是噪声、不是分布形状问题。

**结论三（mip 路径也排除了）**：`?repeat=16` 改成 `repeat=1`（把贴图放大 16 倍，椅子上没有任何
minification，mip 链直接不参与）后，两侧同时下降（`27.21→24.95` 对 `21.20→19.45`），**差值比例
几乎不变：+28.4% → +28.3%**。所以「我们 `mipnone`、three.js 三线性 + 各向异性 16」不是原因，
mip 可以出局。

到这里，能排除的已经排完：albedo 合成（`pow(texel,2.2) × fc4`）、`pow` vs 真 sRGB（0x80 处 1.7%）、
wrap、mip/anisotropy、贴图内容的空间平均（`repeat=1`）。剩下的疑点只指向「**同一批 texel 的解码
结果不同**」——旁证：这张棋盘格的平均编码值实测 `0x92/0x91/0x96`（约 0.57），真 sRGB 解出 0.283、
`pow(x,2.2)` 解出 0.295，两者只差 4%，都不足以解释 28%。下一步需要**把我们的 albedo 直接画到屏幕**
（沿用 `debugReflect` 那套默认关闭的诊断开关）逐 texel 对拍，而不是继续在外面猜。

### 32.9 量具第四个坑：「最亮的 3 帧」会把**没画上去**当成更亮

§32.2 里定过一条规则：「晚落地的贴图/阴影只会让区域变暗，所以同一状态读 3 帧取最亮」。这条在深色地面上
直接把 §32.8 第一版结论带进了沟里：同一个二进制、同一份配置连跑三次量到 `46.30 / 93.21 / 46.30`，
两个态各自还都均匀（`p50 == p90`），比值 ≈2.0，于是被误判成「深色地面有个 ~2× 的双态渲染 bug」。

真相是 **93.21 就是清屏色**：`0x5e5d5d` 上屏后 Rec.709 亮度 = `0.2126·94 + 0.7152·93 + 0.0722·93
= 93.2126`，与读数逐位相同 —— 那一帧**地面根本没画**（纯色地面的 draw 会偶发被丢），
而「取最亮」偏偏最喜欢这种帧。验证方式很土但很硬：把 `scene.background` 临时改成黑色再连跑三次，
深色地面立刻变成 `46.30 / 46.30 / 46.30`。

修法（已落地，写在 `keepBest` 注释里）：**任何与清屏色亮度相差 < 0.5 的样本一律丢弃并计数**，
结束时若 `dropped > 0` 就打印 `PARITY <tag> dropped=N`，不静默。

```text
0x5e5d5d 上屏 → 0.2126*94 + 0.7152*93 + 0.0722*93 = 93.2126   （BACKGROUND_LUMA）
```

顺带说明：**地板 draw 偶发丢失**本身是一个独立的真实缺陷（阴影/贴图都不相关，纯色地面尤其容易命中），
但它不再污染比对数值，因为丢帧现在会被记账而不是被当成“更亮”。这条留给 R1a′ 的第一件事。

---

## 33. M25-R3：`.exr`（OpenEXR 半浮点）解码（D167–D169，2026-11-01）

`RGBELoader` 只认 Radiance RGBE，`.exr` 一直被**按名拒绝**。拒绝是对的（不静默降级），
但「仓库里最常用的两种 HDR 之一不能读」始终是能力缺口。本轮补上 `EXRLoader`。

### 33.1 载荷仍是 `HDRImage`（D167）

three.js 的 `EXRLoader` 产出 `HalfFloatType` 的 `DataTexture`；本后端**没有任何浮点纹理格式**
（D152），而下游唯一消费者 `EquirectangularToCube` 的产物是 8 位伽马 face。所以 EXR 采样在
解析时就被压成 **Radiance RGBE 四元组**，与 `.hdr` 走同一条 `HDRImage` 通路：

- 精度账：RGBE 是 8 位尾数 + 共享指数量化，真正的 8 位 cube 面还会再量化一次；保留 float 只会
  让 2048×1024 全景多占 48 MB 换一个下游看不见的精度。
- 一致性收益：`sampleBilinear` / `bakeTexels` / `autoScale` / `hdrScale` 全部零改动，
  两种格式的环境强度口径天然相同。

### 33.2 支持面与拒绝面（D168/D169）

| 项 | 处置 |
|---|---|
| 压缩 NONE(0) / RLE(1) | ✅ 解码 |
| 压缩 ZIPS(2)/ZIP(3)/PIZ(4)/PXR24(5)/B44(6)/B44A(7)/DWAA(8)/DWAB(9) | ❌ **按名 + 代码报错**（需要 zlib 或专有预测器） |
| 像素类型 HALF(1) / FLOAT(2) | ✅ |
| 像素类型 UINT(0) | ❌ 报错（那是 id/mask，不是辐照度） |
| 扫描线、INCREASING_Y | ✅ |
| tiled / deep / multi-part / DECREASING_Y / RANDOM_Y | ❌ 按名报错 |
| `dataWindow` 非零原点、`displayWindow` ≠ `dataWindow` | ✅（尺寸取 dataWindow，chunk 的 `y` 减去 `yMin`） |
| chlist 里缺 R/G/B（含 `red/green/blue` 拼写） | ❌ 报错并列出实际通道名 |

### 33.3 坑：RLE 的载荷**不是**扫描线本身（本轮最大的一个）

第一版按「RLE 逐字节解压 → 直接当扫描线」写完，自测全绿：编码器与解码器互为逆阵，
4×2 到 256×128 都能原样还原。**但那是假的** —— 三个第三方读取器（OpenCV、ffmpeg、OpenEXR 自带
`exrheader`/`exrmetrics`）一致报第 43 行是 `NaN` / `±1.6e4` 垃圾，而且 OpenEXR 把我们的文件
重写一遍（`exrmetrics --convert -z none`）后**那条垃圾仍在**，证明不是读取器的毛病。

翻 OpenEXRCore 的 `internal_rle.c` 才看到：RLE **和 ZIP 一样**要先跑
`reorder_and_predict()` —— 先做字节间 delta（`d = cur - prev + 128`），再把偶数位字节打包进
前半段、奇数位进后半段 —— 然后才做字节 RLE。解码侧对应 `unpredict_and_reorder()`。
少了这两步，解出来的仍旧是「长度正确、看着像数」的噪声：**这是最坏的一种错**（不报错、不崩、
只是画面不对），比抛异常危险得多。

教训（写进 `EXRLoader` 的注释）：压缩容器的往返自测**证明不了格式正确**，必须拿第三方实现
对一次。`tools/gen-exr.js` 现在把同一份预测 + 拆分写进编码器，产物 8.8 KB（原始 196 KB），
OpenCV 与 ffmpeg 都能读出与 `radiance()` 逐点一致的像素。

### 33.4 资产与双格式对拍

- `tools/gen-exr.js` **import** `tools/gen-hdr.js` 的 `radiance()`，把同一张 synthetic studio
  全景写成 256×128 / HALF / RLE 的 `assets/textures/hdr/studio.exr`（`.hdr` 是 512×256）。
  两份资产必须描述同一间屋子，否则「换源看不出差别」证明不了解码正确。
- `apps/hdr-m25` 按键 `7` 在 `studio.hdr` 与 `studio.exr` 之间切源并重烘焙。AOT 日志：
  `panorama source=exr` / `HDR panorama exr 256x128 exposure=1` /
  `bake 128px in 17ms, autoScale=32, hdrScale=32` —— 五球的软箱高光、天空/地面分界与 `.hdr`
  版本一致（分辨率减半只让软箱边缘略软）。

### 33.5 验收

`probes/hdr-smoke-m25/` 新增 G 段（**11 条**，合计 66 条 ALL PASS）：

| # | 钉住什么 |
|---|---|
| G1 | `dataWindow` 决定宽高（4×2 非零原点仍正确） |
| G2 | 每个纹素 half → RGBE 往返误差 < 1%（实测 0.39%） |
| G3a | 构造出的 RLE chunk **确实比原扫描线小**（16 < 24）——否则 G3 会退化成空断言 |
| G3 | RLE（delta + 字节拆分）与 NONE 解码逐纹素完全相等 |
| G4 | `halfToNumber`：`0x3C00 → 1.0`、denormal `0x0001 → 2^-24`、`0x7C00 → +Inf`、`0 → 0` |
| G5 | ZIP 被按名拒绝（消息里带 `code 3`） |
| G6 | UINT 通道被拒（id/mask 不是辐照度） |
| G7 | tiled 被按名拒绝 |
| G8 | 错 magic 的报错里点名「not an OpenEXR」 |
| G9 | 缺 R/G/B 时报错并列出实际通道名 |
| G10 | `linearToRGBE` 往返 < 1/255 |

探针里的 EXR 是**现场拼字节**生成的（探针没有同步文件 IO），编码器与
`tools/gen-exr.js` 同一份算法；后者另有 OpenCV/ffmpeg 的交叉验证兜底（§33.3）。

---

## 34. M26-R1b 收口：三处 PBR 保真缺口（D170–D173，2026-11-01）

§32.6 把「金属本体分布不对」拆成 R1a（贴图地面）与 R1b（镜面叶瓣），当时只知道
`p50` 只有参考的一半、`p90` 是参考的 2.2 倍。本轮把 R1b 追到根因：**不是**叶瓣公式，
而是三处「我们比 three.js 少做了一步」的保真缺口。三处都已落地，另外顺手排除了四个
无辜嫌疑（见 §34.6）。**第四处（多散射补偿，D173）也落地了，但它不是那四分之一** ——
详见 §34.4/§34.5。

### 34.1 D170：sRGB 传递函数（R1a 的真正根因）

`three-api-design.md` 早就写着后缓冲是 sRGB 编码的，但解码/编码两处都用了 `pow(x, 2.2)`
这个近似。真实曲线 `f(x) = 1.055·x^(1/2.4) − 0.055` 在中间调与 2.2 差到 **3 个 8 位码值**，
而且**方向固定**：`pow(x,2.2)` 比真曲线暗，`pow(x,1/2.2)` 比真曲线亮。于是
「解码用 2.2 + 编码用 1/2.2」是一个**自洽但不是 sRGB** 的往返对：

- 中性贴图路径（`context = 1`）不受影响；
- 但贴图是**有内容的**，地面/本体的每个纹素都先被解码成偏暗的线性值，再被编码回来 ——
  一进一出互相抵消，**只剩非线性部分**：亮度对比被压低、暗部的贴图细节整体上抬。
  §32.8 量到的「贴图地面 +19.8%、纯灰地面 −1.7%」正是这个非线性残差的形状。

改成真曲线后（`SRGB_CONSTANTS = (1.055, 1/1.055, 0.055, 2.4, 1/2.4)`，上传到 `fc41/fc42`）：

| 量 | 改前（pow 2.2） | 改后（真 sRGB） | three.js |
|---|---|---|---|
| 地面 mean（雾开） | 28.43（+19.8%） | **21.79（−8.2%）** | 23.74 |
| 本体 mean（雾开） | 46.72（+10.6%） | **40.39（+4.4%）** | 42.25 |

- 曲线是**互为逆阵**的一对，这是 `D18`/`D27` 两条探针钉的东西：256 级全部落在 1 个码值内。
- 编码侧刻意**不做 toe**（`c ≤ 0.04045` 走 `c/12.92`）：那需要一个比较寄存器，而曲线形式的
  绝对误差 < 0.5/255。代价是亚黑区最多 +0.5 码值 —— 远小于丢掉「互逆」的代价。
- **踩的坑**：第一次写解码时把 `+0.055` 写成了 `fc41.wwww`（那是 2.4），于是解码变成
  `((c+2.4)/1.055)^2.4`，整帧发白（本体 mean 137、地面 179）。`fc41` 的 `.z` 才是 0.055。
  为此探针 `D11` 钉**逐字文本**、`D16/D17` 钉**数值**，两条一起才能抓住 .z/.w 互换。
- 连带缺陷：`_basicFragmentTail` 现在也以 `srgbEncodeBlock` 结尾，常量在 `fc41/fc42`，
  超过 AGAL1 的 28 个常量寄存器上限 —— **线框/Line 程序的顶点+片元都改成 AGAL4**
  （`AGALMiniAssembler` 对超限是打印错误后返回**空程序**，表现为「整条 draw 静默不画」）。

### 34.2 D171：数据槽也要解码（metalness / roughness map）

`metalnessMap = map` 是 `webgl_animation_walk` 的原样写法（`apps/walk-m26` 与
`apps/m26-parity` 都照抄）。在 three.js 里这**没有歧义**：sRGB 解码是纹理对象的属性，
由 GPU 的 sRGB 采样器完成，它不知道 texture unit 的用途 —— 所以 **metalness 读到的是线性蓝**。
我们是在片元里按槽位补解码的（M17），只覆盖了颜色槽（map/emissive/env），于是：

```text
metalness_我们 = 编码蓝（0.5 编码 → 0.5）
metalness_参考 = 线性蓝（0.5 编码 → 0.21）      // 高估最多 4 倍
```

金属度高估 ⇒ `diffuseContribution = baseColor·(1−m)` 被掐掉 ⇒ 金属只剩镜面、暗部发黑。
实测 A/B（`metalnessMap` 有/无的差值）：参考 **+62%**，我们只有 **+19%** —— 这就是
「我们的蓝色比参考更金属」的直接证据。

修法：`decodeMaskFor` 增加 `DECODE_ROUGHNESS = 8` / `DECODE_METALNESS = 16`，只读一个分量
（`.g` / `.b`），用 3 条指令的 `srgbDecodeScalarBlock`；glTF 的 metallicRoughness 贴图是线性数据
（`NoColorSpace`），两位都不会置 —— **这条只在「把颜色贴图复用成数据贴图」时生效**，
正是这个 demo 的形态。

### 34.3 D172：`geometryRoughness`（R1b 的真正根因）

`lights_physical_fragment.glsl.js:9-15` 在算完 `roughnessFactor` 之后还有一步：

```glsl
vec3 dxy = max(abs(dFdx(nonPerturbedNormal)), abs(dFdy(nonPerturbedNormal)));
float geometryRoughness = max(max(dxy.x, dxy.y), dxy.z);
material.roughness = max(roughnessFactor, 0.045);
material.roughness += geometryRoughness;      // ← 我们一直没有
material.roughness = min(material.roughness, 1.0);
```

这一步是**抗镜面走样**的关键，因为 `D_GGX` 在小粗糙度下近乎奇异：
粗糙度 0.2 时 `D(1) ≈ 199`，而 **`dotNH` 掉 1%（约 8°）就掉到 1.1（≈180 倍）**。
角色在 400×300 上只有几十像素高，逐像素法线变化量大，不加这一项，凡是「法线恰好平分 L/V」
的一片（扁平装甲板）就**整片打爆**，而邻近像素全黑 —— 实测就是这样：本体框里 10% 的像素
是 237（接近全白），中位数只有 15。

落地（`geometryRoughnessBlock()`，7 条指令）：`ft0` 归一化**之后、法线贴图扰动之前**
取 `ddx/ddy`，`abs`+两次 `max` 折成标量存 `ft12.x`，在取完 roughness 贴图后
`add` 进 `ft5.x` 并 `min(1)`。`flatShading`（M19）走另一支：面法线是常量，导数恒为 0。

| 量（雾开，本体框） | 改前 | +D172 | three.js |
|---|---|---|---|
| mean | 40.39 | 35.34 | 42.25 |
| **p50** | 15.34 | **22.55** | 32.00 |
| **p90** | 237.00 | **82.22** | 105.36 |

`p90` 从「参考的 2.25 倍」变成「参考的 0.78 倍」，爆掉的大片消失（ASCII 亮度图从
15×14 像素的实心 `@` 块变成与参考同位置的细条纹）。**代价**：整体能量掉 ~13%（爆块消失），
剩下的是均匀的 0.75 倍 —— 见 §34.4。

导数在**世界空间**取（我们在世界空间做光照，three.js 在视空间）：单位向量导数的模长
与坐标系旋转无关，所以这是同一个数。地板是平面 ⇒ 法线导数 0 ⇒ 该项为 0，
实测地板 mean 一前一后**完全相同**（21.79），这也是「改动只影响曲面」的旁证。

### 34.4 D173：多散射补偿落地 —— 但它**不是**那四分之一

**假设原文（保留，免得后人重走）**：三处修完，本体框是参考的 0.84 / 0.70 / 0.78 倍，
「整体偏低四分之一」，而 r187 还对直接镜面乘一项多散射补偿：

```glsl
EssMs = dfg.r + dfg.g                        // dfg = texture(dfgLUT, vec2(roughness, dotNV))
material.multiScatteringCompensation = 1.0 + specularColorBlended * (1.0 / EssMs - 1.0);
```

`F0 = 1` 的金属在 roughness 0.2 时 `EssMs ≈ 0.9`，系数 ≈ 1.11 —— 于是判定「缺这一项就是那
四分之一，`dfgLUT`/补偿是第一杠杆」。

**本轮把它实现了，假设被实测证伪。** 补偿公式里还有一个常被略读的乘数：

```glsl
comp = 1 + specularColorBlended * (1.0 / Ess - 1.0)
```

`Ess` 确实只由粗糙度决定（Karis 系数满足 `r.z + r.w = 1 − 0.55·roughness`，`a004` 在求和里
整体抵消），**但系数要乘 F0**。walk-m26 的本体是 `metalnessMap = material.map`：有效金属度
≈ 贴图蓝通道（≈0.2），于是 `F0 ≈ 0.07`；地面是介质 `F0 = 0.04`。实际拿到的补偿是：

| 材质 | roughness | Ess | comp | 确定性回读实测 |
|---|---|---|---|---|
| 地面（介质，F0 0.04） | 0.85 | 0.5325 | **1.035** | floor mean 21.79 → 22.17（+1.7%） |
| 本体（F0 ≈ 0.07，含 `geometryRoughness`） | 0.43 | 0.7635 | **1.020** | body mean 35.34 → 35.50（+0.5%） |

`×1.11` 只在 `F0 = 1`（纯白金属）时成立；对着一个 0.2 金属度、漫反射占主导的 glTF 材质，
它是 2%。**这一节的教训与方法论有关**：`Ess ≈ 0.9` 是从「粗糙度」推到「系数」时漏了 F0，
中间差了 5 倍 —— 所以本轮没有直接改常数，而是把补偿实现出来、用回读把它量出来。

#### 落地（三处使用点，与 r187 同序）

`AGALRenderer` 新增两个公共块（探针逐字钉住，H1–H10）：

- `envBRDFApproxBlock(ab, tmp)` —— Karis 的 12 条指令，产出 `ab.y = AB.x`、`ab.z = AB.y`，
  **永不写 `ab.w`**（标准程序把光 0 的 PCF 因子停在那里，写它等于悄悄关掉阴影）。
- `multiScatterCompBlock(out, ab, tmp)` —— `1 + specularColorBlended·(1/Ess − 1)`；标量先在
  `tmp` 里算完再乘 vec3，避开「写 `.xyz`、读 `.x`」的写掩码别名（stage346 那类坑）。

1. **标准直接光**：DFG 提到 Stage 5.5（r187 在 `lights_fragment_begin` 顶部算一次，之后
   直接光与 IBL 共用同一对 AB），直接镜面乘 `ft10.xyz`；第二盏平行光
   （`_secondLightBlock`）同乘 —— 补偿是**逐材质**而不是逐光。
2. **IBL 的 split-sum 两半**（`computeMultiscattering`）：以前只做
   `FssEss = Fr·AB.x + F90·AB.y`，现在补上 `Fms·Ems·irradiance/π`，其中
   `Fms = FssEss·Favg/(1 − Ems·Favg)`、`Favg = Fr + (1−Fr)/21`。`1/21` 落在原本恒 0 的
   `fc10.y`，没有加宽 `fc0..fc13` 常量块。`irradiance/π` 直接就是 N 方向采样乘
   `envMapIntensity`（`getIBLIrradiance` 乘进去的 π 与 `RECIPROCAL_PI` 互消）。
3. **点光/聚光**（`_buildPunctualProgram`）：r187 对**每一次** `RE_Direct` 都乘它
   （`lights_physical_pars_fragment.glsl.js:595`），所以加法光通道也要乘；punctual 程序此前
   只上传 `fc0..fc10`，现在上传 14 个（`fc11..fc13` 必须显式填，否则读到上一个标准 draw 的
   残留 —— 这是个只在「场景里既有平行光又有点光」时才现形的定时炸弹）。

指令预算：无 tone/无阴影变体 163 → **194**，阴影 + tone + fog 变体 **308/400**。

#### 怎么量出来的（可复用）

`ft5.x`（最终粗糙度）与 `1/Ess − 1` 都能**直接从 GPU 回读**：把 Stage 7 的色调映射与 sRGB
编码临时摘掉、`mov oc, <寄存器>`，8 位后缓冲里就是线性值本身。

- 地面读数 `224/255 = 0.878` ⇒ `Ess = 0.532`，与解析式 `1 − 0.55·0.85 = 0.5325` 逐位吻合。
- 本体 `p50` 读数 `78/255 = 0.306` ⇒ `Ess = 0.766`；同一帧的粗糙度读数 `p50 = 109/255 = 0.427`
  ⇒ 解析 `Ess = 0.7635`，两者一致。

这条同时验证了两件事：AGAL `exp` 确实是 2 为底（否则 `a004` 偏大、Ess 偏小），以及
`EnvBRDFApprox` 的系数没有传错。诊断改动全部回滚，仓库里只留 `dumpFragSource` /
`debugReflect` 两个默认关闭的开关。

### 34.5 那 16% 到底在哪？（下一步的正确方向）

补偿落地后本体仍是参考的 **0.84 倍**。用「把 comp 强行改成 2.0」做灵敏度标定可以反推镜面
在读数里的占比：`comp 1.124 → 2.0` 让本体 mean 35.34 → 40.54，即**镜面只占本体读数的约 15%**。

结论很直接：**本体不是「一盏镜面叶瓣」，而是「一个 0.2 金属度的漫反射体 + 一点点镜面」**
（不然 `geometryRoughness` 修正不会把 p90 从 237 打到 82 而 p50 只动 7 点）。所以剩下那 16%
要从**漫反射/反照率路径**找，而不是继续在 BRDF 上叠加常数：

- 漫反射的能量分配我们用的是 `1 − F_004`（介质菲涅尔），r187 用的是实际 `F`（`1 − F_blended`，
  对 0.2 金属度临界角附近差几个百分点）；
- IBL 漫反射的 `(1 − singleScattering − multiScattering)` 能量守恒项我们没做（对地面只差 2%，
  但本体的 F0 更高，差得更多）；
- 剩下的就是 R1a 的贴图路径（§32.6）：贴图采样/`uv` 与参考的差异在地面框上就摆着。

这三条都还没做，**登记为下一次收口的入口**；不要再回头怀疑 `D_GGX` / `V_GGX_SmithCorrelated`
的归一化（§34.3 已经把叶瓣排除了）。

### 34.6 排除掉的四个嫌疑（都做了 A/B，别再回头查）

| 嫌疑 | 实验 | 结论 |
|---|---|---|
| 金属度/粗糙度常量传错 | 在 `_fillStandardConstants` 里临时打印整组 `fc` | `r=0.2 m=1 light=5,5,5 ambient=0,0,0 envI=0 rmap=false mmap=true nrm=true` — 与参考逐项相同 |
| 法线贴图路径 | `NO_NORMAL` / 参考 `?nonormal=1` | 两端都几乎不变（参考 42.25→41.80，我们 40.39→41.03）⇒ 法线贴图**不是**因子 |
| 面罩（`vanguard_visor`，`roughness=0.045` 透明镜面） | 参考页新增 `__only(name)` 逐网格隔离 | 面罩**根本不覆盖**本体框（只拍面罩时整框 = 清屏色 93.21）；我们隔离本体后读数一字不差 |
| 阴影 | 两端关阴影（`NO_SHADOW` / `?noshadow=1`） | 形状差依旧（我们 p50 33 / p90 180，参考 66 / 115）⇒ 不是阴影，是叶瓣 |

`tools/refscene/walk-m26.html` 为此新增三个诊断把手（已写进该目录 README）：
`__scene` / `__renderer` / `__names()` / `__only(name)`。

### 34.7 验收

- 探针 `probes/texstate-smoke-m17/` 从 45 条增到 **78 条 ALL PASS**：
  `D11`–`D18` 钉 sRGB 解码/编码文本与数值、`D19`–`D27` 钉数据槽位与标量解码、
  `G1`–`G3` 钉 `geometryRoughnessBlock` 的逐字文本（含「两次 max 折叠」「两个 abs」）、
  `H1`–`H10` 钉 D173：DFG 十二句、`ab.w` 不可写、`-9.28` 不折 ln2、补偿公式、
  `Ess = 1 − 0.55·roughness` 在**全 roughness × 全 NoV 网格**上成立、`comp ≥ 1`、
  以及两种材质实际拿到的 1.035 / 1.020。
- 全量探针 25 组全绿；`apps/m26-parity` 仍是确定性回读（§32.1），本轮读数：
  `fog=1 body 35.50/22.62/82.29, floor 22.17`。
- `apps/light-m6`（点光/聚光路径）AOT 构建 + 实跑：`standard fragment 194/400`，无 AGAL 报错。
- **AIR 侧**（AGAL 校验更严的那个底）：`apps/walk-m26` 用 `adl` 实跑 180+ 帧，
  `calls=3 tris=16376` 正常绘制、零错误 —— 这覆盖了阴影 + tone + fog 的 **308** 指令变体；
  `apps/light-m6` 在 `adl` 下也正常。`apps/m26-parity` 的 AIR 构建能通过，但 `adl` 侧会被
  早已登记的间歇 `#1502`（`OrbitControls.update`）挡在首帧，所以它**不能**当作 AGAL 校验证据，
  真正的证据是 walk-m26 那 180 帧。
- 后续（**未做**，按 §34.5 的顺序）：漫反射能量分配（`1 − F_blended` + IBL 守恒项）→
  R1a 的贴图路径 → `backgroundBlurriness` 的 LOD 语义（D156 仍是分档锥）。

## 35. M25-R1 环境粗糙度预滤波 + M27 LightProbe（D174–D179，2026-11-01）

§30 的 HDR 环境把「镜面里能看见 60.0 的柔光箱」做对了，但**粗糙度只影响亮度，不影响叶瓣宽度**：
M9 时代的替代物是「取 `fs7` 在 `R` 的样本，再按 `roughness^4` 混向法线方向的样本」。这在
`roughness = 1` 的球上表现为「反射仍然是镜子，只是被平均掉一部分」—— 一眼能看出不是 roughening。
本轮补上真正的两级分离：**背景模糊**（M25-R2，分档锥）与**环境预滤波**（M25-R1，CPU 粗糙度阶梯）。

同时把 M27 的 `LightProbe` 落地，并把 §30 留下来的第二套 HDR 存储曲线（`fc36`）收成一套（D177）。

### 35.1 预算先行：这个后端只剩 `fs7` 一个环境槽（D175）

动手前先算账，因为「PMREM + 独立 irradiance cube」是 three.js 的默认形态，而这个后端两条都放不下：

| 槽 | 用途 |
|---|---|
| `fs0` | baseColor |
| `fs1` | normalMap |
| `fs2` | roughnessMap |
| `fs3` | metalnessMap |
| `fs4` | shadowMap（阴影变体） |
| `fs5` | emissiveMap |
| `fs6` | aoMap |
| `fs7` | 环境（cube） |

Stage3D 只给片元程序 `fs0..fs7` 八个采样器（见 `as_agal_sampler_flags` 与 `stage3d_glue`：
只有 unit `< 8` 被处理），所以**没有 `fs8`**。第一版确实试过「再绑一档粗糙 cube 到 `fs8`、
系数上传到 `fc10.z`」—— 探针能过、AOT 也能跑，但 AIR 侧那个槽根本不存在，属于
「碰巧能跑」。结论记在 D175：**环境只能占 `fs7`，一个槽，一次采样**。

于是 M25-R1 的形态被预算定死：

- **CPU 侧**产出 `PrefilteredEnvironment`（6 档 `roughness = 0/0.2/0.4/0.6/0.8/1.0` 的 cube）；
- **图元侧**每次 draw 按 `material.roughness` 选一档绑定到 `fs7`；
- **AGAL 侧不新增采样**，反而**少 6 条指令**（`prefiltered = 1` 时不再发 M9 的替代块）。

### 35.2 D174：CPU 阶梯的实现口径

`kit/asaot/three/extras/EnvironmentPrefilter.as`。四个决定，每个都有探针钉：

1. **叶瓣宽度用 Karis 的余弦幂拟合**，不直接对 GGX 积分：GGX 的半角随 `roughness` 增长得比
   余弦幂快，用 `sin(alpha)` 之类的经验式在 `r > 0.95` 会交叉（探针 `A8/A8b` 钉这个交叉点
   在 `r = 0.9526`）。
2. **核是「角度各向同性」的，不是像素各向同性**：同一行里一个经度像素覆盖
   `2π/w` 弧度，越靠极点越小，所以横向 sigma 要除以 `sin(polar)`（下限 1/16，否则极点行
   要扫整张全景）。不这么做，纬度 60° 的柔光箱会糊成横条（探针 `C` 组）。
3. **能量守恒是「按构造」保证的，不是「希望误差小」**：等距柱投影的一行越靠近极点代表的
   立体角越小，所以纵向核必须带 `sin(polar)` 面积元；而且可分卷积在 halving 之后本来就不是
   严格守恒（探针实测最粗一档偏 **13%**）。因此每一档在结束前**显式按球面均值重标定**到
   基础全景的均值，`E2` 用 `1e-12` 相对容差钉住。
   —— 这一条是本轮唯一一次「代码对、口径错」：一开始用**像素均值**当不变量，它在极点稀疏处
   本来就不是物理量，越调越偏。
4. **先减采样再模糊**：`MAX_SIGMA_PX = 3`，`MAX_OCTAVE = 5`，512 宽的全景最粗一档降到 16×8。

### 35.3 D178：阶梯必须分帧烘焙（`PrefilterJob`）

同一份 CPU 循环，AOT 与 AVM2 差一个数量级：

| | 6 档 × 128px 全景（`apps/hdr-m25`） |
|---|---|
| AOT（native） | **84–98 ms** |
| AIR（`adl`） | **2186–2356 ms**（约 26 倍） |

两秒落在一帧里，等于吃掉 AIR 15 秒脚本看门狗的三分之一；装载回调刚好落在阴影重建那一帧时，
就报 `Error #1502`（栈停在 `Object3D.updateMatrixWorld`，看着像渲染器 bug，其实是看门狗）。
所以新增 `kit/asaot/three/extras/PrefilterJob.as`：`step()` 只烘一档（`adl` 下约 240–400 ms），
demo 在 `updateFrame` 里每帧调一次，**第 0 档就是清晰 cube**，环境第一帧就可用，之后逐帧变粗糙。
`partial()` 让渲染器在烘焙中途也能拿到「已完成的档位前缀」，所以中途渲染从来不是非法状态。
同步版 `EnvironmentPrefilter.bake()` 保留给探针与 AOT 一次性烘焙。

### 35.4 D176：LightProbe 在 CPU 上烘成 irradiance cube，不做 SH9 着色

`SphericalHarmonics3` / `LightProbe` / `LightProbeGenerator` 三个类照 r187 的数值与系数顺序实现
（`Y00 = 0.282095`、`Y1 = 0.488603`、l=2 的 `1.092548/0.315392/0.546274`，索引 1→Y、2→Z、3→X）。
但**求值不在片元里做**：忠实 SH9 大约 40 条 AGAL，而 §34 已经把标准片元推到 `308/400`，
采样器也满了（§35.1）。所以：

- `LightProbeGenerator.fromCubeTexture()` 把 cube 辐亮度投到 SH9（立体角权重归一到 `4π`）；
- `toIrradianceCube()` 把**求过和的** irradiance 烘成 16×16 的小 cube，纹素存 `E/π`
  （因为着色器的环境漫反射路径本来就乘 `π`），用 D177 的同一对 sRGB 曲线编码，
  除数写进 `CubeTexture.hdrScale`；
- 渲染器 `_resolveLightProbes(scene)` 每帧收集探针、按 `intensity` 加权求和、**只在
  `probe`/`version` 变化时重烘**，把结果绑到 `fs7`。

**一个槽两个用户**（D176 后半）：探针与 `scene.environment` 抢 `fs7`。规则是「有环境就用环境，
探针被忽略并**只警告一次**」（key `probe-vs-env`），而不是悄悄混两者 —— 后者在 AIR 上根本
表达不出来，在 AOT 上也只是假象。探针路径的强度标量取 `cube.hdrScale`，
**不乘** `envMapIntensity` / `environmentIntensity`：那两个是环境 IBL 的旋钮，不是探针辐照度的。

### 35.5 D177：HDR 存储与渲染器共用一对传递函数

§30 的烘焙用的是 `pow(x, 1/2.2)`，而 D170 之后渲染器的解码是**真 sRGB**。两者各自自洽、
互不匹配，于是 HDR 环境在中间调上系统性偏色（地面 `224/255` 对解析 `Ess 0.5325` 的偏差就是它）。
现在：

- `EquirectangularToCube.srgbOetf()` 编码（纹素 = `srgbOetf(clamp(lin/scale, 0, 1))·255`）；
- 背景 cube/panorama 程序的解码改用 `AGALRenderer.srgbDecodeBlock`（`fc41`）；
- **`fc36`（`DECODE_CONST`）退役**，渲染器只剩一对 `fc41`/`fc42`。

探针 `hdr-smoke-m25` 的 D 组因此改成钉往返：`encode(0.25)` 必须是 **137**（sRGB OETF），
不是 `pow(.25, 1/2.2) = 135`；`texstate-smoke-m17` 的 D14 同步改成钉 `SRGB_CONST == 41`。

### 35.6 AIR 侧：本轮测到的两件事（`hdr-m25` 首次有 AIR 构建）

`apps/hdr-m25` 之前**从来没有** AIR 构建过 —— 一构建就暴露两个真缺陷，都已修：
`import flash.ui.Keyboard` 与 `asaot.three.input.Keyboard` 同名歧义（mxmlc 报「引用不明确」），
以及 `AGALRenderer` 没 import（`adl` 运行时 `Error #1065`）。修完后 AIR 侧确认：

- 预滤波变体在 AIR 上**能装配**：`adl` 下 `standard fragment` 走 `prefiltered=1`，无 AGAL 报错；
- **但 cube 背景在 `adl` 下不绘制**（D179，未定位）：球体、地面、环境反射都正常，唯独
  `_drawSkybox` 那 12 个三角形什么都不出，天顶恒为 `clear(0,0,0,1)` 的黑。已排除的嫌疑（都做了
  单变量 A/B，每次 `adl` 截图对比）：片元内容（改成常量 `mov ft0, v0.xxxxx` 仍黑）、
  顶点变换（改成 NDC 直通仍黑）、背面剔除（`culling none`）、`setDepthTest`/`setBlendFactors`/
  `setCulling` 全部去掉、`op.z = op.w` 改成 `0`、顶点/索引缓冲（AIR 侧打印 `nv=24 ni=36`、
  角点 `-0.5,-0.5,-0.5`、索引 `4,5,6` 全对）、普通 LDR 变体（`decode=false, hdr=false` 也黑）。
  **唯一没排除的是 adl 自己**：同一 session 里 `adl` 还会间歇报 `#1502`（`#34.7` 已登记的
  已知问题，`walk-m26`/`renderstate-m19`/`m26-parity` 都撞过），实测 5 次里 0–2 次能活到截图。
  所以 D179 目前是**未定位的 AIR 遗留**，不进「已验收」：M25-R1 的 AIR 证据只有
  「程序能装配 + 场景能画 + 反射正确」，背景天空盒要等 `adl` 侧能稳定复现再定位。

### 35.7 验收

- `probes/prefilter-smoke-m25r1/`：**39 条 ALL PASS**（A 叶瓣与交叉点、B sigma/octave 计划、
  C 接缝/钳位/角度各向同性、D 档位选择与不变量、E 端到端 spot/disc 峰值与能量、
  F `D177` 存储往返）。E2 是 `1e-12` 相对容差的球面均值守恒；E3 峰值随档单调下降
  （`4 → 4 → 2.61 → 1.13 → 0.35 → 0.13`）。
- `probes/lightprobe-smoke-m27/`：**36 条 ALL PASS**：`A` 基函数顺序与 `getAt` 一致性、
  `B` 常数环境 `c0 = 4π·Y00·L`、`E = πL`、`C` 方向性环境对**暴力余弦积分**（同一纹素网格）
  偏差 +Y 0.7% / +X 2.3%、`D` `intensity` 与 `version` 重烘、`E` 烘出的 `E/π` 与 sRGB 往返、
  `F` 四种拒绝路径。
- `probes/texstate-smoke-m17/` 复跑 **77 条 ALL PASS**（D177 后 `fc36` 已删、`SRGB_CONST == 41`）；
  `probes/hdr-smoke-m25/` 复跑 **69 条 ALL PASS**。
- `apps/hdr-m25`：AOT 构建 + 实跑，`bake 128px in 98ms over 6 frames`，
  `standard fragment 213/400 (prefiltered=0) → 217/400 (prefiltered=1)`；截图逐档验证
  **高光宽度沿粗糙度行单调变宽**（0.05 的镜面球仍是清晰地平线，1.0 的球只剩一坨平滑亮区），
  背景天空与 D177 前一致。`prefiltered=1` 与 `prefiltered=0` 在同一解码状态下相比**少 6 条指令**
  （去掉 M9 替代块），阴影 + 雾的最坏变体因此从 `308` 降到 `302`。

### 35.8 未做（登记，不假装）

- 没有 PMREM、没有多级预滤波 mip，也没有 `backgroundBlurriness` 的真正的 LOD 语义
  （D156 的固定角度锥仍是近似）。
- 阶梯烘焙是**单线程**的（`PrefilterJob` 只解决分帧，不解决并行）。
- 探针与环境的 `fs7` 冲突只有「警告 + 忽略探针」，没有第二套混合方案。
- D179（`adl` 下 cube 背景不画）待定位。

## 36. 能力面实测：`Context3DTextureFormat` / profile / 顶点纹理取值（2026-11-02）

这一节回答的不是「编译器能不能编」，而是「**引擎今天能用到什么**」。做法不靠读编译器文档，
也不靠 AIR 文档推断：写一支无窗口 Stage3D 探针，用 asaot3d 真实的调用方式在 **AOT/Metal**
与 **AIR/adl 51.4.1** 上各跑一遍，逐项读回像素。

探针：`probes/fmt-vtf-m28/`——`probe.as` + `probe.build.json` 是 AOT 侧，`air/` 是 AIR 孪生。
复现（两半都可一条命令跑完；AOT 侧结果进 `temp/`，AIR 侧见下）：

```bash
cd asaot3d/probes/fmt-vtf-m28 && node ../../../as3compiler/src/index.ts probe.as \
  ../../seam/com/adobe/utils/AGALMiniAssembler.as --manifest probe.build.json \
  -o ../../temp/fmt-vtf-m28 --run

AIRSDK_HOME=... ./air/build.sh --run     # mxmlc + adl，并打印探针日志
```

AIR 侧的日志路径是实测选出来的，不是顺手写的：`adl` 在 macOS 上**既不转发 `trace()`
也不转发未捕获异常**，所以探针必须自己落盘；而 `File.applicationDirectory` 对 AIR 应用
是**只读**的（`open(APPEND)` 抛错，被 `catch` 吞掉 → 整支探针静默跑完、退出码 0、什么
也没写），相对路径又会解析到 `adl` 运行时目录，症状相同。唯一实测可写且稳定的位置是
`File.userDirectory`，故日志固定落 `~/asaot-fmt-vtf-air.txt`，`build.sh --run` 负责清理、
读取并在缺失时报错（缺日志＝没跑到 `onCtx`，不是“没有输出”）。

### 36.1 profile：AOT 不跟随请求，AIR 跟随

```
AOT  requestContext3D("auto","enhanced") -> profile = baselineExtended
AIR  requestContext3D("auto","enhanced") -> driver = OpenGL (Enhanced), profile = enhanced
```

后果不是「少一个字符串」，而是**半浮点渲染目标被档位门挡住**：

```
createTexture(4,4,"rgbaHalfFloat")  AOT(baselineExtended) -> #3759
                                    AIR(enhanced)        -> ok
```

带 `ASC_S3D_HALF_TEXTURES=1` 重编后，AOT 认领 `standard`，`rgbaHalfFloat` 渲染目标**真的保住 2.0**：

```
clear(2.0) -> 取样 ×0.25    BGRA8  rt -> 0x404040（钳到 1.0）
                            half   rt -> 0x808080（保住 2.0）
```

⚠️ 这条**没有**改：认领 `enhanced` 需要同时具备 MRT + 浮点纹理 + VTF，缺一即谎报
（AGENTS.md §1.5）。当前构建只到 `standard`，`profile` 就只报 `standard`。**不要**为了让
`rgbaHalfFloat` 可用去改 `profile` 声明 —— 改成先补齐 MRT。

### 36.2 格式对 2D / 渲染目标有效，对 cube 无效

| 格式 | 2D `createTexture` | 渲染目标 | cube |
|---|---|---|---|
| `bgra` | ok | ok（8 位钳制） | ok |
| `bgrPacked565` / `bgraPacked4444` | ok（CPU 解包成 8 位） | ok | **接受但按 8 位内存布局** |
| `rgbaHalfFloat` | `standard` 档 ok，默认档 `#3759` | `standard` 档保 2.0 | **接受，但存的是同样那批 8 位字节** |
| `compressed` / `compressedAlpha` | 4×4 起 | `#3746` | 未测 |

实测关键一条：`rgbaHalfFloat` cube 的取样结果**逐位等于** `bgra` cube（`0xFF0000`）。
所以「用半浮点 cube 装真 HDR 环境」这条路在本运行时是假的 —— 引擎仍走 D154 的
8 位 sRGB 编码 + `hdrScale` 还原。这也是 M25 的 CPU 烘焙取舍在今天仍然成立的真正原因，
而**不是**「后端没有浮点纹理」（这句话在 `standard` 档是错的，本轮已全仓修正）。

### 36.3 cube 的 mip 上传被静默丢弃

`uploadFromBitmapData(bd, side, miplevel=1)` 既不抛也不报，且**不改动 level 0**。
⇒ 「一个 cube + 6 级 mip 代替六个 cube 阶梯」在 asaot3d 走不通，M25-R1 的
`PrefilteredEnvironment`（六个独立 `CubeTexture`）是唯一可行形态。改回 mip 方案前先看这条。

### 36.4 顶点纹理取值（VTF）：AIR 可用，AOT 已打通（Metal）

AGAL 的顶点阶段取值是 `tld` + `vsN`（`TLD` 在 Adobe 汇编器里是 `OP_VERT_ONLY`），不是 `tex`
（`OP_FRAG_ONLY`，汇编期即报 `only allowed in fragment programs`）。

**本轮开工时的实测**（同一支探针）：

```
AIR: tld/vs0  assemble ok -> upload ok -> draw ok -> readback=0xFF00   ← 真取到绿色
AOT: tld/vs0  upload ok   -> draw 抛 Error id=0 msg=null               ← 无任何诊断
```

按 AGENTS.md §1.5 判据（`adl` 能跑对而我们跑不出）这是**遗留缺陷**。该缺陷已由编译器侧
补齐并入库（`as3compiler` `5d92d93` "AGAL4 vertex texture fetch ('tld' in a vertex program)"），
用同一支探针重跑：

```
AOT/Metal: tld/vs0 -> draw ok -> readback=0xFF00                        ← 与 AIR 一致
```

⇒ **AOT/Metal 与 AIR 都能取值**。仍待确认：D3D12 / WebGL 两个后端（本机无法实测，不写成
「已通过」）、顶点侧 sampler flags 是否随 `tld` 的 `<2d,nearest,clamp>` 生效、以及失败时的
错误文案（`msg=null` 是两段翻译共用一个静态 `as_agal_errmsg` 导致：顶点程序翻译失败后被
片元程序的成功翻译清空）。`SkinnedMesh`/`Skeleton` 的 D84/D85 因此已改写为「卡在**存储与
精度**（骨矩阵只有 16F 且仅 `standard` 档），不是卡在取值」。

### 36.5 附带测到：`depthAndStencil` 与 `clear` 掩码

`configureBackBuffer(..., depthAndStencil=true, ...)` 时，若产生该帧的 `clear()` 掩码里没有
STENCIL，`drawToBitmapData()` 抛 `#3692`（本探针用 `mask=3` 时撞上，改 `7` 才好）。
引擎主 pass 用 4 参重载（掩码 ALL），所以不受影响；阴影 prepass 的 `mask=3` 已在
`AGALRenderer` 就地注明依赖关系（那里从不回读）。

### 36.6 对 asaot3d 路线的结论

- **HDR 离屏（bloom / 后处理）**：值得做，但前置是 profile 抬到 `standard`（含 MRT）。
- **PMREM / cube LOD**：与这两项都无关，永远不行（AGAL 无片段 LOD 操作数）——
  M25-R1 阶梯路线是对的，不要回头重构。
- **半浮点 cube**：不做。收益被 8 位输出和 `hdrScale` 完全吃掉。
- **GPU 蒙皮**：VTF 已在 AOT/Metal 与 AIR 打通（§36.4），剩下的前置只剩**精度实验**
  （16F 骨矩阵在绑定姿态位移数十单位时 ~5e-4 相对误差）与采样槽竞争。先量，再决定。

---

## 37. 原生着色器通道：引擎侧 `ShaderMaterial` / `NativeShaderRenderer`（D180–D186、R66–R70，2026-11-02 M30 拍板）

> 编译器侧（`Context3DNative` / `NativeProgram3D` / Metal 胶水 / `--features` 门控）记在
> `as3compiler/docs/zh-cn/{native-shader.md,native-shader-plan.md}`；本节只记**引擎侧**的形状与
> 落地时暴露的缺陷。触发场景是 Ultra-Water（`OceanSim.js` 的 MRT FFT + `textureLod` 位移），
> 但这一轮验收只用一张 2×2 四边形把通路钉死，**不掺海水**。

### 37.1 为什么是「第二通道」而不是「换掉 AGAL」

AGAL 是 AIR 能跑的唯一形态，`MeshStandardMaterial` 那套机器生成 AGAL（PBR/阴影/雾/tone）已经被
M6–M27 对齐到参考值的几个百分点内 —— 换掉它等于把全部验收证据清零。E6 的价值在**AGAL 表达不了
的东西**：浮点渲染目标、MRT、`texelFetch`、整数/位运算、`textureLod`、深度纹理。所以：

- **默认后端不动**，`AGALRenderer` 仍是唯一默认路径；
- 原生通道是**按材质粒度**的逃生舱：`ShaderMaterial` 的 draw 走 native，其余材质照旧走 AGAL；
- 两者**共用一个接缝**（`IRenderer`），不新增方法、不加开关枚举（**D181**）。

### 37.2 四个对象的分工

| 文件 | 职责 | 关键约束 |
|---|---|---|
| `kit/asaot/three/materials/ShaderMaterial.as` | `extends Material`，纯数据：`vertexShader` / `fragmentShader` / `uniforms`（`{name:{value:...}}`）/ `defines`；`setValues()` 拒绝未知键 | **不 import `flash.display3D`** ⇒ `mxmlc` 下同一份源码照编（**D180**） |
| `seam/asaot/three/NativeShaderRenderer.as` | `extends AGALRenderer`，**只覆写** `_drawShaderMaterial(mesh, material)`：建/复用程序、按反射名喂 uniform、绑纹理、绑属性、draw | 一次 `import` 都不写 `Context3DNative`，全部走 `Class` + 方括号（**R67**） |
| `seam/asaot/three/RendererFactory.as` | `getDefinitionByName("asaot.three.NativeShaderRenderer")` 探测 + `create(context)` 回退 `AGALRenderer` | 探测失败**缓存 null 也是答案**，不要每次 `try/catch` |
| `seam/asaot/three/app/Stage3DApp.as` | 创建点从 `new AGALRenderer(_context)` 改成 `RendererFactory.create(_context)` | 字段类型仍是 `AGALRenderer`（工厂返回类型就是它），子类赋值天然兼容 |

`AGALRenderer` 侧的改动只有三处：`_renderMesh` 顶部的 `if (material is ShaderMaterial)` 分派、
`protected function _drawShaderMaterial(...)`（基类**抛错**，**D183**）、`_context` 从 `private` 放宽到
`protected` 与新增 `_camera`（自动 uniform 要用相机位置）。

### 37.3 uniform 绑定：按**反射名字**，不按槽位

SPIRV-Cross 给每个 uniform 独立一个 `[[buffer(N)]]`（M1 实测），所以绑定不需要算 `std140` 偏移，
也不需要自己排槽位 —— 名字够用。规则：

- **五个自动 uniform**：`projectionMatrix` / `modelViewMatrix` / `modelMatrix` / `viewMatrix` /
  `cameraPosition`，与 three.js `ShaderMaterial` 的内建 uniform 同名；
- **别名表**（`ALIASES`）：`position`/`normal`/`uv`/`color` → 引擎几何的 attribute 名；
  名字对不上时**按位置回退**（`BY_LOCATION`），兜住作者抄 three.js 例子的 `in vec3 position`；
- **作者 uniform** 按**形状**分派（`16 = mat4`，`4/3/2/1` 分量走 `setUniform4f/3f/2f/1f`），`Texture` 走
  `bindTexture`；**`mat3` 未支持** —— `Context3DNative` 只开了 `setUniformMatrix4`，没有 `mat3` 入口，
  9 分量落地成一次 warn（不静默丢，也不谎称已经上传）；
- 反射表里**没有**的名字：**warn 一次**而不是抛（**D182**）—— glslang 会把未使用的 uniform 裁掉，
  作者留着一个没被读的 `uTime` 是常态，为此打断渲染是错的方向；拼错名字导致的「着色器不理我的
  光照」由这条 warn 指出来（编译器侧 `setUniform` 对**完全不存在**的名字抛 `#2008`，两处判据不同）。

**D184**：程序按 `material.version` 缓存、纹理按 `Texture.version` 缓存，两者都是「变形才重编」，
不是每帧。**R69**：自动 uniform 的矩阵必须用**独立 scratch**（不复用基类的 `_mvp`）—— 基类在
`_applyMaterialState` 里会用 `_mvp`，共用一个 scratch 会把两边的残留互相污染，症状是「第一个 draw
对、后面的模型矩阵错一帧」。

### 37.4 §8 红线的落地形态：**抛错**，不是近似图

设计文档 §8 只说了「AOT-only，AIR 侧必须如实报明」。引擎侧的选择是（**D183** / **R66**）：

```
_drawShaderMaterial() 基类:  throw new Error("material '" + labelOf(material) + "' needs the native
  shader channel: build with --features native-shader ...");
```

理由：`MeshStandardMaterial` 的 AGAL 路径在 `ShaderMaterial` 上是**语义错误**（作者写的是自己的
光照，AGAL 会套 PBR），画出来的东西「看着像海洋、数值全错」，而 §0 红线说语义错误比缺失功能更致命。
验收证据：`apps/shader-m30` 在**默认构建**与 `adl` 下打印 `NO-CHANNEL`、退出码 0（不刷栈、不黑屏卡死），
同一份 `.as` 在 `--features native-shader` 下 15 项 PASS。

### 37.5 可达性：`extra-roots` 清单字段（**D185**）

`RendererFactory` 用**字符串**引用 `asaot.three.NativeShaderRenderer`，所以 `--air-app` 的闭包
（`src/reach.ts`）看不见它 —— 而它的症状是**静默退化**（探测落空 ⇒ 回到 `AGALRenderer` ⇒ 首帧
抛 `_drawShaderMaterial` 的错，或者更糟：没人用 `ShaderMaterial` 就完全看不出来）。编译器侧因此新增
清单字段 `extra-roots`：

```json
{ "extra-roots": ["asaot.three.NativeShaderRenderer"] }
```

- 只做「把名字塞进闭包根集合」，**不解析路径**（路径由 `--air-app` 的源码根决定）；
- 两种入口：清单字段 `extra-roots`，与 CLI `--extra-roots a.b.C,d.E`（**`--air-app` 每次重写
  `<Main>.build.json`，所以只存在于清单里的字段在构建脚本里无法使用**，→ 才补了 CLI 那一半）；
- 去重；拼错字段名走既有的 `unknown field 'extra-root' (did you mean 'extra-roots'?)`；
- 同名类不存在 = 忽略（不是错误），因为同一个清单要能跨构建复用。

demo 侧不手写清单：`apps/<demo>/features` 与 `apps/<demo>/extra-roots` 两个文本文件（一行一个，`#` 注释）
由 `tools/build-demo.sh` 注入（**D186**），`--air-app` 每次重写的 `<Main>.build.json` 因此不需要进库。

### 37.6 落地时暴露的四个真缺陷（都是「编译过、结果错/空」）

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | 链接期 `_asc_shader_translate` 未定义 | `--features` 只加 `ASC_USE_NATIVE_SHADER=1` 宏，不带 shim / include 路径 / 14 个 `.a` | `build.ts::applyFeatureDeps`：feature 自己声明依赖（`shader_compiler.cc` + `link-order.txt`），不再靠每个 demo 写清单 |
| 2 | native 构建**静默退化成默认构建** | 内建类 `Context3DNative`/`NativeProgram3D` 注册时没给 `reflectFqn`，`getDefinitionByName` 的注册表按它建键 ⇒ 探测落空、工厂回退 `AGALRenderer`，全程零报错 | `symbols.ts` 补 `reflectFqn: 'flash.display3D::Context3DNative'` / `::NativeProgram3D`（**R70**） |
| 3 | Metal 拒绝该 pass：`aPos(0)` 不在顶点描述符里 | `s3d_native_use` **立刻**建管线，而顶点流要到 `drawTriangles` 才绑 | `nativePsoPending`：延到首绘再建（顶点描述符此刻齐备） |
| 4 | draw 编码了，但**什么都没画**，零报错 | `Context3DNative.drawTriangles` 自己发 draw，绕过 `Context3D_submit`（顶点缓冲的上传同步点在那里） | 改走 AGAL 同一个提交点 |

第 2、4 两条是本轮最贵的教训：**空画面与退化都不报错**。判据因此不能是「跑起来了」，而是
「`drawToBitmapData` 读回的像素是对的值」——`apps/shader-m30` 的 15 项断言里前 12 项是通路结构，
后 3 项才是像素，缺了后 3 项这个 demo 就什么都没证明。

### 37.7 规则（R66–R70）

- **R66**：没有 native 通道时 `ShaderMaterial` **必须抛**，禁止回退 AGAL 近似图（理由见 §37.4）。
- **R67**：探测原生类的代码**禁止 `import`**（类型位置在 `mxmlc` 下是 `#1046` 编译失败）；
  一律 `getDefinitionByName` → `Class` → 方括号调用。
- **R68**：只被字符串命名的类**必须**登记 `extra-roots`；漏登的症状是静默退化，不是报错。
- **R69**：自动 uniform 的矩阵 scratch 与基类 `_mvp` 必须分开（§37.3）。
- **R70**：新增**内建** native 类必须在 `symbols.ts` 带 `reflectFqn`（`pkg::Name` 形）；缺它时
  `getDefinitionByName` 永远落空，而症状是「静默退化成默认构建」——既有钉子在 `test/unit/native-shader.ts`。

### 37.8 余项（明确登记）

- ~~**M4 Web 直通**~~ ✅ 2026-11-03：`stage3d_webgl.cc` 把作者 GLSL ES 3.00 原样喂 WebGL2 +
  `EXT_color_buffer_float`，零交叉编译（wasm 侧不编 `shader_compiler.cc`、不链 glslang/SPIRV-Cross，
  反射走链接后 program 上的 `glGetActiveUniform`）。`--features native-shader` 现在同时声明 `native`
  与 `wasm`。三个只在 WebGL2 出现、症状是「编译过、结果错」的坑（槽位必须按 (kind, stage) 编号、
  采样器上限是 16 而不是 AGAL 的 8、正面朝向要 `glFrontFace` 翻转而不是补全 cull 模式）连同
  「渲染目标登记表写死 32 项」一起记在 `as3compiler/docs/zh-cn/native-shader.md` §6.11。
- **M5 D3D12**：`stage3d_d3d.cc` 的浮点 `DXGI_FORMAT` + 原生 HLSL（SPIRV-Cross 那半边库已链好）。
- **M7 Ultra-Water 对齐**：FFT（MRT 写两张浮点图）→ `textureLod` 顶点位移 → caustics → 大气/水下。
  这一轮只证明了通路，**没有证明海洋**。
- `RawShaderMaterial`（不注入任何前导）、UBO（`layout(std140) uniform`）：未做，`ShaderMaterial`
  足够覆盖 three.js 的 `ShaderMaterial` 用法。

---

## 38. M31 能力矩阵 + M32 第一片 FFT 海洋（D187–D191、R71–R73，2026-11-02）

§37 把通路钉死了，但它画的是一张 2×2 四边形、写的是**后台缓冲**。Ultra-Water 要的东西一样都不在里面：
浮点渲染目标、MRT 两个附件、`texelFetch`、整数哈希、深度附件、顶点纹理取值。§38 补这两步：
`apps/shader-m31` 是**能力矩阵**（一次把六项能力各自单独证明），`apps/ocean-m32` 是**第一次真的海水**
（Tessendorf FFT + 顶点位移 + MRT 位移/法线）。

### 38.1 M31：六项能力，逐项单独证明

判定原则与 §37.6 一致——**结构通过不算通过，读回像素对才算**。所以每一项都配一个能把「错」与「对」
分开的可观测差值：

| 能力 | 断言 | 为什么这条差值能分辨 |
|---|---|---|
| 浮点 RT 可渲染 | 32F / 16F 两张目标都写 `100.0`，读回绿通道 `100` | 8 位目标会把 100.0 与 1.0 都变成 1；只有真浮点能存 >1 |
| **fp16 真的丢位** | 写 `1 + 1/4096`：32F 读回蓝 `255`，16F 读回蓝 `0` | fp16 在 1.0 处 ulp = 1/1024，这条差值正好跨过相邻可表示值；若 16F 被悄悄当 32F 用，两者会一样 |
| MRT 两附件 | 附件 0 = 红、附件 1 = 绿，分别读回 | 把两张图绑成一张会读到同一个颜色 |
| `texelFetch` | 读**非中心** texel（偏移 5,5）得 `100` | 归一化 `texture()` 在这里会读到邻近 texel 的平均=0 |
| `uvec2` 位运算哈希（PCG） | 种子 1337/1338 读回 `255`/`177` | 走 `setUniform1f` 传整数会得到位模式（`1337.0` 的尾数），两个种子会产生同一条输出 |
| 深度纹理**作附件** | z=-0.5 红色先画；z=0.9 绿色必须被拒；z=-0.9 蓝色必须通过 | 只测「被拒」无法区分「深度没工作」与「那张图根本没画」——第三条是**正对照** |

顶点 z 直接以字面量注入 GLSL（`@Z@`）而不是走 uniform，是为了让失败**只能**归因于深度附件本身。

### 38.2 M32：`apps/ocean-m32` 的 FFT 链

形状照 `OceanSim.js` 搬，规模砍到能在 AS3 里逐帧跑：

```
wind spectrum h0(k)          ──1 pass──►  h0 (RG32F, 256²)
 evolve h(k,t)=h0·e^{iωt} + conj(h0(-k))·e^{-iωt}   ──1 pass/cascade──► (bit-reversal 折进这一趟)
 FFT 行 → FFT 列（radix-2 DIT，8 级 × 2）            ──16 pass/cascade──►
 assemble（(-1)^{x+y} 修正 + 位移/法线打包）          ──1 pass/cascade, MRT──► disp + normal
 surface（顶点纹理取值位移 + Fresnel/天空/太阳/泡沫）   ──1 pass──►
```

- **级联**：`600 m` 与 `85 m` 两档，`uDisp0/1`、`uNorm0/1` 各一张图，顶点里按世界坐标取两次再叠加。
  细档在自身 patch 外**按距离淡出**（`smoothstep(0.35,0.5,max(|w-0.5|))`）——一开始用 `clamp`，结果细档
  的边界 texel 被整片拉伸，海里出现一块「冻住的方格」，视觉上一眼就能看出。
- **整数 uniform**：`uStage`（FFT 级）、`uVertical`（行/列）、`uSeed` 必须走 `setUniformInts`。这是
  §38.3 缺陷 3 的直接后果。
- **验收**：读回位移图，把 R 通道当有符号高度看极差——`-1.64..1.56 m`（spread 204/255）；平面会读成 0。
  断言只有一条，但它盯的是「整条 FFT 链是否真的在动」，比逐级读回更抗实现漂移。
- **视觉**：14 m/s 风、海况 1.8、相机 (0,14,95) 看向 (0,2,0)，能看出涌浪、浪尖高光与泡沫。天空仍是
  单色 clear colour ——**天空梯度 / 大气 LUT 未做**，与 Ultra-Water 的差距主要在那一块。

### 38.3 这一轮暴露的三个真缺陷

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | 读回**对**，但下一帧崩在 Metal 内部（`MTLResourceListAddResource`、`method cache corrupted`），像「Metal 的 bug」 | `Context3D.drawToBitmapData` 按**后台缓冲**尺寸遍历，索引却写进**目标位图**大小的缓冲：960×600 后台缓冲 → 256×256 位图，写穿 1.1 MB（`as3compiler/src/emit.ts`） | 拷贝按 `min(后台缓冲, 目标位图)` 裁剪，只填重叠的左上区域 |
| 2 | 深度附件「挂上了但不起作用」：几何不分前后，零报错 | 深度**仅**格式（`DEPTH_32F`）时，Metal 管线描述子把 `stencilAttachmentPixelFormat` 留在默认值 → 校验直接拒；更隐蔽的是管线通过、render pass 仍给 stencil 附件赋值时，Metal **整条忽略深度附件** | `stage3d_glue.mm`：非打包格式（非 `Depth32Float_Stencil8`）时 PSO 的 stencil 格式设 `MTLPixelFormatInvalid`，且只在打包格式时才给 `rp.stencilAttachment.texture` 赋值 |
| 3 | 整数 uniform 传 2，shader 里读到 `1073741824` | `setUniform1f` 写的是**位模式**，float 2.0 的位模式当 int 读就是 1073741824 | 反射表补 `components`/`base_type`/`size`；`base_type` 是 int/uint/bool 时走 `setUniformInts` |

第 1 条最值得记：它从**第一个读回探针**起就存在，所有探针都在读回后立刻退出，堆损坏没来得及显形；
直到 34 pass/帧的海洋在同一进程里继续跑，才在**别处**炸出来。教训是「读回探针必须继续跑几帧」——
M31/M32 现在都这么做了。

### 38.4 通道约束（引擎侧必须遵守，对应编译器文档 §6.9）

- **顶点属性给 `layout(location = N)`**：不给时 SPIRV-Cross 生成的 `vs_main_in` 没有 `[[attribute]]`，
  MSL 编译直接失败。
- **别写读 uniform 的 GLSL 辅助函数**：SPIRV-Cross 会把 `constant` 地址空间的引用绑到 `thread` 参数上，
  Metal 拒译。内联，或先抄进局部变量。
- **不要给空渲染目标集提交绘制**：`setRenderTargets([], null)` 会让 Metal 绘制中止；读后台缓冲用
  `setBackBuffer()`。
- **字段别遮蔽 `Stage3DApp._renderer`**：demo 里用 `_nr:NativeShaderRenderer` + `_native = _nr.context3DNative`，
  否则拿 `AGALRenderer` 类型去访问 `context3DNative` 是编译期就错的。
- **读回放在 `afterFrame`**：`drawToBitmapData` 会 flush 当前 command buffer，别再插到一帧中间。

### 38.5 规则（R71–R73）

- **R71**：读回探针**必须**在读回后继续跑若干帧再退出——只读一次就退的探针测不出写越界（§38.3 缺陷 1）。
- **R72**：纹理的**采样语义**由它在 GLSL 里的声明类型决定，不由绑定时的资源决定；深度纹理因此只能作
  **渲染附件**，要读线性深度就渲染进彩色浮点图。
- **R73**：凡是「绑了但没生效」的路径（深度附件、未被读的 uniform、被裁掉的反射项），**必须**有一条
  正对照断言；只测「被拒/为黑」无法区分「功能没工作」与「根本没画」。

## 39. M33 能力补测 + M34 Ultra-Water 全量对齐（D192–D196、R74–R77，2026-11-02）

§38 的 M32 只做到「有位移的网格」。这一节把 Ultra-Water 剩下的部分一次补齐：`apps/shader-m33` 先证明
下游要用的通道能力（导数、加性混合、离屏走一遍相机、`256x1024` 图集），`apps/ocean-m34` 再把整个
管线串起来——4 级 FFT、大气 LUT、caustics、平面反射、不透明深度进 alpha、延迟水面、spray、
水下透镜/光柱、合成调色，一帧 86 个 pass。

### 39.1 画面验收：先解决「看不见」，再谈好看

这一轮最大的时间花在**看不见**而不是算错。三次「画面全黑」都不是渲染错：

1. **`drawToBitmapData` 读不到本帧**。合成 pass 直接画后台缓冲时，帧内读回拿到的是清屏色
   （`(0,0,0,1)`），而同一帧稍后画进后台缓冲的探针却有内容。修法不是改读回，而是**别读后台缓冲**：
   合成写进 `_final` 离屏目标，再由 `present.frag` 一次拷贝到后台缓冲。此后所有读回都落在离屏目标上，
   稳定、可复现，也顺手把「合成之后还要画东西」这条限制去掉了。
2. **合成把 clear tag 当成了水面**。`isWater = w.a > 0.5` 会把 tag 1（无水面 = clear 值）算成水面，
   于是整片天空被水面目标的黑色覆盖。tag 约定是 0 底面 / 1 无水 / 2 顶面，判据必须是
   `abs(w.a - 1.0) > 0.5`。这条 bug 让「天空是黑的」和「天空没画」看起来一模一样。
3. **天空的射线是 NaN**。`inverse(uInvViewProj)` 在原生通道里返回的矩阵让每个像素的射线变成 NaN，
   天空整块写 0。改成宿主上传相机基向量（`uRayFwd`、`uRayRight`、`uRayUp`，由
   `projectionMatrix` 的 `1/p[0]`、`1/p[5]` 给出 tan(fov/2)），顶点阶段只剩加法和缩放：
   没有矩阵求逆，也就没有 NaN。**强制常量色的天空能画、真天空全黑**，就是「片元进了但值坏了」的指纹。

**垂直翻转只在链条的一端存在**。整条 pass 链（opaque → water → spray → lens → shafts → composite →
`_final`）都经同一个全屏四边形写、同一个读，行序天然一致，**链内不翻**；唯一的翻转在
`present.frag`，它是唯一一条从渲染目标纹理跨到 drawable 的边界。此前链内插过一次翻转，
配上「读回是清屏色」的假象，害得两边都判反了。

### 39.2 判据：`240x150` 十六进制帧转储

ASCII 亮度分档分不出「深蓝的天」和「黑」，正好是这一轮要回答的问题。所以 app 里留了一个
`dumpHex()`：把 `_final` 经 `present` 画到后台缓冲 → `drawToBitmapData` → `BitmapData.draw` 缩到
`240x150` → `getPixels` 逐像素打 `RRGGBB` 十六进制行。转储落进日志，外面用 20 行 python 拼回 PNG。
**肉眼看到的第一个真帧**就是靠它：天空 + 云 + 岛 + 起伏海面。这条工具是这一节的验收前提，
不是装饰。

### 39.3 水面要像水：深度与散射

海床原来在 **-7 m**，水面按 Beer–Lambert 只衰减到「能看清海底纹理」，于是整片海像浅礁不像海。
把海床降到 **-26 m**（岛的高度同步 +19 m，峰顶才还在水面之上），并把 `SCATTER` 抬到
`(0.010, 0.062, 0.085)`，水面才由自身散射项主导，读出深海的蓝绿。这类「参数在合理区间但场景
尺度不匹配」的错，只有看画面能发现，读回数值全都正常。

### 39.4 采样器状态按 stage 分开（D192）

水面顶点程序用 `repeat` 采样位移图集，片元程序用默认 clamp 采 `uOpaque`，两者都占 unit 0。
Stage3D 的寄存器文件没有 stage 之分，但 SPIRV-Cross 给原生 GLSL 的采样器**按 stage 编号**，
于是同一个 unit 撞了两种状态。修复分三处：

- `stage3d_glue.mm`：`textures` / `texHasMips` / `samplerFilter` / `samplerWrap` / `samplerMip` /
  `samplerStateSet` 全部改成 `[2][S3D_MAX_TEX]`，`s3d_bind_texture` 仍写两行（AGAL 语义不变），
  新增 `s3d_native_set_sampler_state` 只写反射出来的那一行；绘制按 `S3D_STAGE_VS` / `S3D_STAGE_FS` 取。
- `Context3DNative.setSamplerStateAtStage(stage, unit, wrap, filter, mip)`：新的公开 API。
- `NativeShaderRenderer._applySamplerStates` 遍历 `entry["texList"]`（带 stage），逐个调上面的 API。

顺带把 native 默认过滤器的字面量从 `2`（会被 clamp 成 0）改成 `0`，并注明**后端编码里 0 == linear、
1 == nearest**——字面量 `2` 能跑但读代码的人会以为还有第三种过滤器。

### 39.5 规则（R74–R77）

- **R74**：验收读回**只能**落在离屏渲染目标上。drawable 在 present 之前的可读性是未定义的，
  把「读回是清屏色」当成渲染失败会浪费一轮又一轮的排查。
- **R75**：多 pass 管线里，**垂直翻转只允许存在一处**，且必须在「渲染目标纹理 → drawable」这条边界上。
- **R76**：通道里凡是「值可能是 NaN/Inf 的地方」（矩阵求逆、`0/0`、`log` 负数）都要有**常量对照**：
  强制常量能画、真值全黑，就是 NaN 的指纹。
- **R77**：一个参数「在合理区间」不等于「与场景尺度匹配」。海床深度、散射系数这类量必须以**成片画面**
  验收，读回的 min/max 全绿也可能是一张没有水的海。

### 39.6 M34 自检与门槛（当前状态）

`apps/ocean-m34` 一帧 86 pass，退出前打 7 条自检（全 PASS）：

| 自检 | 判据 |
|---|---|
| 4 级 FFT 有起伏 | 600 m 级位移图双线性采样极差 > 0.6 m（实测 -10.0..10.0，平坦面读 0） |
| 大气 LUT 有辐射 | sky-view LUT 极差 > 0.01（实测 0.078..12.627） |
| 平面反射有镜像场景 | 反射目标 `.b` 极差 > 0.01（实测 0.078..3.922） |
| caustics 非均匀 | 近场 caustics 极差 > 0.05（实测 0.000..2.857，平坦水面 = 1.0） |
| 水面覆盖下半屏 | `_water.a == 2` 的像素 > 20%（实测 48.6%，海床抬高后近场被水面裁掉一部分） |
| 水下光柱有散射 | 光柱目标均值 > 0.0005（gain 8 读回 0.0016） |
| 从下方看是底面 | 相机潜到水下后 `_water.a == 0` 的像素 > 5%（实测 80.2%） |

门槛：`tools/check-all-demos.sh` 27/27 构建通过、27/27 运行通过、0 失败（M34 也在其中）；
编译器全量回归 `node test.ts` **608/608**。

### 39.7 视觉保真轮（D197–D203、R78–R81，2026-11-02）

7/7 数值自检全绿之后，拿参考示例的浏览器截图做像素级对照，结论是**数值全对、画面不像**：
水是「黑底 + 白色裂纹」，参考是「金色路 + 连贯涌浪」。逐项定位如下（全部按
`temp/` 下的 PPM dump 与参考截图的同相对区域均值比较，避免窗口截图的过期帧）。

- **D197 显示端缺 sRGB 编码（根因）**。back buffer 是 `BGRA8Unorm`，不是 `_sRGB` 视图，
  Metal 写入时不编码；`present.frag` 把线性值直接交给显示器，等于把 0.3 线性当 0.3 sRGB 显示，
  中间调被整体压暗（同一个 0.3 应是 0.58）。加上 OETF 后海面亮度直接翻倍，这才是「黑」的主因。
- **D198 天空反射按自身分辨率取 LOD**。参考 `log2(alpha*650)` 是给 1024 cube 的；本管线是
  192x108 的 LUT，照抄会落到最粗一级（≈天空平均辐射），暖色反射被抹成灰。改成 clamp 到 3。
- **D199 `geoVar` 是画面粗糙度总闸**。Kaplanyan 项上界 0.18 在近场就饱和（1 px ≈ 2 个纹理级），
  alpha 被抬到 0.44，镜面高光碎成「不锈钢」。收到 0.06；同时把 2.1 m 级坡度压到 0.55
  （参考靠岸图按深度衰减得到同样效果，本示例没有水深图）。
- **D200 近场水色来自海床透射，不是散射系数**。参考是浅潟湖沙底；把海床放到 -26 m 后
  `exp(-0.42*26)` 把红光全吃掉，水体只剩蓝绿 → 黑板。改成 `-3.2 - 0.018*r`（近处潟湖、
  远处开阔海），沙/岩反照率提亮，吸收系数按潟湖降到 (0.17, 0.055, 0.038)。
- **D201 合成端加白平衡与饱和度**。参考画面处处 R>G>B（水区 R/B≈2.0），本管线物理中性
  （≈1.0）。在 ACES 前乘 (1.10, 1.0, 0.86)、饱和度 1.12；参考的 Post 段做的是同一件事。
- **D202 水面 pass 整体电平 ×1.7**（有据可查的短板：192x108 变形 LUT 对 3.5° 太阳的
  aureole/地平线辉光欠采样；海床是程序化地形而非受光沙地）。逐项修完仍差这一档，按整体抬升，
  并在着色器里写清为什么。
- **D203 采样密度**：极坐标网格 240 环 × 320 扇区（原 170×192，环步 4.8% vs 参考 1.64%，
  中景网格比 12 m 级还粗 → 光照有细节、几何是平的，正是「有闪没有浪」），内部 1152x720
  （原 768x480），相机方位与太阳同轴偏 0.04 rad（原 0.16，太阳偏出画面右 9°）。

### 39.8 本轮新增规则（R78–R81）

- **R78**：**走到 drawable 的那一个 pass 必须自己做线性→sRGB 编码**。离屏链路一律线性光，
  只有跨越到 drawable 的边界才做 OETF，且只做一次；漏掉的症状是「整体发暗、暗部纯黑」，
  很容易被误诊成光照太弱而反复加能量。
- **R79**：**从参考实现搬 LOD 公式时，先看它作用在多大的纹理上**。`log2(alpha*650)` 对 1024
  cube 是模糊，对 192x108 LUT 就是「取全天空平均值」。分辨率每小 4 倍，可用 mip 级少 2 级。
- **R80**：`geoVar`（法线屏幕空间导数）这类**自适应粗糙度**在上界饱和时，会把整个水面变成
  同等粗糙 —— 表现是「高光碎成一片白线」而不是「高光太强」。调参前先读该通道的实际值。
- **R81**：**深水板与潟湖是两种画法**。近场水色由「海床反照率 × 逐波长透过率」决定，
  散射系数只决定没有海床时的兜底色；把海床沉到看不见的深度，画面就一定是一块黑蓝板。

### 39.9 上屏链路与 dump 分叉（D204–D205、R82–R83，2026-11-02）

39.7 的全部结论都是拿 `drawToBitmapData` 的 PPM dump 验证的，而**窗口里显示的从来不是那张图**。
本轮把「上屏」与「dump」当成两个独立产物逐一钉死，两条都以「画面错、着色器对」告终。

- **D204 宿主在 `updateFrame()` 之后又渲染了一遍 `_scene`（上屏错帧的根因）**。
  `Stage3DApp.onEnterFrame` 的顺序是 `updateFrame()` → `_renderer.render(_scene, _camera)` →
  `present()`。前两步对所有「在 `updateFrame` 里画一帧」的 demo 是重复的：M34 的
  `updateFrame` 已经把 FFT→焦散→反射→opaque→water→spray→composite 全画完，宿主这一次
  `render(_scene)` 带 `clear`（clear=1 的全屏 quad）把合成帧整个盖掉，再画一次天空+地形。
  于是窗口里是「金色天 + 黑海床、没有水面」，而 dump（在 `drawComposite()` 内部读回）是成品。
  两侧只在海面区域不同，正是这条的指纹。修复：`Stage3DApp._ownsFrame`（默认 false，零成本），
  M34 在 `createScene()` 里置 true。
- **D205 去掉 `_final` + present 时把唯一一次翻转也丢了**。composite 改为直接写 drawable 后，
  render target（row 0 在顶部）与全屏 quad（`vUV.y` 0 在底部）的行约定第一次正面相遇，
  整幅画面上下颠倒。之所以一直没被发现：`drawToBitmapData` 读的是同一个（同样颠倒的）
  back buffer，dump 和窗口一起颠倒，看起来“一致”。
  修复：翻转移到 composite 自身的采样坐标 `uv = vec2(vUV.x, 1.0 - vUV.y)`，
  对 uColor/uWater/uSpray/uLens/uShafts 一视同仁，仍只有一处。

诊断方法（可复用于任何「上屏≠读回」）：
1. 冻结动画（`FREEZE_AT` + `dt=0`），否则水在动，任何跨时刻对比都不成立。
2. 用**逐 pass 读回**定位窗口内容停在哪个 pass：M34 的 `pass-opaque.ppm` 与窗口逐像素同级，
   `pass-water.ppm` 与 opaque 相同（水是画进离屏 `_water` 的），说明窗口停在 composite 之前。
3. 读纹理别用 `getBytes:` 判 GPU 内容的时序问题 —— 它读的是 CPU 可见副本，
   commit 后没等 GPU 完成时是旧值。用同队列 blit 到 shared buffer + `waitUntilCompleted`，
   那才是合成器会看到的内容。
4. 在 pass 记录点打印 `rp.colorAttachments[0].texture == c->target` 与 `numIndices`，
   直接看「这一帧到底有没有一个画到后缓冲的 6 索引 quad」。

### 39.10 本轮新增规则（R82–R83）

- **R82**：**在 `updateFrame()` 里自绘整帧的 demo 必须置 `_ownsFrame = true`**。宿主的
  `render(_scene, _camera)` 会 clear 后重画 `_scene`，对多 pass demo 就是「静默丢帧」——
  不报错、自检全绿、dump 还是对的，只有上屏错。
- **R83**：**整条链路只允许存在一处翻转**，且它必须挂在「跨越 render target → drawable」的
  那一步上。一旦那一步被换掉（去掉中间纹理、让上游直接写 drawable），必须重新确认翻转还在，
  并**用窗口截图而不是 dump 验证**——两侧同时颠倒时，dump 对比永远看不出问题。

### 39.11 着色器回到移植版 + 每帧 72 次动态派发（D206–D208、R84–R86，2026-11-02）

39.7 那一轮的调色（反射 LOD、环境光乘子、`col *= 1.45`、SSS 项、final mix、glitter 掩码）
是在 D204/D205 两个真缺陷还没修掉的画面上做的补偿。缺陷修完后这些补偿全部失去依据，
按「回到原作者内容」的要求整体撤回：

- **D206 恢复 `water.frag` / `water.vert` 到移植版**。撤回的不只是数值，还包括为此新增的
  uniform（`uSSS`/`uSkyView`/`uTime`/`uDebug`）：移植版用 `uSkyAmbient` 常色给水体打光，
  不追踪 LUT，所以 `water_frag` 的注入列表也一并去掉 `atmo_core`/`atmo_sky`
  （留着会要求两个 stage 的 `precision highp sampler2D` 一致，进而 link 失败）。
  **`composite.frag` 是唯一保留两处非移植改动的文件**，两处都只关于「写到哪里」而非着色模型：
  `uv = vec2(vUV.x, 1.0 - vUV.y)`（D205 的唯一翻转）与末尾的 `toSrgb()`（drawable 不是
  `_sRGB` 视图，Metal 不会替我们做 OETF）。撤掉调色后画面即恢复原作者的金色黄昏海面。
- **D207 CPU 100%、帧 19–27 ms 的根因：热路径用方括号取原生方法**。
  `_native["setSamplerStateAtStage"](...)` 这种「Object 类型接收者 + 字符串名」的调用走
  `as_dyn_call`：每次都要沿方法表按名字线性查找再调用。实测（arm64、`-O2`）
  **单次 25 µs**；把函数值存进字段再调 **< 0.5 µs**，差 50 倍。一次 draw 要 6 次
  （useProgram / bindTexture / 两个 uniform / drawTriangles），于是 256×256 的 FFT pass
  单 pass 200 µs，其中 Metal 编码只占 10 µs；一帧 72 个 pass ⇒ 约 14 ms 纯派发。
  修复：`NativeShaderRenderer` 把 12 个原生入口在构造时冻成字段，M34 把
  `setRenderTargets` / `generateMipmaps` / `setBackBuffer` 同样冻成字段。
  结果：单 pass 220 µs → 60 µs，`sim` 13.9 → 2.1 ms，帧 19–27 → **4.6 ms**，
  33 → **113 fps**，慢帧计数归零。
- **D208 高速运行时窗口截图会撕裂，看到的不是屏幕**。修好性能后同一帧的窗口截图会出现
  「上半张是旧帧、下半张是新帧」的水平接缝，而同一帧的 PPM 完好。这是
  `screencapture -l` 抓到合成器正在写入的 drawable 所致，不是渲染错误：
  冻结帧（`FREEZE_AT=60`）后窗口与 PPM 逐像素一致。**判窗口内容一律先冻结**。

### 39.12 本轮新增规则（R84–R86）

- **R84**：**帧内热路径禁止 `obj["nativeMethod"](...)`**。原生入口必须在构造期解析成
  字段（`private var _fnX:Function`），因为一次动态调用约 25 µs，和 pass 的有效工作量同量级。
  新增原生调用点时，先问「这一帧会走几次」。
- **R85**：**调试着色器的调色不得留成“看起来对”的状态**。凡是用于补偿某个已知缺陷的
  shader 改动，缺陷修复后必须整体撤回，并重新对照移植版；保留项要能在注释里指出它
  对应哪条上屏事实（翻转、编码、精度），否则就是待撤的临时补丁。
- **R86**：**窗口截图只在冻结帧时可信**（承 R83）。运行中的截图即使内容明显错误，
  也不能据此判定上屏链路坏；先用 `FREEZE_AT` 复现，再决定是否查 pass。

### 39.13 应用时钟封顶：把 demo 钉在参照页面的 60 Hz（D209、R87，2026-11-03）

D207 把帧时间从 19–27 ms 压到 4.6 ms 之后，CPU 仍稳定在 83% 左右。这不是 bug，
也不是还有热点：**是宿主把应用时钟同步到了面板的 120 Hz**（M16 的「显示刷新率同步」
设计），于是一帧 4.6 ms 的工作被要求一秒做 120 次，CPU 占用自然翻倍。
参照页面（Chrome/Safari 里的 Ultra-Water）跑的是 vsync 60 Hz —— 同一秒内它与我们
的帧数、每帧成本都不再可比。

- **D209 上限是 demo 的，不是宿主的**。M16 的同步本身没错（浏览器也是按面板率跑），
  错在把「面板率」当成所有 demo 的默认答案。新增 `Stage3DApp.frameRateCap()`
  （保护方法，**默认返回 0 = 不封顶**），由子类声明自己的上限；
  `OceanM34` 返回 60。`onVsyncRefreshRate` 里用纯函数 `capFrameRate(panel, cap)`
  取两者较小值——**上限只能压、不能抬**（60 Hz 面板 + 120 上限仍是 60）。
  `init()` 的握手前默认值也走同一判定（`cap>0 && cap<60` 才写，否则 60），
  这样「后端查不到面板」的路径不会把上限当成帧率写下去。
- **实测（120 Hz 面板、960×600 窗口、`ASC_FRAME_STATS`+`ASC_S3D_STATS`）**：

  | | 不封顶（D207 修复后） | 封顶 60 |
  |---|---|---|
  | CPU | ~83% | **~40%** |
  | 呈现帧率 | 113 fps | **59.9–60.2 fps** |
  | 帧间隔 p50 / p95 / p99 | — | **16.8 / 17.7 / 18.0 ms** |
  | `>17 ms` 的帧（512 帧窗口） | — | 147–204（即被 vsync 钉住的抖动，非慢帧） |
  | Safari 参照（2568×1536、4× MSAA） | — | 58 fps / 17.23 ms |

  CPU 减半而画面完全不变——**这就是「帧率上限」与「性能优化」的区别**：
  优化降低每帧成本，上限降低每帧次数，两者不能互相冒名。
- **一个必须用方法而不是字段的地方**：`frameRateCap()` 是虚拟方法。`init()` 可能在
  **基类构造函数**里执行（stage 已存在时），那时子类的字段初始化器**还没跑**，
  用字段做上限读到的永远是 0。契约写成「返回字面量或类常量」。
- **应用级副作用要写清**：`stage.frameRate` 是**应用级单值**（AIR 语义），
  所以封顶也会压住同一 App 的其它窗口。单窗口 demo 里这是可接受的，
  也正是它必须是「按子类声明」而不是「宿主全局默认」的原因。

### 39.14 本轮新增规则（R87）

- **R87**：**要跟参照页面比性能，先把应用时钟对齐**。面板率（120 Hz）是宿主默认值，
  不是每个 demo 的正确值；与浏览器参照对照时，demo 必须声明 `frameRateCap()`
  到参照页面的 vsync 率，否则测出来的 CPU 差一半是「跑了双倍帧」而不是「实现更慢」。
  判据是**帧间隔分布**（p50/p95/p99）与**每帧成本**两条同时给出；只有帧率数字没有意义。

### 39.15 M34 控制面板：模型在上、uniform 在下（D211–D214、R88–R89，2026-11-03）

参照页面（`temp/ultra-water/src/main.js` 的 lil-gui）有十几个分区。移植到 `asaotui` 时
唯一能守住的不变量是**单向数据流**：

```
widget 写模型                        帧循环独占写下游
OceanPanelView ──► OceanParams ──► applyView()/applyParams() ──► uniforms / bake / camera
```

- **D211 面板只写模型**。`OceanParams` 存的是**作者单位**（度、km、m/s、倍数），不是
  uniform 单位；`OceanM34` 的 `updateFrame()` 是唯一的读者。好处是「重置」等于把模型
  拷回默认值，不需要知道任何 uniform 名字，面板也不需要持有 `NativeShaderRenderer`。
- **D212 两种 bake 各自带脏判定**。太阳/云（elevation、azimuth、intensity、cloudCoverage）
  变化 → `bakeAtmosphere()`（天穹 LUT + 地形/水面太阳 uniform）；海况（风速、风向、fetch、
  waveScale、spreadBlend、swell）变化 → `bakeSpectra()`（JONSWAP 四路级联）。
  判定基准是**上一次应用成功的值**（`markParamsApplied()`），不是「模型 != 默认」，所以拖动
  滑块时只在值真的动的那一帧重烘。其余便宜的量（光学吸收、散射、曝光、choppiness、泡沫）
  每帧直接推 uniform，无脏标志——**贵的才判脏，便宜的别判**。
- **D213 视点是一次性快照**。`view == 0` 是自动巡航；选中命名视点只写一次相机（与 lil-gui
  的 `views` 行为一致：点一次、之后仍可自由操作），每个视点自带 `setSun()`，与参照
  `views` 表逐行对应（Golden hour 3.5°/205°、Breakers 22°、Lagoon 52°、Open ocean 14°、
  Aerial 30°、Underwater 48°）。参照的 `Flotsam` 未移植——那需要漂浮物几何，不是相机。
- **D214 关反射要留一张黑贴图**。水面程序**无条件**采样 `uReflection`，Metal 里未绑定的
  采样器是校验失败而不是「返回黑色」。所以 `reflections == false` 时仍然给 `uReflection`
  绑一张 1×1 黑纹理（只在创建时清一次），跳过的是 `drawReflection()` 的整趟镜像渲染。
- **`asaotui` 的一条坑：`ScrollView` 里的 slider 行必须给显式高度**。滑块轨道画在
  `absH - 12` 附近、标签在顶部，行高 auto 时被压成一行 → 轨道与标签重叠；给
  `size: [inner, 34]`（标签 11px + 轨道 + 间距）才是「标签在上、轨道在下」，而且这个
  显式高度同时成为 `ScrollViewWidget.measure` 的逐子高度，长分区才会「滚动」而不是被压扁。
  同理，面板根用 `alignItems: "flex-end"` 靠右，**不要**用 `justifyContent`：asaotui 的
  `Style.resolve` 会沿祖先链继承未设置的属性，`justifyContent` 会漏进 select 的下拉行。
- **验收**：`probes/panel-params-m35/` **88 项 ALL PASS**（默认值 14 / 0..1 映射 7 /
  31 个控件的按名双向映射 32 / 十二条夹取 12 / 渲染档位 5 / 水色 8 / reset 4 /
  describe 4 / 未知名抛错 2）。**控件表的每一个名字都必须在 `valueOf`/`setValue` 里有分支**：
  本轮加 `vignette` 行时表里有、访问器里没有，探针的「按名往返」当场抛
  `unknown control 'vignette'`——这正是它存在的理由。它能在无 GPU 的情况下钉住模型，但钉不住面板：**面板本身
  只有肉眼验收**（真实鼠标事件打开下拉、拖滑块、勾掉反射、Reset、折叠/展开），这正是
  「自动 PASS ≠ 可用」的那一类。

### 39.16 本轮新增规则（R88–R89）

- **R88**（§39.17 修订）：**控件只有两种合法状态——真生效，或者根本不在面板上**。原先的
  措辞是「着色器没有对应物就别出现」，但那是**当时**的结论：那一轮的真实缺口是「对照着的
  pass 里没有这条链路」，而不是「这件事做不到」。判据因此收紧为两条：①控件要接进**真正
  消费这个值的 pass**——`uUnder` 曾经在 `drawShafts()` 里写死成 `[0.055, 0.9, 42, 0]`，
  于是浊度滑块拖到底画面都不动，这跟假滑块是同一个病，只是假在 app 里而不是面板里；
  ②链路不存在时先看**能不能补出链路**（本轮补出了线性 HDR → bloom → ACES → grade，
  所以 bloom/contrast/saturation/auto-exposure 从「没有」变成「有」），补不出的才落文档。
  退货判据：任何控件在**帧边界**（`applyParams()` 之后）读到的 uniform 值必须随模型变，
  否则删除该控件而不是留着。
- **R89**：**统计归宿主、计数归 demo**。HUD 的建立/刷新/切换由 `Stage3DApp` 提供
  （`showStats()` 关闭），draw/frame 计数由 demo 用 `frameDrawCalls()`/`frameTriangles()`
  记账；`renderer` 自报值只在「整帧只走 `renderer.render()`」的 demo 里可以直接用。

### 39.17 M34 后期链路落地：把「做不了」换成「补链路」（D215–D218、R90–R92，2026-11-03）

§39.16 的 R88 当时把 bloom/contrast/saturation/auto-exposure、浊度、质量档一起判成
「移植版着色器没有对应物」。复核下来这条判据用错了方向：**缺的是链路，不是能力**。
于是本轮补齐四件事，判据也一起改掉（见 R88 修订）。

- **D215 后期拆成两段：`composite` 只到线性 HDR，`grade` 才落 drawable**。
  `composite.frag` 现在把「不透明 + 水面 + spray + 光柱」合成成**线性 HDR** 写进 `_hdr`；
  新 `grade.frag` 读 `_hdr`，顺序是 **曝光 → 加 bloom → ACES → contrast → saturation →
  vignette → sRGB OETF**。为什么必须拆：bloom 与自动曝光都要在 tone map **之前**的线性值上
  算（tone map 之后的暗部被压过、亮部已裁），把它们塞进原来那个「合成即上屏」的 pass 里
  就只能拿到已编码的值。这条拆分的代价是整条链的**行序约定**必须重新对一遍：`composite`
  写 `_hdr` 用 `vUV`、`grade` 读 `_hdr` 也用 `vUV`、`grade` 写 drawable **不翻转**——
  与 HEAD（`composite` 直接上屏且带一次翻转）逐像素比对 mean abs diff **0.01**，是零差异；
  之前把「唯一一次翻转」挪进 `grade` 的版本是 **99.84 / max 240**（整幅上下颠倒）。
  结论写进注释：`target → target` 与 `target → drawable` 在原生通道里行序一致，翻转只在
  「另一条通往 drawable 的路径」上才需要，而这条链已经没有了。
- **D216 自动曝光是 meter → adapt → grade 三级，不是一次除法**。
  `meter.frag` 把 `_hdr` 降采样成 32×32 的 `log2` 亮度网格；`adapt.frag` 用 1×1 浮点
  **乒乓**目标做指数趋近（`k = 1 - exp(-dt/tau)`，首帧 `k = 1` 直接取目标，避免读到未初始化
  的 `prev`）；`grade.frag` 用 `exposure = key / 2^state`，再夹到 `[minExposure, maxExposure]`。
  水下额外乘 `underwaterExposure`（缓动趋近，出水回 1）。**默认不发自动曝光**（`autoExposure
  = false`，`exposure = 0.45` 与 HEAD 一致）：实测本场景下 key 0.18 会把水下段测成近黑、
  key 0.30 又把水下 in-scatter 测到发白——自动曝光对「一半是亮海面、一半是暗水体」的画面
  天然两难，它需要自己一轮针对水下的调校（见本节末「未做」），而**默认画面不允许是实验品**。
  复选框保留，功能是真的（水面上工作正常、逐帧跟随）。
- **D217 质量档是六个档位的 select，不是滑块；且只有屏幕尺寸的目标参与重建**。
  `OceanParams.SCALES = [0.5, 0.75, 1, 1.25, 1.5, 2]`，原生通道**没有 texture dispose**，
  连续滑块会把旧目标一层层漏掉，档位化把漏的量封在「用户点了几次」。架构上必须把目标
  分成两组——`makeFixedTargets()`（FFT 级联、大气 LUT、caustics、lens、meter、adapt、
  反射关闭用的 1×1 黑）与 `makeScreenTargets()`（反射、不透明、水面、spray、光柱、`_hdr`、
  bloom 金字塔）；`applyRenderScale()` 只调后者。**这条是被自检逼出来的**：一开始一把
  `makeTargets()` 全建，`renderScale = 0.5` 那一下直接把 FFT 级联与大气 LUT 清成新的
  空目标，于是 `FAIL four-cascade FFT gives a varying surface` / `FAIL atmosphere LUT bake
  produced radiance` / `FAIL the surface pass covered the lower frame` 三条同时红。
  2× 档实测 `2304x1440 internal (drawable 960x600)`，`grade.frag` 的 `uSuper` 打开后做
  四抽样箱式滤波。注意质量档与 MSAA **是两把不同的旋钮**（见 D220）：档位是超采样，
  每个像素都重新着色；MSAA 只均摊子像素覆盖，解决边缘而不动内部。两者可叠加。
- **D220 离屏 MSAA 是逐目标 companion，不是全局开关**。`Context3DNative.setRenderTargetSamples
  (tex, n)` 给被点名的目标挂一张同尺寸 multisample companion，绘制写 companion，**读取时惰性
  resolve** 回目标本体（`s3d_msaa_resolve_texture` 在采样绑定 / 原生纹理绑定 /
  `s3d_get_render_target` / `s3d_generate_mips` / 帧 flush 五处入口都先 resolve）。三条硬约束：
  ① Metal 要求**同一次 pass 的所有附件采样数一致**，所以颜色与深度要一起挂，否则
  `s3d_pass_samples()` 发现不齐就退回 1 采样（不报错、不退性能）；② 只给**几何光栅化进去的**
  目标挂（不透明/水面/spray/反射 + 两张深度），FFT 图集、测光网格、1×1 曝光状态、bloom 金字塔
  全屏 quad 覆盖，多采样是 bit-identical 的浪费；③ `ASC_S3D_MSAA` 只管 drawable（D55），
  两者不相干。风验：冻结时间、Golden hour 视图，off vs 4x 差 **1.58%** 像素
  （9118/576000，均值 0.185），其中 **92.5%** 落在强边缘；Breakers 视图 1.12%，硬台阶
  像素 10861 → 10668。若差异落在大块平面上，说明不是 MSAA 而是别的状态被动了。
  实现代价：`S3DRttMsaa` 槽表 32 项、`s3d_destroy_texture` 一并回收 companion；AST 侧
  `Context3DNative.setRenderTargetSamples` 返回 Boolean（false = 设备拒绕，应用自己 logLine）。
- **D218 浊度属于光柱 march，不属于合成**。`uUnder` 原本在 `drawShafts()` 里写死成
  `[0.055, 0.9, 42.0, 0]`，所以「浊度」这个模型字段在画面上是死的；改成
  `[_params.scattering, _params.shafts, _params.shaftRange, 0]` 之后，浊度 0.055 → 0.35
  让水下自检均值从 **0.0407 掉到 0.0044**（光柱被吃掉），肉眼也确实是「更浑、god ray 更弱」。
  另外 **preset 会盖掉字段默认值**：`OceanPanelView` 构造时 `setPreset(preset)`，所以
  `PRESETS[0]` 的浊度才是首帧的真实值——字段默认必须与 `PRESETS[0]` 对齐（否则「头less
  直接用模型」与「面板打开后」两个默认值不一样，探针会抓出来）。

**本轮明确未做**（写在这里而不是留空想）：

- **水下段的自动曝光调校**。`autoExposure` 的算术是正确的（水面上逐帧跟随、突变不过冲），
  但本场景「上半天光 + 下半水体」的直方图让单键值测光两头不讨好：key 0.18 → 水下近黑，
  key 0.30 → 水下 in-scatter 发白。参照页面靠 AgX 的 toe/shoulder 消化这段动态范围，我们要么
  换 tone map，要么给水下单独一条测光通道（按 `underwater` 切换 key/tau）。**两个方案都要重做
  一遍与参照的对照**，不是本轮的收尾项。
- **岸线波浪**（参照 `water/shoreMap.js`：岸距 SDF、行进时间图、浅水增陡 shoaling、岸边泡沫）。
  这是本轮唯一还缺的功能段，需要一张烘焙的岸距图和一个新的水面分支，规模与 D215 同级。

### 39.18 本轮新增规则（R90–R93）

- **R90**：**后期先问「这个值编码过没有」**。exposure/bloom/tone map 必须在**线性 HDR**
  上做，写进 drawable 的那一步才做 OETF；把 exposure 放在 sRGB 编码之后等于白调（暗部已经
  被 `pow(x, 1/2.2)` 抬起来，乘完再裁）。所以任何新增后期都先回答：它消费的是 `_hdr` 还是
  drawable？答不出来就别加。
- **R91**：**没被写过的 render target 不能采样，`* 0.0` 不是保险**。新建的半浮点目标内容是
  NaN/garbage，`NaN * 0.0` 仍是 NaN，一个「强度为 0 时乘 0」的写法会把整幅画面毒成黑。
  本轮的判据来自三段调试带：`hdr` 非黑、`aces(hdr)` 非黑、`(hdr + bloom*0)` 全黑 ⇒ 问题在
  bloom 那个空目标。修法是**守卫采样**（`uBloomStrength > 0.0 ? texture(...).rgb : vec3(0)`），
  而不是 `Context3D.clear()`——后者是延迟命令，能不能在第一个消费 pass 之前生效要看队列，
  守卫则与队列无关。
- **R92**：**尺寸可变的后期目标必须与烘焙目标分开建**。任何「按屏幕尺寸分配」的目标集合都要
  能被单独重建，且重建入口只碰这一组；把 FFT 级联/LUT 混在一起重建，等于每次改分辨率都把
  累积状态清空（本轮实测三条自检立刻红）。同理，凡是**由分辨率推导**的量（相机 aspect、
  texel size、超采样开关）都要从 `_rw/_rh` 读，不能从 `stage.stageWidth` 读。
- **R93**：**挂 MSAA 要连深度一起挂，且重建目标集后必须重挂**。`s3d_pass_samples()` 只在
  **本次 pass 的所有附件采样数完全相同**时才用多采样，少挂一个深度附件就静默退回 1 采样——
  画面看着「差不多对」，只有边缘锯齿在。目标重建（渲染缩放）会把 companion 一并丢掉，所以
  应用要在重建后重新 push 一次采样数；`OceanM34` 用一个 `_appliedMsaa` 哨兵（重建时置 0）
  把「已经推过」与「这个目标还没推过」区分开。判据：改档位前后截图差应集中在 1~2 px 宽的
  边缘带上；若差在整块面上，说明 PSO 采样数与本帧附件不匹配。

### 39.19 相机交给指针（D221、R94–R95）

- **D221 相机控制照搬参照，不发明「自由相机」模式**。参照页的相机就是 `OrbitControls`
  （main.js:44-46：damping 开、`maxDistance 6000`，**没有** minDistance、没有极角/方位限制——
  正是这两条「没设」让相机能下潜到水下再绕回来）。它的视点菜单只写 `camera.position` +
  `controls.target`，**没有「manual / free」这一档**；点完菜单再拖，菜单仍指着上一个视点。
  移植版因此也不加这一项：菜单记的是「上次选的视点」，而「谁写相机」是**每帧的事**，
  不是 UI 状态，也就不该有 UI。面板不新增旋钮，`OceanParams` 也不新增字段（`viewReq` 不是
  模式，是请求计数，见下）。
- **巡航保留，拖一下就位**。26 s 自动环是本 demo 的自检依赖（要在水面上下穿越时取帧），不能删。
  `OceanM34.detectCameraTakeover()` 把「这一帧的相机位姿与上一帧巡航写的不同」当作接管信号：
  巡航期间没有第二个人写相机（太阳滑块改的是**下一帧**巡航要写的值，不是当前位置），所以位姿
  一变只可能是指针干的。好处是不必再挂一套事件监听，且「按下但没动」不会被误判成接管——
  这与 three.js 同口径（没动就没有变化），松开按钮巡航照旧。
- **唯一回到巡航的手势是「重选当前视点」**。`OceanParams.viewReq` 是请求计数器，`applyView()`
  以 `(view, viewReq)` 为幂等键。只认 `view` 的话，相机被拖走后再选「auto loop (26 s)」什么
  都不会发生——而这恰恰是用户唯一会做的复位手势。`reset()` 因此让它**递增**而不是照抄默认值
  （no-op 的那个场景恰恰是最常见的：相机被拖走时 `view` 已经是 0、计数器也已经是初值）。
- **R94**：**指针归谁，由「面的拥有者」回答，不由命中测试回答**。three.js 里 GUI 是 canvas 的
  兄弟 DOM 元素，指针天然分流；AIR 只有一条显示列表，面板上的按下会冒泡到 `stage` 上的同一个
  监听器，于是「拖滑块顺手把相机也转了」。`asaot.three.controls.OrbitControls` 因此长了一个
  `pointerFilter(x, y)` 钩子，在**手势起点**（鼠标按下 / 滚轮）问应用「这个点归不归你」，由
  `OceanPanelView.blocksPointer()` 按**布局矩形**回答（展开＝最右 `PANEL_W` 像素；折叠＝右上
  按钮那一块）。为什么不按命中测试：展开的下拉会被 `SelectWidget.liftForPopup` 抬到 stage
  容器上，早已不是面板的后代；折叠时干脆没有面板盒子，只剩一个按钮。过滤器只在按下那一刻被
  问，所以**拖到一半离开面板仍然继续控相机**，与浏览器的 pointer capture 同口径。
- **R95**：**每帧只许一个人写相机**，且互斥点必须是帧内单点。巡航、视点快照、`OrbitControls`
  三者互斥，写成 `if (isFreeCamera()) updateOrbit(); else updateCamera();`——不能靠各自「看
  情况跳过」，两处都写就会看到「拖完往回弹一帧」。视点接管时还要 `_haveCruisePose = false`
  并清掉控制器的阻尼余量（`clearOrbitDamping()`：关 damping 跑一次 `update()`，它就不累积
  也不应用），否则上一手的滑动量会叠到新机位上。指针接管后仍要过参照的 `clampCamera`：
  `y >= seabedH(x, z) + 0.8`，可以下潜，但不能穿地。

