# asaot3d — as-aot 的现代 3D 引擎

> 替代 Away3D：Away3D 已多年未更新、作者放弃，API 停留在 AGAL 时代。
> asaot3d 以「借 three.js 设计、用 AS3 重写」的方式，给 as-aot 配一套现代 3D 场景图库。

## 已锁定的三项决策（2026-10-30）

1. **定位**：替代 Away3D，首个里程碑对齐 three.js 核心 API 面
   （`Scene` / `Mesh` / `Geometry` / `Material` / `Light` / `Camera` / `Loader`）。
2. **借鉴纪律**：只借设计与语义、不借实现——three.js 是 JS + WebGL2，我们是
   AS3 → C/native/wasm，落地形态必然不同。每一条「借了什么」必须落到 `three-src/`
   的**具体文件 + 行号**，形态不同的行写清「为什么不照搬」（见 `three-borrow-map.md`，
   规则同 asaotui 的 `gpui-borrow-map.md`）。
3. **渲染后端**：AGAL-first——材质编译成 AGAL，走 as-aot 现有的
   AGAL→MSL/GLSL 翻译器（`ASC_AGAL_TARGET`），源码在 adl/真 AIR 上也能跑（对齐 AIR 底线）。
   原生着色器直通（E6，增强项）**已落地为 opt-in 第二通道**（M30，2026-11-02）：
   `--features native-shader` 才注册 `Context3DNative`/`NativeProgram3D`，作者写 GLSL ES 3.00 的一对
   vertex/fragment 经 glslang → SPIR-V → SPIRV-Cross 落到 MSL；**默认构建一个字节都不变**，没开开关时
   `RendererFactory` 探测不到、`ShaderMaterial` 在有 native 通道前**抛错而不是画近似图**（设计见
   `../as3compiler/docs/zh-cn/native-shader.md`，引擎侧决策见 `three-api-design.md` §37）。

## 许可

three.js 是 **MIT**，借鉴/移植只需保留版权声明。

## 目录结构

| 目录 | 职责 | 命名空间 |
|---|---|---|
| `kit/asaot/three/` | 纯 AS3 引擎（场景图 / 数学 / 几何 / 材质 / 相机 / 灯光 / 加载器） | `asaot.three.*` |
| `seam/asaot/three/` | 渲染接缝（`AGALRenderer` 默认 + `NativeShaderRenderer` 原生通道 + `RendererFactory` 探测）+ 应用宿主 `app/Stage3DApp.as`（刷新率同步 + 每 demo 帧率上限 / resize / 帧循环） | `asaot.three.*` |
| `seam/com/adobe/utils/` | Adobe 官方 `AGALMiniAssembler`（BSD）**全仓唯一副本** | `com.adobe.utils.*` |
| `three-src/` | three.js 浅克隆（r187，commit `a1ca74b`），供 borrow-map 指出处 | — |
| `tools/build-demo.sh` | 双后端构建实现（AOT / AIR），被 `apps/<demo>/build.sh` 转发调用 | — |

> `three-src/` **不入库**（免内嵌嵌套 `.git`，见 `.gitignore`），克隆本仓库后需要自己重建；
> borrow-map 的所有行号以这棵稀疏树为准：
>
> ```bash
> git clone --filter=blob:none --no-checkout \
>   https://github.com/mrdoob/three.js.git three-src
> git -C three-src sparse-checkout set src
> git -C three-src checkout a1ca74b
> ```
>
> 重建后 `three-src/src/` 应有 757 个 `.js`；重建不了也不影响构建与测试（它只是出处索引），
> 只有核对 borrow-map 行号时才需要。
>
> 命名沿用 asaotui 的约定：顶层命名空间 `asaot`，`ui` 与 `three` 是两个并列库。
>
> `seam/` 与 `kit/` 是**共享源码根**，不再往每个 `apps/<demo>/src/` 里复制库文件：每个 demo 的
> 构建命令固定带 `--as-class-path seam --as-class-path kit`（`--air-app` 把两个根当作额外源码根
> 全量扫描，包名仍取自文件里写的 `package`，与目录位置无关）。
>
> ```bash
> node ../as3compiler/src/index.ts --air-app apps/<demo>/<Main>-app.xml \
>   --main-class <Main> --as-class-path seam --as-class-path kit
> ```

## 进度（M32 · 第一片 FFT 海洋 ✅；M31 · 原生通道能力矩阵 ✅；M30 · 原生着色器通道 E6 ✅）

| 里程碑 | 状态 |
|---|---|
| 数学库（`kit/asaot/three/math/`，9 文件） | ✅ 落地，冒烟 `probes/math-smoke/MathSmoke.as` 29/29 PASS |
| `Object3D` 场景图 + `Scene`/`Group`/`Mesh`/`Camera`/`PerspectiveCamera` | ✅ 落地，冒烟 `probes/scenegraph-smoke/SceneGraphSmoke.as` 18/18 PASS |
| `BufferGeometry`/`BufferAttribute` + 内建三几何（Box/Sphere/Plane） | ✅ 落地，冒烟 `probes/geometry-smoke/GeometrySmoke.as` 29/29 PASS |
| 材质 + 灯光（`Material`/`MeshBasicMaterial`/`Light`/`AmbientLight`/`DirectionalLight`） | ✅ 落地，冒烟 `probes/material-light-smoke/MaterialLightSmoke.as` 22/22 PASS |
| `AGALRenderer` 最简通路（旋转立方体上屏） | ✅ 落地，demo `apps/rotating-cube/`（`--air-app` 编译链接 + 运行截图确认旋转立方体上屏） |
| `MeshStandardMaterial`（PBR 参数面）+ `Texture` | ✅ 落地，冒烟 `probes/material-smoke-m2/MaterialSmokeM2.as` 33/33 PASS |
| `AGALRenderer` GGX 微表面光照 + `map` 纹理采样（PBR 立方体上屏） | ✅ 落地，demo `apps/pbr-cube/`（左蓝 GGX 立方体光照渐变 + 右棋盘格 map 立方体，上屏截图确认；含绕序适配 R5） |
| `Loader` 抽象基类 + `ObjectLoader`（JSON 场景图反序列化） | ✅ 落地，冒烟 `probes/loader-smoke/ObjectLoaderSmoke.as` 61/61 PASS（object literal 49 项 + `JSON.parse` 通路 12 项） |
| JSON 场景加载并渲染（M3 验收） | ✅ 落地，demo `apps/loader-scene/`（内嵌 three.js format 4 JSON → `JSON.parse` → `ObjectLoader.parse` 重建蓝色 GGX 立方体 + 方向光/环境光 → 上屏截图确认；含 D23–D30、R7） |
| PBR 贴图族 `normalMap`/`roughnessMap`/`metalnessMap` 采样 + `computeTangents`（M4） | ✅ 落地，demo `apps/texture-maps/`（程序化法线鼓包/粗糙度条纹/金属圆盘三立方体，上屏截图确认；含 R8、D31） |
| 外部资产通路 `FileLoader`/`ImageLoader`/`TextureLoader` + `ObjectLoader.parseGeometry` + `computeVertexNormals` + R9 缺属性默认缓冲（M5） | ✅ 引擎侧 + 冒烟 `probes/loader-smoke-m5/` 8 节全绿（真 suzanne 505 顶点 + 像素断言 + uuid 守卫）；demo `apps/asset-load/` 磁盘加载 suzanne JSON + PNG 贴图，上屏验收 ✅（黑背景 + 蓝灰 suzanne + 棋盘格立方体，根因修复：demo 补显式 `_context.present()`） |
| 灯光族扩展 `PointLight`（distance/decay）+ `SpotLight` + 渲染器多光逐光 additive pass（M6） | ✅ 落地，冒烟 `probes/light-smoke-m6/` 24/24 PASS + `probes/agal-m6-probe/` 点/聚光片元 < 200 指令；demo `apps/light-m6/` 方向光 + 红色点光 + 白色聚光三光源 additive 上屏验收 ✅（右半球白 / 左半球红 / 球顶高光 / 地面椭圆光斑；根因修复：additive pass diffuse 段误累加未除 PI 的 diffCont，改 `mov` 覆盖） |
| 方向光阴影 `DirectionalLightShadow` + 深度 prepass render-to-texture + 主 pass 采样比较（M7） | ✅ 落地，冒烟 `probes/shadow-smoke-m7/` 19/19 PASS；demo `apps/shadow-m7/` 悬空立方体投阴影到地面，上屏验收 ✅（阴影方向/位置对齐光向；根因修复：投影矩阵深度列 [-1,1]→[0,1]（Metal NDC z）+ bias 矩阵 y 列取负（Metal framebuffer 原点），见 borrow-map D-depth/R11-R13） |
| glTF 2.0 资产通路 `GLTFLoader`（GLB/glTF、buffer/accessor、primitive、PBR 材质含 emissive/AO 贴图、纹理、节点、相机、KHR 灯光）（M8） | ✅ 落地，冒烟 `probes/gltf-smoke-m8/` 46 项全 PASS（Duck.glb 2399 顶点/12636 索引 + 坐标 min/max 对上 accessor + DamagedHelmet 14556 顶点 + 外部 .bin/JPEG 解码 + data URI 小端 float + emissive/occlusion 贴图落到材质）；demo `apps/gltf-m8/` 鸭子 + 头盔同屏上屏验收 ✅（**根因**：标准程序原本只采 4 张图，`emissiveFactor=(1,1,1)` 只乘中性白纹理会把整个网格刷成白团；补 fs5/fs6 采样槽后按 three.js 语义 `emissive = factor × texel`，A/B 截图证实关掉 emissiveMap 即刻复现白团、AO 只让环境项变暗约 2%） |
| 环境贴图 IBL `CubeTexture` + `CubeTextureLoader` + `Scene.environment`/`material.envMap` + 渲染器 fs7 cube 采样（M9） | ✅ 落地，冒烟 `probes/env-smoke-m9/` 38 项全 PASS（六面 JPEG 解码/乱序填面/单次 `onLoad`/`version` 触发、材质与 Scene 默认值、`material.envMap \|\| scene.environment` 解析、EnvBRDFApprox 两点锚定 + `exp`↔`exp2` 常量换算、`tex <cube>` 汇编通过）；demo `apps/env-m9/` 五个金属球粗糙度扫描（0.05→1.0）**仅由环境贴图照明**，上屏验收 ✅（**A/B 判定**：注掉 `scene.environment` 后整排纯黑，证明画面完全来自 IBL；**取舍**：cube 无 float/mip 存储、AGAL 片段无 LOD 操作数，故无 PMREM 预卷积，粗糙度用 `mix(R,N,r²)` + 向 irradiance 混合近似，DFG 用 Karis 解析式替代 BRDF_LUT 贴图；标准片元 **166/200** 指令，余 34） |
| 渲染质量族：`toneMapping`（No/Linear/ACESFilmic）+ `toneMappingExposure`；`transparent`/`opacity`/`alphaTest`/`depthWrite` 真生效（透明 pass 远到近排序 + `sourceAlpha`/`oneMinusSourceAlpha` + 不写深度；`alphaTest` 走 `kil`）；4x MSAA（`ASC_S3D_MSAA=4` opt-in）（M10） | ✅ 落地，冒烟 `probes/alpha-smoke-m10/` 32 项全 PASS（材质默认值、排序键定义、glTF `alphaMode` MASK/BLEND/OPAQUE → 三个材质旗标、`ACESFilmicToneMap` 片段汇编 + 27 指令计数、ACES 六个数值锚点 0.18→0.213105 / 1.0→0.763397 / 4.0→0.952237 / 曝光 2.0→0.887514）；demo `apps/alpha-m10/` 镂空 alphaTest 面板 + 三层重叠玻璃 + 过曝球，上屏验收 ✅（**三组 A/B**：`TONE_MODE` 2↔0 → 高光由平坦死白变为带渐变的滚降；透明排序方向反置 → 重叠区主色调从红变蓝；`alphaTest` 0.5↔0 → 镂空面板退化为整块不透明白板）。指令预算按 AGAL1 基线上调至 **400**，实测 ACES 开启时标准片元 **188/400**（含阴影）/ **180/400** |
| 几何族 + 曲线 + 线框 + 视锥剔除（M11） | ✅ 落地，冒烟 `probes/geometry-smoke-m11/` **103 项 ALL PASS**（独立重算 r187 拓扑的顶点/索引/group 数、包围盒证明躺在正确平面、法线单位长与朝外、UV 角点、EdgesGeometry 盒 12 边/单面 4 边、mergeGeometries 拼接与不兼容拒绝、六平面提取与「绝不假阴性」、线段顶点程序 30 指令含 `dp4` 不含 `m44`）；demo `apps/geometry-m11/` 七个几何画廊 + 8 基座 + 线框盒 + 40 个屏外盒，上屏验收 ✅（`drawCalls=17 / triangles=5428 / culled=40` 稳定，`culled` 与画面像素的 A/B 分别对应剔除与线框两条新通路）。**根因修复三处**：①剔除平面必须从 **view-projection**（`projectionMatrix × matrixWorldInverse`）抽，喂投影矩阵得到的是相机空间平面却去测世界空间球 ⇒ 整排误剔除；②线段顶点程序在 **NDC** 算偏移却写进 **clip** 空间的 `op`，整段被缩小 w 倍缩成屏幕中心一团（补 `mul vt6.xy, vt1.xy, vt6.wwww`）；③方向光阴影采样缺「片元是否在阴影盒内」守卫，盒外采到 clamp 边界 texel ⇒ 宽场景平白变黑（`max(shadow, 1-inFrustum)`）；④回归截图暴露 M7 demo 的 `shadow.bias` **符号写反**（正 bias 是制造 acne 而非治疗，且 8-bit 深度下需要 ≥ 一个台阶 ≈0.116 世界单位，改 `-0.004` 后地面干净、接触阴影仍贴地）。分歧 D56–D65、R19–R21 见 `three-api-design.md` §16 |
| 动画族 + CPU 蒙皮/形变（M12） | ✅ 落地，冒烟 `probes/animation-smoke-m12/` **110 项 ALL PASS**（五种插值器的段内值与边界、退化区间取段末、`PropertyBinding` 白名单消歧与四级 `findNode`、`PropertyMixer` 的 lerp/slerp 累加与总权重 <1 回混、`LoopOnce/Repeat/PingPong` 与 `fadeIn/fadeOut`、双缓冲 `_accuIndex` 交替与 `stop()` 恢复原姿势、glTF CUBICSPLINE 三元组 stride 与 Hermite 数值锚点、单骨/双骨蒙皮与权重归一、morph 相对/绝对两模式）；demo `apps/animation-m12/` 6 骨节鞭 + 形变球 + 旋转方块同屏，上屏验收 ✅（**逐帧观测对照**：`carouselY` 0.95↔0.45、鞭尖 (0.187,3,0)↔(1.4017,2.3192,0)、`skinChecksum` 865.991↔1061.9015、形变半径 0.72↔1.36，`bindChecksum` 恒 865.991 证明形变幂等无漂移）。**形态取舍**：GPU morph/skinning 需要 AGAL 的相对常量寻址（`vc[a0.x]`）或 float 纹理调色板，本后端两者皆无 ⇒ **同一套算术在 CPU 上跑**并写回 `position`/`normal`（`D84`），顺序与 shader chunk 一致（morph 先、skinning 后）；渲染器新增 `updateDeform(frameId)` 调用点（R22，`_frameId` 去重使阴影 prepass 与主 pass 只算一次，且 prepass 拿到的是已摆姿势的顶点）。**不新增任何 AGAL 程序**，标准片元仍 182/400（含阴影）/163/400。分歧 D66–D87、R22 见 `three-api-design.md` §17 |
| 阴影质量：PCF + `normalBias` + 镂空 caster + 16 位深度打包（M13） | ✅ 落地，冒烟 `probes/shadow-smoke-m13/` **47 项 ALL PASS**（`LightShadow` 的 `radius`/`normalBias` 默认值与可写性、`MAX_DIR_LIGHTS`/`MAX_SHADOW_LIGHTS`/`PCF_TAPS`/`PCF_OFFSET_BASE` 四个常量、`castsShadow(...)` 规则、9 tap 网格几何与「每次返回独立副本」、snippet 结构（一 tap 一 `tex`、全 `fs4`、全 `nearest`、无 `linear`、每 tap 一个 `dp3` 解包、`receiveShadow` 混合存在）、snippet 行数 76 与真汇编后 84 条指令、`pcfKernel` 六个边界、`shadowDepthKind` 五种选路）；demo `apps/shadow-m13/` 地面 + 旋转环面 + 悬空镂空薄板 + 暖色 key（`radius=2`/`normalBias=0.02`/`bias=-0.002`）与冷色 fill。**A/B 判定**（`ANIMATE=false` 冻结同一姿势，参照系是 `castShadow=false` 的同场景）：阴影半影占比 `radius` 0→2 由 **0.0% → 19.3%**（1944 个部分遮挡像素）；环面错误自阴影 `normalBias=0` 时 **34.5%**、只补 `normalBias` 时 14.1%、`normalBias=0.02` + `bias=-0.002` 时 **2.6%**；镂空薄板投影 4 窗透光。**根因修复四处**：①阴影深度从裸 8 位 R 通道改为**两字节打包**（`hi/lo` + `dp3` 解包），台阶由 0.155 世界单位降到 0.0006——16-bit 之前无论怎么调 `normalBias` 都是换一圈圈长痘的地方；②`castShadow`/`receiveShadow` 从摆设变真生效（caster 过滤 + `vc22`→`v5` varying 混合）；③`BitmapData(w,h,false,…)` 会把 alpha 强制 255 ⇒ 镂空面板投实心影子，必须 `transparent=true`；④顶点临时寄存器**偏写后全读**会被翻译器硬拒绝（`AGAL: vt2 is read before it is written`），改整寄存器 + 广播标量。指令预算 **300/400**（两方向光 + 一张阴影图，余 100）。分歧 D88–D93、R23–R24 见 `three-api-design.md` §18 |
| 交互：射线拾取 + 轨道相机（M14） | ✅ 落地，冒烟 `probes/interaction-smoke-m14/` **110 项 ALL PASS**（A 射线 22：`at/recast`、垂直距/原点距、三角命中与背面剔除、**共享边 watertight 双命中**、`applyMatrix4`、球的进入/出射/空球/背后/擦过、平面距离与平行 NaN、盒进入点；B 指针桥 15：NDC 四角与中心、零尺寸视口不产 NaN、透视原点=相机位、正交原点落在相机平面且随 NDC 平移；C 拾取 37：`FrontSide` 单命中 / `DoubleSide` 前后各一且升序 / `BackSide` 只中远面 / 中心射线双命中 / 漏射零命中 / `near`·`far` 裁剪 / 平移缩放后的**世界**点与距离 / `recursive` 有无 / 等距双网格顺序稳定 / `drawRange` 三种取值 / 非索引几何不造假 uv·normal / 旋转地面正反面；D 轨道 36：极角方位距离夹取、`dollyIn/Out` 互逆、damping 每帧一份并收敛、autoRotate、pan 沿 -X 且距离不变、正交改 zoom 不改位、**真 `MouseEvent` 分发**下的 ROTATE 状态与 `2π·dx/height`、轮子正负向、`disconnect`）；demo `apps/interaction-m14/` 六彩盒环 + 中心环面（有孔轮廓）+ 只接收阴影的地面，四手势全部用 Quartz 合成**真实系统鼠标事件**驱动：点击绿盒 `PICK #1 ... -> box2 distance=9.943 point=(-1.947,1.5,4.107) face=4 normal=(0,1,0)`、点击环面 `PICK #2 ... -> torus distance=11.951 face=21 normal=(0.193,0.969,0.156)`（插值后的管面法线）、左拖 271px `drag released ... -- no pick (drag, not click)`、滚轮拉近、右键平移（且右键不触发拾取）。**根因/形状决策**：`Raycaster` 的稳定排序必须用插入排序（AOT 的 `Vector.sort` 不稳定，而 three.js 依赖 `Array.sort` 稳定）；`BackSide` 必须反绕序 `(pC,pB,pA)` 才点得到内壁；距离用**世界**点算；AIR 轮子方向与 DOM `deltaY` 相反故取反；`dollyOut` 是「除缩放比」不是「放大倍数」。拾取与轨道全在 CPU 侧，指令预算不变（163/400、300/400）。分歧 D94–D100、R25–R26 见 `three-api-design.md` §19 |
| 性能 HUD：`Stats` / `StatsPanel`（M15） | ✅ 落地，冒烟 `probes/stats-smoke-m15/` **76 项 ALL PASS**（A 面板几何与标签文法 8：`80×48`、`TEXT_X/Y=3/2`、`GRAPH_X/Y=3/15`、`74×30`、`"<round(v)> <NAME> (<round(min)>-<round(max)>)"`；B `barHeight` 8：归一化饱和、零高、`maxValue<=0`/NaN 退化；C `StatsPanel.update` 21：**min/max 终生单调不重置**、74 槽窗口每次左移一列、读回列高与绘制一致；D 时钟 17：MS 每帧归一化 200、FPS 每 1000ms 窗口归一化 100、边界重置 `frames`、`update()==begin();end()`（假时钟精确断言）；E 面板轮换 11：一次一页、`cycle()` 环绕、`showPanel()` 跳转；F 右上角锚定 5：`x = stageWidth-80-margin`、margin 默认 8、`autoPlace=false` 回左缘、无 stage 回退；G 事件桥 6：点击冒泡到 `Stats` 并翻页、点击/按下被 `stopPropagation` 截断、按下本身不翻页）；demo `apps/stats-m15/`（M13 英雄场景 + 5 页 HUD）用 Quartz 真实系统鼠标事件驱动：锚定日志 `anchor x=872 y=8`（960 宽）、5 次点击 `FPS → MS → MB → CALLS → TRIS → FPS` 且 6 张截图按面板底色分类 5/5 对上日志、**HUD 上拖 30px 不转相机**（`az=0`）随后场景拖拽 `az=-1.396`、开/关 HUD 各跑 ~14 秒帧时间 `42,42` 对 `42,41`ms（面板开销落在抖动里，<1ms）。分歧 D101–D104、R27 见 `three-api-design.md` §20 |
| 应用宿主：刷新率同步 + 窗口 resize（M16） | ✅ 落地，`seam/asaot/three/app/Stage3DApp.as` 收编 15 个 demo 同形的 Stage3D 引导（`stage` 配置 → `requestContext3D` → `CONTEXT3D_CREATE` → `ENTER_FRAME` 里 `render()`+`present()`），并补上两件 AIR 应用必需、浏览器代劳的事：①**显示刷新率同步**——`vsyncEnabled=true` + `VsyncStateChangeAvailabilityEvent.VSYNC_STATE_CHANGE_AVAILABILITY` 的 `refreshRate` 写进 `stage.frameRate`（应用级单值），传给 `frameRateForRefresh()` 归一，`0`/负数/NaN 视为「查不到」**不写**（AIR 赋值下限 0.01 fps）；②**窗口 resize**——`Event.RESIZE` → `renderer.setSize(w,h)` + 透视相机 `aspect`/`updateProjectionMatrix()`（正交相机不自动 refit，留给子类），再经 `onViewportResize(w,h)` 钩子让 `OrbitControls.setSize()`/HUD 重锚跟上。子类只写 `createScene()`/`updateFrame()`/`afterFrame()`/`onViewportResize()`，需要比面板更低的节奏时再写 `frameRateCap()`（默认 0 = 不封顶，D209）。冒烟 `probes/apphost-smoke-m16/` **30 项 ALL PASS**（速率归一 7、**帧率上限 5**、aspect 7、投影重建 6：`elements[0]*aspect==elements[5]`、无 stage 构造 5）；**15/15 demo 起窗日志** `Stage3DApp ready: WxH frameRate=120 refresh=120`（本机 120 Hz 面板，此前恒 24 fps），`AnimationM12` 第 420 帧 `mixerTime=3.475`≈420/120 证明应用时钟真按面板率走；resize 端到端：`StatsM15` 820×600 窗口 → `M15 resize -> 820x568 HUD x=732`（HUD 仍贴右上，`temp/m16-stats-resized.png`）、`InteractionM14` → `M14 resize -> 820x588 aspect=1.395` 后点击屏幕中心仍命中 `PICK #1 ... -> torus`（射线未偏，`temp/m16-m14-resized.png`）、`RotatingCube` 900×388 宽高比 2.32 下立方体仍方正（`temp/m16-cube-resized.png`）。指令预算不变（163/400、300/400）。分歧 D105–D108、R28 见 `three-api-design.md` §21 |
| 纹理状态真生效：`wrapS/wrapT` / `magFilter/minFilter` / `generateMipmaps` / `flipY` / `colorSpace` + `Scene.background`（M17） | ✅ 落地。M2/M5 起 `Texture` 就带着这六个字段，`Scene` 带着 `background`，**但渲染器一个都没读**——端口代码照抄不会报错，画面却不变，这是比缺 API 更危险的静默失效。M17 把它们全部映射到 Stage3D：`wrapS/wrapT` + filter 走 `setSamplerStateAt`（在 `setProgram` **之后**，后写者胜，R29）；`generateMipmaps` 走**上传期 CPU 生成的 mip 链**（`BitmapData.draw` 逐级折半，`mipLevelCount`/`mipDimension` 与运行时同一公式），且与 mip 系 `minFilter` **锁死**——没有链却要 mip 过滤时 AIR 会整条 draw 丢弃（R30：阴影图/中性 1×1 等无链槽必须显式 `clamp/linear/none`）；`flipY` 走上传前行翻转；`colorSpace == SRGBColorSpace` 走片元 `pow(x, 2.2)`，**按槽位掩码编译进程序变体**（`DECODE_MAP`/`DECODE_EMISSIVE`/`DECODE_ENV`），无 sRGB 贴图的场景指令数一分不涨；`Scene.background`(Color) 走 `clear()`（**按已编码的 sRGB 值**，后台缓冲是编码空间，D113）。谁打 sRGB 标：`CubeTextureLoader`（= three.js `:62`）、`GLTFLoader` 的 `baseColorTexture`/`emissiveTexture`（glTF 规范只这两个槽是编码色），`TextureLoader` 不设。冒烟 `probes/texstate-smoke-m17/` **51 项 ALL PASS**（wrap 8 / filter 9 / 链几何 8 / 颜色空间掩码 14 / 清屏色 7 / 行翻转 5）；demo `apps/texstate-m17/` 五块面片一屏说清五件事，**D vs E 像素实测 117 / 116**（同灰度「sRGB 贴图」对「材质色」；没有解码时是 186 vs 116，差 70 个色阶），`temp/m17-mip-ab.png` 是「有链／无链」的摩尔纹 A/B，`temp/m17-flipy-ab.png`（左 `flipY=false` 蓝上绿下＝倒的，右 `flipY=true` 绿上蓝下＝与源图 `uvgrid.png` 一致）证明 M17 之前**平面几何的贴图是上下颠倒的**、现在正了；`env-m9` 的 IBL 亮度回到与立方体贴图本身一致、`gltf-m8` 的鸭子/头盔纹理不再二次编码发白、`animation-m12` 背景由纯黑变实测 `(14,16,21)`（= 作者的 `0x0d1016`，±1 LSB）。`Scene.fog` / `Material.blending` / `Object3D.renderOrder` 仍未实现，但**已登记且一次性诊断**（不再沉默，D114）。指令预算：基础 **163/400**、shadow **300/400** 均不变，新增只有解码位（单贴图 164、环境三处 166）。分歧 D109–D114、R29–R31 见 `three-api-design.md` §22 |
| UV 变换真生效：`offset` / `repeat` / `rotation` / `center` / `matrix`（M18） | ✅ 落地。M17 收官清单的头一条遗留（§22.8）是「没有 UV 变换，tiling 只能靠放大几何 uv 属性」——那是「用模型假装贴图在重复」。纹理状态在采样器上，**UV 变换在坐标上**，所以 M18 按 three.js r187 的分工落在顶点程序：`Texture.updateMatrix()` → `Matrix3.setUvTransform(offset, repeat, rotation, center)`（`three-src` `Texture.js:451` / `Matrix3.js:394`），顶点里用**两次四分量点积**打仿射变换，再按 `uv_vertex.glsl.js:9` 的逐贴图语义把 **6 个槽各自一套**系数塞进 `vc40..vc51`（`UV_MAP`→`v2.xy`、`UV_NORMAL`→`v2.zw`、`UV_ROUGHNESS/METALNESS`→`v6`、`UV_EMISSIVE/AO`→`v7`）。`dp4` 能打完仿射的关键是 Stage3D 给 `FLOAT_2` 属性补默认分量 `(z=0, w=1)`（R32，w=0 时平移项会整条消失）；normalMap 有了自己的 uv 后，切线帧的 `ddx`/`ddy` 必须同源改读 `v2.zw`（R33）；alpha 镂空 caster 的阴影程序同样只上传 `vc40`/`vc41` 走同一变换。冒烟 `probes/uv-smoke-m18/` **39 项 ALL PASS**（`setUvTransform` 数值 8 / `matrixAutoUpdate` 契约 13 / 常量打包 3 / **打包行 ≡ `mat3·(u,v,1)`** 2 / 六槽 varying 表 6 / 顶点块结构 7——含给 AS3 **`return` 换行自动插分号**立的钉子）；demo `apps/uv-m18/` 六面片**共用同一几何 uv（一个像素都没改）**，差别全在 Texture：A 参照、B `repeat(4,4)` 接缝 **25.5/50.5/75.5%** ⇒ 正好 4 格、C `offset(0.5,0)` 接缝 **50.5%** 且 R 由 210 掉到 101 ⇒ 位移恰好半张、D `rotation=π/4 + center=(0.5,0.5)` 中心像素与 A **相同** ⇒ 绕贴图中心旋转、E `matrixAutoUpdate=false` + 手写 `matrix`（缩放 -1,1）剖面与 A **逐点镜像** ⇒ 负缩放（`repeat` 是格数，写不出负数）、F 底色 1×1 + `emissiveMap.repeat(3,3)` 三组采样**原样重复三次** ⇒ 两槽互不干扰。**片元指令一分未涨**（163/400、300/400、`env-m9` 166、`gltf-m8` 223/224、`alpha-m10` 180 与 M17 逐个相同），新增只有每 draw 16 条顶点指令。不落：`texture.channel` 多 UV 集、`envMap` 的 UV 变换。分歧 D115–D118、R32–R34 见 `three-api-design.md` §23 |
| 渲染状态真生效：`Material.side` / `depthTest` / `depthWrite` / `blending`、`Object3D.renderOrder`、`flatShading` / `wireframe`（M19） | ✅ 落地。同一类「字段在、渲染器不读」的第三批（M17 纹理状态、M18 UV 变换之后）：六个字段里 **`Material.side` 是唯一肉眼可见的 bug**——渲染器对每个 pass 写死 `setCulling('front')`，于是 `DoubleSide` 的薄片从背面看直接消失，glTF `doubleSided:true`（`GLTFLoader` 会设 `DoubleSide`）也等于没设。M19 把每个字段映射到后端的真实调用，并各自收敛成一个纯函数（探针可钉）：①`side` → `setCulling`，**必须反着映射**（后端正面是 CW、three.js 几何是 CCW ⇒ `FrontSide → "front"`、`BackSide → "back"`、`DoubleSide → "none"`，D119）；②`depthTest`/`depthWrite` → `setDepthTest(depthMask, compare)` 的两个半边，`depthTest=false` 用 `"always"` **并且连写也关**（关掉的 GL 深度测试本来就不写，D120；这条取代了 M10 的 D49「透明 pass 一律不写深度」，现在由 `depthWrite` 决定）；③`blending` 五模式按 `WebGLState.setBlending` 逐条抄（Normal/Additive/Subtractive/Multiply/None → `setBlendFactors`），`CustomBlending` 降级到 Normal + 一次性诊断（R35、D121）；④`renderOrder` 成为两张列表的**首**排序键（不透明稳定排序、透明 `renderOrder` 优先再远到近，D122）；⑤`flatShading` 用已经算好的位置导数叉乘出**面法线**（`crs`+`nrm` 两条指令，只 +1 片元指令，D123）；⑥`wireframe` 没有线图元 ⇒ 复用 M11 线段程序把每条边展开成屏幕空间四边形（168 面 → 504 条边，D124）。状态每 draw 一次（`_applyMaterialState`），排序零分配。冒烟 `probes/renderstate-smoke-m19/` **59 项 ALL PASS**（culling 6 / shadow-culling 3 / 深度 7 / 混合 11 / 排序 5 / 默认值 7 / 面法线 6 / 边打包 14）；demo `apps/renderstate-m19/` 九块面板 A–I 各有可测像素：A `(51,51,51)` 只剩背景板 vs B `(104,188,249)` 板在、C/D 远绿盖住近红、E 三条带 Normal `(107,57,92)`/Additive `(128,77,112)`/NoBlending `(195,72,156)`、F 红压绿、G 光滑 `(162,167,174)` vs H 平直切面 `(140,144,150)`、I 线框球。**片元预算不变**（163/400、300/400、env 166、gltf 223/224、alpha 180、shadow-m7 241），新增只有 `flatShading` 变体 164/400；静态 demo 像素级不变（`texstate-m17`/`uv-m18`/`interaction-m14` 均 0.00%）。分歧 D119–D124、R35–R39 见 `three-api-design.md` §24 |
| UI 层接入 + 布局约定（M24） | ✅ 落地。把 three.js 例程里「`stats.dom` 右上 + `lil-gui` 右上」的**抢座冲突**摆平：①`Stats` 默认锚点从右上改**左上**（`alignAt: "left"|"right"`，非法值**抛错不回退**；默认值必须写字符串字面量——as-aot 不在参数默认值位求值类常量），探针 F 节由 5 项扩到 10 项（默认左上 / 右锚数学 / 无 stage 回退 / 未知值抛错），全套 81 项 ALL PASS；②控制面板固定 `300px` 贴右缘、全高，中间 3D 与左上 HUD 都不被遮挡；③`asaotui`（**另一个 checkout**）**就地链接**，`apps/<demo>/class-paths` 每行一个源根，`tools/build-demo.sh` 同一份清单喂两端（`--as-class-path` / `-source-path+=`），复制即分叉所以不复制；④数据流**单写者**：widget → `PanelState` → 帧循环 `applyState()` 是唯一写 `Scene`/`Light`/`Material`/`AGALRenderer` 的地方（M20 雾 bug 的同款纪律：两处可写 = 两份自相自洽的真相）。demo `apps/panel-m24/`（雾开关/near/far、太阳强度/角度、阴影、色调映射、曝光、线框、重置），Quartz 真实系统鼠标事件驱动：`stats x=8 panelW=300`、点线框 `wireframe=true`、关阴影+关雾 `shadows=false`/`fog=false`、拖 Far 34→15 标签与雾带同步，120 fps / `calls=5` / `tris=50` 不变；AIR 侧 196,498 B SWF 起窗、面板同形。**另实测登记一条双端差异（D142/R56）**：同一描述符 `1200×900`，AOT 得到 stage `1200×900`（描述符 = 客户区）、AIR 得到 `1200×868`（描述符 = 窗口 frame，含 32px 标题栏）⇒ 跨端像素比对必须先把 **stage 尺寸**对齐，否则差的是投影不是渲染。分歧 D139–D142、R56–R58 见 `three-api-design.md` §27；three.js 三个例程的缺口审计与 M25–M27 排期见 §28 |
| 骨骼可视化 + 键盘桥 + 交叉淡入（M26） | ✅ 落地。§28.1 里 `webgl_animation_walk` 的三条 ❌ 全部补齐，验收方式是把整个例程搬成 demo `apps/walk-m26/`（`Soldier.glb` + 棋盘地面 + 跟随灯光组）：①**键盘桥**收在宿主 `Stage3DApp.keys`（`kit/asaot/three/input/Keyboard.as`）——`KEY_DOWN/KEY_UP` 维护「按下表 + 一帧边沿表」，`Event.DEACTIVATE` 清表（否则 alt-tab 回来角色一直走），宿主在 `afterFrame` 之后调 `endFrame()` 折掉边沿，越界键码计入 `droppedKeys` 而不是静默丢；②**交叉淡入**：`AnimationAction` 补 `crossFadeTo`/`crossFadeFrom`/`syncWith`/`warp`/`stopWarping`/`halt`，`warp` 存的是**相对倍率**并在窗口末折回 `timeScale`（实测 `runTS=0.677=walkLen/runLen`，切回走步后步频仍对得上）；③**骨骼可视化**：`SkeletonHelper` 用 M11 的线段程序，新增线段程序的 `(vertexColors, toneMapped)` 变体（`va3 → v1`），未开顶点色的 draw 仍走原程序；glTF 关节节点置 `isBone=true`（AS3 不能事后换类，`Bone` 除标记外无他物）。Quartz **真实系统按键**驱动验收：AOT `action: Walk` → `Run warp=true time=0.333` → `Walk warp=true` → `Idle`，权重逐帧可读、`pos` 单调推进、`skeleton: true` 后 `calls` 3→4 / `tris` 16376→16472（48 段骨骼线）；AIR 同一脚本拿到同样三次切换与同一个 `calls/tris`。冒烟 `probes/anim-smoke-m26/` **59 项 ALL PASS**，标准片元指令数**一分未变**（163/400、阴影 300/400）。**顺带登记两条遗留**：AIR 长跑 `#1502` 拿到更窄的抛点（`SkinnedMesh._skinIntoAttributes()` ← 阴影 prepass）且证明它**间歇**；`env-m9`/`walk-m26` 的 AOT↔AIR **环境贴图观感差异**（AOT 更暗、高光发白）为既有分歧，列为 M25 第一件事。分歧 D143–D151、规则 R59–R62 见 `three-api-design.md` §29 |
| M26 收尾：可移植资源路径 + 环境贴图分歧定性（2026-11-01） | ✅ 落地。①**双击即挂**：21 个 demo 的资源路径从裸相对路径全部改成 `app:/assets/...`，`tools/build-demo.sh` 在两个后端产物旁各建一个 `assets` 符号链接（AOT 在可执行文件旁、AIR 在 SWF 旁），于是路径不再依赖 cwd——从 `/tmp` 起跑与双击可执行文件均零 `ioError`、零 `#2032`（§2.1）。②**环境贴图分歧定性并修复**：`env-m9`/`walk-m26` 的 AOT 偏黑不是 cube 朝向也不是 sRGB 编解码，而是**编译器**在把 AGAL 展开成逐分量赋值时制造的读后写别名（`mul ft8.xyz, ft0.xyz, ft8.xxxx` 的第 2、3 分量读到已改写的 `ft8.x`）；`agal_emit_body` 新增 `agal_mask_clobber`/`agal_snap_src`/`agal_src_expr_named`，命中危险别名时先发整寄存器快照（§29.5）。证据链：新诊断 demo `apps/cubeface-m25/`（六面纯色 + 镜子球，六面逐面读回全对）、`as3compiler/examples/stage346.as`（8 条翻译文本断言 + Metal 像素读回）、单元组 `stage3d/agal-write-mask-alias`、全量 `node test.ts` **4664 PASS**。③`walk-m26` 默认姿态按参考收口：参考本身**没有**环境贴图也没有 HemisphereLight，故默认 `scene.environment = null`，城堡 cube 仍在启动时加载，按 `E` 切换（保留 IBL 可演练）。**遗留**：`walk-m26` 的双端明度差已从「材质」改判到「阴影项」：静态因子分解（`apps/texture-maps` 钉死姿态 + 同行对照面）证明 `metalnessMap` 采样与 ACES 两条路径两端**都在 1% 内**，真正的分歧是 **AOT 在某盏灯没有任何投影体时把整个阴影视锥压黑**（同一份源码：地面 AOT `11.8` 对 AIR `31.8`，本体 AOT `63.9` 对 AIR `48.0`，AIR 侧才是对的）。已登记 §29.6，含修法方向（无 caster 时该光不参与阴影项，而不是靠清屏色凑）与 30 秒复现步骤。 |
| M26 后续：空 caster 阴影修复 + AGAL `exp`/`log` 底数（2026-11-01） | ✅ 落地。①**「有 `castShadow` 灯、没有 `castShadow` 网格」把整片阴影视锥压黑**（上一行的遗留）根因**不在 `AGALRenderer`**，而在 Metal 后端：`clear()` 是**延迟**操作，真正的清屏挂在下一次 `drawTriangles` 的渲染通道 `loadAction` 上，于是「清完零 draw」的阴影 prepass 从未落地，贴图停在新分配私有纹理的未定义内容（全 0），8bit 打包深度解出 `0.0` = 「比任何片元都近」⇒ 整锥判遮挡；`adl` 的 clear 与 draw 无关，空 pass 照样落到贴图上（深度 `1.0` = 最远）。编译器侧补 `s3d_apply_pending_clear()`（目标切换 + 帧末离屏仍绑定两处补一条零 draw 清屏通道），钉子 `as3compiler/examples/stage347.as` + `unit: stage3d/pending-clear-no-draw`。修后同源同帧地面 AOT `34.6` 对 `adl` `32.1`（修前 `11.8` 对 `31.8`）。②**AGAL 的 `exp`/`log` 是以 2 为底**（`adl` 与 AOT 逐值一致，翻译器本就是 `exp2`/`log2`），而 `AGALRenderer` 两处按「只有 e^x」折算：EnvBRDFApprox 的 `-9.28` 被折成 `-9.28·ln2`、FogExp2 少乘 `log2(e)` —— **两端同错**，所以 AOT/AIR 差分永远看不见，只有对着 three.js 参考值才显形；两处已按 §29.7 修正。顺带修掉 `dumpFragSource` 在 `adl` 上抛 `#1065`（`AGALTranslator` 不在 `airglobal.swc`）把 AIR 端每帧打死的问题。**§29.8 结案**：那条「本体点积两端系统性不同」是**取样口径**——把 AIR 描述符高度临时改成 832（stage 也 1000×800）后，AOT 与 AIR 逐项相同（雾关本体 38.69 对 37.80、地面 27.22 对 27.28），原读数撤回。判「谁对」改用参考实现本身：新增 `tools/refscene/`（three.js `webgl_animation_walk` 在 1000×800 下钉死姿态，暴露 `__stats(box)` + 同口径的 `boxstats.mjs`），真值是本体 11.45 / 地面 21.10（雾关）⇒ **两端同样欠**：金属本体 3.4×、地面 +29%（M26-R1），雾抬升 +5.50 对参考 +9.30（M26-R2）。§29.6/§29.7/§29.8 |
| HDR 环境贴图（M25，2026-11-01） | ✅ 落地。M9 的 IBL 只吃已编码的 8 位 cube，而参考路线是「float panorama → 预滤波 cube」；环境 cube 在任何档位都**没有 float/mip 存储**（默认档也没有 float 渲染目标；`standard` 档才有 16F 2D/RT，`three-api-design.md` §36），于是整条链路搬上 CPU：`RGBELoader`（RGBE→线性 `2^(e−128)/255`、平铺/旧 RLE/新 RLE 三种扫描线、`±X`/`±Y` 轴向、`EXPOSURE`、**显式拒绝** `32-bit_rle_xyze` 与非 Radiance 文件）→ `EquirectangularToCube`（六面方向与 Stage3D cube 采样逐面对齐、`autoScale` 取 99.5 分位向上取 2 的幂、**真 sRGB OETF** 编码 —— D177，原为 `pow(·,1/2.2)`）→ `CubeTexture.hdrScale` 存除数（**D154**：8 位面装的是伽马编码的线性辐照度，既不是 sRGB 颜色也不是线性值）。渲染器新增 HDR 背景程序 `_bgCubeProgramHdr`（解码 + 乘 `hdrScale·backgroundIntensity` + 色调映射，M20 的 decode 变体少了后两段故不够用）与 `_bgCubeProgramHdrBlur`/`_bgCubeProgramHdrBlur9`（**D156**：AGAL 无 `textureCubeLod`，`backgroundBlurriness` 用分档角度锥近似，`blurTapsFor` 按强度选 0/5/9 tap），环境强度在 CPU 折成 `envMapIntensity·environmentIntensity·hdrScale`（**D157**，不占新槽位）。踩坑：模糊分支先写 `ft0.xyz` 再 `mov oc, ft0` 会被 `adl` 判 `#3647/#3648`，必须先写满四分量。冒烟 `probes/hdr-smoke-m25/` **69 项 ALL PASS**（含 `.exr` G 段；「方向着色全景」抓 v 轴翻转/面序/经度镜像三类最容易犯的错）；demo `apps/hdr-m25/` 只由一张 512×256 `.hdr` 照明，五球粗糙度 0.05→1.0 + 七个按键（模糊/环境强度/背景强度/背景切清屏/环境开关/重烘焙 128↔64/`.hdr`↔`.exr` 换源），AOT 日志 `bake 128px in 17ms, autoScale=64, hdrScale=64`；资产由 `tools/gen-hdr.js` 合成入库，不依赖外网。**遗留**：无 PMREM/多级预滤波（M25-R1）、背景模糊是分档角度锥非 LOD（M25-R2 已分档，语义仍非 LOD）、烘焙单线程（M25-R4）；`.exr` 已落地（M25-R3 ⇒ §33）。§30 |
| loader 行为对齐（§31，2026-11-01） | ✅ 首批落地（L1–L5）。审计口径：**AOT 先行**，参考物是 three.js r187 的 `src/loaders/`，不拿 AIR 当对齐目标。①**`L1` 真缺陷**：`FileLoader`/`ImageLoader`/`TextureLoader`/`CubeTextureLoader` 把回调与在飞状态存在**实例字段**里，同一实例上第二次 `load()` 会把**第一个文件的数据交给第二个回调**、把两张图都写进第二个 `Texture`（three.js 免疫是因为它每次 load 新建闭包）——四类全部改成 per-load 局部闭包（**D158**），实例上只留 `abort()` 需要的在飞表；②`ImageLoader.load()` 同步返回解码句柄（**D159**，three.js 返回 `Image`，我们返回 `flash.display.Loader`）；③`responseType='json'` 交付解析后的对象、`'blob'/'document'` **报明**不再静默当 text（**D32** 改写）；④补齐 `setResponseType`/`setMimeType`/`setRequestHeader`/`abort()`（**D160**，并**收窄 D25**：`requestHeader` 不是 XHR 专有，`URLRequest.requestHeaders` 是真的会发；`abort()` 走 `URLLoader.close()`，取消后不派发事件）；⑤不做 fetch 去重扇出与 `Cache`（**D161**，写明「同 URL 并发两次各拿不同对象」这一可观测差异）。验收：`probes/loader-smoke-m5/` 新增第 9–13 节 24 条断言（含「两张夹具图必须不同」的反证），**A/B 变异实测**——把回调改回实例字段后第 10 节立刻红（`first onLoad fires exactly once (got 0)`），恢复即全绿；同轮 `loader`/`asset-load`/`gltf-m8`/`env-m9` 四探针全绿。**遗留**：`LoadingManager`（L6，P1）、`GLTFLoader.register()` 第三方扩展入口（L12，P2）。§31 |
| M25-R3 `.exr` 解码（§33，2026-11-01） | ✅ 落地。`EXRLoader`（`kit/asaot/three/loaders/`）：扫描线 EXR，压缩 **NONE + RLE**、像素类型 **HALF + FLOAT**，`dataWindow` 非零原点 / `red|green|blue` 通道拼写都认；ZIP/ZIPS/PIZ/PXR24/B44/B44A/DWAA/DWAB、UINT 通道、tiled/deep/multi-part/非 INCREASING_Y **一律按名报错**（D168/D169），不假装支持。载荷仍是 `HDRImage`（D167）：下游产物是 8 位 cube（cube 在任何档位都没有 float 存储，§36.2），所以 half 采样在解析时压成 RGBE，`EquirectangularToCube`/`autoScale`/`hdrScale` 零改动。**最大的坑**：OpenEXR 的 RLE 载荷不是扫描线本身——它和 ZIP 一样先跑 `reorder_and_predict()`（字节间 delta + 偶奇拆分）再做字节 RLE，少了这两步解出来是「长度正确、看着像数」的噪声，而编码器/解码器互为逆阵时自测全绿；靠 OpenCV、ffmpeg、`exrmetrics` 三方一致报 `NaN` 才抓到（§33.3）。资产 `tools/gen-exr.js` **import** `gen-hdr.js` 的 `radiance()` 生成同题材 `studio.exr`（256×128 HALF/RLE，8.8 KB），demo 按键 `7` 双格式换源对拍。探针 G 段 11 条（含 G3a「RLE chunk 真的更小」防止断言退化）。§33 |
| M26 对拍量具 + M26-R1/R2 判定（§32，2026-11-01） | ✅ 落地。§29.8 的对拍靠**截窗口**，每读一个数都要跟标题栏 / 缩放 / 动画相位搏斗，M26-R1/R2 一直挂着，根子是量具不是渲染器。新量具 `apps/m26-parity/`：400×300 固定 stage、`Idle` 只 `mixer.update(0)` 一次（姿态冻结）、`Context3D.drawToBitmapData()` 读**后缓冲**、与参考页同一组分数框同一统计口径；`tools/refscene/` 补 `?w=&h=` 让参考页也能渲成 400×300。量具本身三个坑都记在代码里：回读读到**环形 drawable**（同帧连读 4 次，前几次是旧帧 0 对 28.43）、地面贴图在 20～65 帧之间任意落地（改成「两个框连续 5 帧不动」才开测）、以及 `afterFrame()` 里再 `render()` 一遍会重入延迟清屏把地面整块抹黑。参考页自身也查出两个 bug：模块少一个收尾 `} );` 导致整页从未执行（**旧的「three.js 真值」20.75/11.45 作废**）、漏设 `metalnessMap = map`（同一帧 26.02 对 42.25）。判定：**M26-R2 撤回**——把起止值反解回线性空间，雾混合系数 `0.0705` 对 `0.0728` 差 3%，雾语义是对的，看着「抬得不够」只因起点亮度不同；**M26-R1 拆三条**——纯灰地面 `108.82` 对 `110.66`（**光照基线 −1.7%**，往后不许再说「整体偏亮」）、贴图地面 +20%（贴图采样路径，R1a）、金属高光瓣 p90 2.2 倍且 p50 只有一半（分布问题不是能量问题，R1b）。顺带登记 N5：r187 的 `dfgLUT` 是 256×256 2D 查表，我们后端**能采 8 位 LUT**，不必上 float。§32 |
| M26-R1b 收口：三处 PBR 保真缺口（§34，2026-11-01） | ✅ 落地。R1b（金属本体「p50 只有参考一半、p90 是 2.2 倍」）追到根因：**不是**叶瓣公式，而是三处「比 three.js 少做一步」。①**D170 sRGB 传递函数**：解码/编码一直用 `pow(x, 2.2)`，真曲线 `1.055·x^(1/2.4) − 0.055` 在中间调差 3 个码值且方向固定，于是「2.2 解码 + 1/2.2 编码」是个自洽但**不是 sRGB** 的往返对——中性贴图看不出，有内容的贴图只剩非线性残差（§32.8 量到的「贴图地面 +19.8% / 纯灰 −1.7%」正是它的形状）。改成真曲线（`fc41/fc42` + `SRGB_CONSTANTS`）后地面 **+19.8% → −8.2%**、本体 **+10.6% → +4.4%**。坑：解码里 `+0.055` 曾误写成 `fc41.wwww`（2.4）导致整帧发白，故探针**逐字文本**（D11）+ **数值**（D16/D17）+ 256 级互逆（D18）三条一起钉。连带把线框/Line 程序提到 AGAL4（新常量超过 AGAL1 的 28 槽上限，超限时汇编器返回**空程序**=静默不画）。②**D171 数据槽解码**：`metalnessMap = map` 时 three.js 的 sRGB 解码是**纹理属性**（GPU 采样器不知道槽位），我们按槽位只解了颜色槽 ⇒ 金属度读到编码蓝、高估最多 4 倍 ⇒ 掐掉漫反射暗部发黑（A/B：参考 +62%、我们 +19%）。补 `DECODE_ROUGHNESS/METALNESS`（单分量 3 条指令），glTF 的线性 MR 贴图两位不置。③**D172 `geometryRoughness`**：r187 把法线**屏幕导数**折进粗糙度（`roughness += max|dFdx/dFdy(nonPerturbedNormal)|`），我们整段没做；而 `D_GGX` 在粗糙度 0.2 时 `dotNH` 掉 1% 就掉 180 倍，于是「法线恰好平分 L/V」的一片扁平装甲**整片打爆**、邻居全黑。补 7 条指令（`ddx/ddy/abs/abs/max/max/max`，`ft12.x`，flat 分支置 0）后 p90 **237 → 82**（参考 105）、p50 **15.3 → 22.6**（参考 32），爆块消失，地板读数**一位不变**（平面导数恒 0，旁证只影响曲面）。三处后本体框是参考的 `0.84/0.70/0.78` 倍——剩下的是**缺功能**不是误差：`multiScatteringCompensation`（`dfgLUT`，Ess≈0.9 ⇒ ×1.11）即 §34.4 的第一杠杆，本轮不做以免把新特性混进对齐修正。另 A/B 排除四个无辜嫌疑（常量、法线贴图、面罩、阴影），附录 §34.5。探针 `texstate-m17` **45 → 68 项 ALL PASS**（D19–D27 数据槽、G1–G3 几何粗糙度逐字），25 组探针 + 24 个 demo 全绿。§34 |
| M26-R1b 收口二：多散射补偿 D173（§34.4，2026-11-01） | ✅ 落地，但**假设被实测证伪**。§34.4 原判「缺 `multiScatteringCompensation` ⇒ `Ess≈0.9` ⇒ ×1.11 ⇒ 正好补上那四分之一」；实现后实测只有 **+2%**，因为三条被略读的事实：①补偿是 `1 + specularColorBlended·(1/Ess−1)`，**乘的是 F0** —— walk-m26 本体 `metalnessMap = map`，有效金属度 ≈ 贴图蓝（≈0.2）⇒ F0 ≈ 0.07，地面介质 0.04，而 ×1.11 只在 `F0 = 1` 时成立；②`Ess` 只由粗糙度决定（Karis 系数满足 `r.z + r.w = 1 − 0.55·roughness`，`a004` 在求和里整体抵消，与 NoV 无关）；③本体镜面只占读数约 **15%**（用「把 comp 强改成 2.0」标定灵敏度反推）——它是个 0.2 金属度的**漫反射体 + 一点镜面**，剩下那 16% 要从漫反射/反照率路径找（§34.5），继续在 BRDF 上加常数是错方向。落地三处与 r187 同序：标准直接光（DFG 提到 Stage 5.5，直接光与 IBL 共用一对 AB，第二盏平行光同乘）、**IBL split-sum 两半**（补 `Fms·Ems·irradiance/π`，`1/21` 落 `fc10.y` 不加宽常量块）、**点光/聚光**（r187 对每次 `RE_Direct` 都乘；punctual 上传从 `fc0..fc10` 扩到 14 个寄存器，`fc11..fc13` 不显式填会读到上一个标准 draw 的残留）。新增公共块 `envBRDFApproxBlock`（12 句，**永不写 `ab.w`** —— 那里停着光 0 的 PCF 因子）与 `multiScatterCompBlock`（标量在 `tmp` 算完再乘 vec3，避开写掩码别名）。指令预算：无 tone/无阴影 **163 → 194**，阴影+tone+fog **308/400**。验证手法：把 Stage 7 的色调映射与 sRGB 编码临时摘掉回读线性值，地面 `224/255` ⇒ `Ess = 0.532`，与 `1 − 0.55·0.85 = 0.5325` 逐位吻合；本体 `78/255` ⇒ 0.766 vs 粗糙度读数 `109/255 = 0.427` ⇒ 0.7635（诊断改动已全部回滚）。读数：body mean **35.34 → 35.50**、floor **21.79 → 22.17**（`fog=1 body 35.50/22.62/82.29, floor 22.17`）。探针 `texstate-m17` **68 → 78 项 ALL PASS**（H1–H10），25 组探针全绿，`light-m6`／`hdr-m25`／`walk-m26`／`renderstate-m19` AOT 构建通过；AIR 证据是 `apps/walk-m26` 在 `adl` 下 180+ 帧 `calls=3 tris=16376` 正常绘制（覆盖阴影+tone+fog 的 308 指令变体），而 `m26-parity` 在 `adl` 首帧就撞早已登记的间歇 `#1502`（`OrbitControls.update`），不能当 AGAL 校验证据。§34.4/§34.5 |
| M26-R1a 分层实验：albedo 洗清、量具第四坑（§32.8/§32.9，2026-11-01） | ✅ 落地。为把 albedo 固定住再比，两侧各加旋钮 `?floor=plain\|solid` + `?floorlevel=N` + `?floorcolor=` + `?floornormal=0`（harness：`FLOOR_PLAIN`/`FLOOR_SOLID`/`FLOOR_SOLID_LEVEL`/`FLOOR_COLOR`/`FLOOR_NO_NORMAL`，`FLOOR_COLOR = -1` 表示按模式取默认，故默认配置仍逐字复现 §32.4 真值）。**albedo 路径洗清**：同 albedo 的对照全部 ±1%（纯色 0.216 → `110.06` 对 `111.00`；1×1 灰贴图 0.216 → `111.31`；1×1 白贴图 albedo 1.0 → `207` 对 `209`），含 `pow(x,2.2)` 对 0x80 的 1.7% 偏差 ⇒「wrap/anisotropy/decode 抬高地面」不成立。**剩下的收窄到「贴图内容 × 过滤」**：换回真棋盘格、同 color 同 UV，就从 −0.8% 跳到 **+28.4%**（`27.21` 对 `21.20`，p50/p90 整条平移），**mip 路径也已排除**：`repeat 16→1`（放大到无 minification）后两侧同时下降（`27.21→24.95` 对 `21.20→19.45`），比例 `+28.4% → +28.3%` 不变 ⇒ `mipnone` vs 三线性/各向异性 16 不是原因；棋盘格平均编码值实测 `0x92/0x91/0x96`（真 sRGB 解 0.283、`pow2.2` 解 0.295，差 4%）也不足以解释 28%，下一步需要把 albedo 直接画上屏逐 texel 对拍。**量具第四坑（重要）**：§32.2 的「最亮 3 帧」会把**没画上去的帧**当成更亮——`0x5e5d5d` 上屏后亮度恰为 `93.2126`，深色地面连跑三次得到 `46.30/93.21/46.30`，第一版被误判成「2× 双态渲染 bug」，把 `scene.background` 临时改黑即 `46.30/46.30/46.30` 反证。修法：与清屏色亮度差 <0.5 的样本一律丢弃并打印 `dropped=N`，不静默；**地板 draw 偶发丢失**作为独立缺陷留给 R1a′ 第一件事 |
| M25-R1 预滤波阶梯 + M27 LightProbe（§35，2026-11-01） | ✅ 落地。①**先算预算再动手**：这个后端的片元采样器只有 `fs0..fs7`（`stage3d_glue` 只处理 `unit < 8`），而阴影变体已经八槽满员 ⇒ **没有 `fs8`**，「PMREM + 独立 irradiance cube」两条都放不下（第一版试过写 `fs8`，探针过、AOT 过，AIR 里那个槽根本不存在 —— 典型的「碰巧能跑」，已回滚，**D175**）。②**M25-R1**：CPU 产出 6 档（`roughness 0/0.2/0.4/0.6/0.8/1.0`）cube 阶梯，图元侧按 `material.roughness` 选一档绑 `fs7`，AGAL 侧**反而少 6 条指令**（`prefiltered=1` 不再发 M9 的 `mix(cube(R), cube(N), r⁴)` 替代块，`213/400 → 217/400` 但同解码状态相比 −6）。叶瓣用 Karis 余弦幂拟合（与 GGX 的交叉点在 `r = 0.9526`，探针 `A8`），核必须**角度各向同性**（横向 sigma 除 `sin(polar)`，否则纬度 60° 的灯糊成横条），能量守恒**按构造**保证（各档结束前按 `EnvironmentPrefilter.sphereMean(base)` 重标定，`E2` 用 `1e-12` 钉住 —— 第一版用像素均值当不变量是错的，极点行不代表更少立体角）。③**D178 分帧烘焙**：同一份 CPU 循环 AOT **84–98 ms** 对 `adl` **2186–2356 ms**（26 倍），两秒落在一帧就吃掉 AIR 15 秒看门狗的三分之一（栈停在 `Object3D.updateMatrixWorld`，看着像渲染器 bug）；`PrefilterJob.step()` 每帧烘一档（第 0 档就是清晰 cube，环境立刻可用，`partial()` 保证中途渲染不是非法态）。④**M27**：见路线图行。⑤**D177**：HDR 存储曲线与渲染器解码收成**一对**真 sRGB（`EquirectangularToCube.srgbOetf` ↔ `srgbDecodeBlock`/`fc41`），`fc36`/`DECODE_CONST` 退役。验收：`prefilter-smoke-m25r1` **39 项**、`lightprobe-smoke-m27` **36 项**、`hdr-smoke-m25` **69 项**、`texstate-m17` **77 项**全 ALL PASS；`apps/hdr-m25` AOT `bake 128px in 98ms over 6 frames` + 截图逐档验证高光宽度单调变宽。**AIR 侧两个新发现的真缺陷已修**（`Keyboard` 同名歧义、`AGALRenderer` 未 import ⇒ `#1065`），**但 `adl` 下 cube 背景仍不绘制**（D179，未定位：片元/顶点/剔除/状态/深度/缓冲/普通 LDR 变体逐项 A/B 全部排掉，唯一没排除的是 adl 自己 —— 同 session 间歇 `#1502`），故背景天空盒**不进已验收**。§35 |
| 能力面实测：格式 / profile / 顶点纹理取值（§36，2026-11-02） | ✅ 落地（**只记录实测，不靠文档推断**）。做法：一支无窗口 Stage3D 探针按引擎真实调用方式在 **AOT/Metal** 与 **AIR/adl 51.4.1** 各跑一遍并读回像素（`probes/fmt-vtf-m28/`，已入库可复跑）。四条结论：①**profile 不跟随请求** —— `requestContext3D("auto","enhanced")` 在 AIR 得到 `enhanced`、在 AOT 得到 `baselineExtended`，后果是 `createTexture("rgbaHalfFloat")` 在 AIR 成功而在 AOT 报 `#3759`；带 `ASC_S3D_HALF_TEXTURES=1` 时 AOT 认领 `standard` 且半浮点 RT **真的保住 2.0**（`clear(2.0)×0.25` → `0x808080`，8 位为 `0x404040`）。**没有**去谎报 `enhanced`（还缺 MRT）。②**格式只对 2D/RT 有效**：`rgbaHalfFloat` cube 被接受但存的是同样那批 8 位字节（取样逐位等于 `bgra` cube）⇒「半浮点 cube 装真 HDR」这条路不通，M25 的 8 位 sRGB + `hdrScale` 取舍因此仍然成立，但**理由换了**。③**cube 的 `miplevel>0` 上传被静默丢弃**（不抛、不改 level 0）⇒ M25-R1 的六个独立 `CubeTexture` 是唯一可行形态，别改回 mip 方案。④**VTF**：开工时 AIR 可用（`tld`+`vs0` 读回绿色）、AOT 在 draw 抛 `Error id=0 msg=null`（按 §1.5 属**遗留缺陷**）；写文档时编译器侧的 `tld` 已由另一路落地，重跑同一探针 AOT/Metal 也读到 `0xff00` ⇒ **两端一致**，D3D12/WebGL 与顶点采样器 flags 仍未测。落地改动：全仓 12 处把「后端没有浮点纹理」当成平台事实的注释/文档改成**分档测**口径（`SkinnedMesh`/`Skeleton` 的 D84/D85 理由从「取不到」改为「存储只有 16F 且仅 `standard` 档，精度不足」）；阴影 prepass 的 `clear(...,3)` 补 `#3692` 依赖说明（`depthAndStencil` 下掩码缺 STENCIL 会让 `drawToBitmapData` 抛错，那里靠「不回读」才安全）。详见 §36 |
| loader 第二批（§31.8，2026-11-01） | ✅ L6/L12/L3 落地 + 口径收尾。①**L6 `LoadingManager`**：`itemStart/itemEnd/itemError` + `onStart/onLoad/onProgress/onError` + `setURLModifier`，构造用**可选参数**扩展（`new FileLoader(manager)`）、既有调用零改动；`itemError` **不**平衡计数、失败项仍 `itemEnd`（three.js 同）——所以「一个失败也算这批结束」。**D162** 不做 `normalize('NFC')`（as-aot 无归一化数据）；**D163** 不落 manager 级 `abortController`（批级取消要新所有权层）；**D164** `addHandler/getHandler/removeHandler` **实现但不消费**。②**L12 `GLTFLoader.register()`**：四个钩子 `getMaterialType`/`extendMaterial`/`createNodeMesh`/`afterRoot`，**D165** 同步+给实例（AS3 无 Promise、无类值），触发面与 three.js 一致；坑：AS3 用多于声明的参数调闭包抛 `#1063`，钩子必须按声明**元数**派发。③**L3 `KHR_texture_transform`**：`offset/scale/rotation` 落到 `Texture` 的 M18 uv 变换，**D166** 逐引用 `clone()`（两槽同图不同变换不串味）。④顺带修 `RGBELoader` **D158 复发**（M25 写它时又把请求与回调放回实例字段）。验收：`loader-smoke-m5` 第 14 节 **22 条断言 ALL PASS**（批聚合/失败仍平衡/`setURLModifier` 收到已拼前缀的 URL 且真改写读取结果/`texture.image is BitmapData`/同 URL 并发拿到两个不同对象/3 面报错不挂起/`ImageLoader` 不调 `onProgress`/插件四钩子各一次/变换逐引用生效）。§31.8 |

| 原生着色器通道（**E6 · M30**，2026-11-02） | ✅ 落地（引擎侧；编译器侧 M2/M3 见 `as3compiler/TODO.md` 阶段三百五十三）。三件新增 + 一条红线：①`ShaderMaterial`（`kit/.../materials/`，**纯数据**：`vertexShader`/`fragmentShader`/`uniforms`/`defines`，**不 import `flash.display3D`** ⇒ 同一份源码在 `mxmlc` 下照编）；②`NativeShaderRenderer`（`seam/.../`，`extends AGALRenderer`、只覆写 `_drawShaderMaterial`）——五个自动 uniform（`projectionMatrix`/`modelViewMatrix`/`modelMatrix`/`viewMatrix`/`cameraPosition`）+ 作者 uniform 全部按**反射名字**喂给 `Context3DNative`，`ALIASES`（`position`/`normal`/`uv`/`color`）+ 按位置回退兜住 three.js 的 `attribute vec3 position` 写法；③`RendererFactory` 运行时探测（`getDefinitionByName` 落空即回 `AGALRenderer`），`Stage3DApp` 的创建点从 `new AGALRenderer(...)` 改成 `RendererFactory.create(...)`。验收 `apps/shader-m30/`（作者 GLSL ES 3.00 一对 → 2×2 四边形 → `drawToBitmapData` 读回）**15 项全 PASS**：中心 `#804020` = `uColor.rgb * 0.5` 逐位相符、3/8 处 `#361b0e` 证明 `vUV` 真的插值、反射表 `aPos,projectionMatrix,modelViewMatrix,uColor`，顶点译文含反射到的 `[[buffer(n)]]` 与后端要求的 `main0` 入口。**§8 红线**：同一份 `.as` 在默认构建/`adl` 下打印 `NO-CHANNEL` 并以 0 退出 —— `ShaderMaterial` 在没有 native 通道时**抛错**，不拿 AGAL 画一张「看着对的错误图」。另新增 `extra-roots` 清单字段（`asaot.three.NativeShaderRenderer` 只被字符串命名、闭包看不见它），闭包路径下确实被编译进去（65/123 sources）。**落地时暴露并修掉四个「编译过、结果错/空」**：feature 不带 shim/档案（链接期 `_asc_shader_translate` 未定义）、新类缺 `reflectFqn`（探测落空 ⇒ **静默退化成默认构建**）、`s3d_native_use` 立刻建管线而顶点流尚未绑定（Metal 拒「`aPos(0)` 不在顶点描述符里」）、`Context3DNative.drawTriangles` 绕过 `Context3D_submit`（顶点从没上传，**draw 编码了但什么都没画**）。余项：M4 Web 直通 / M5 D3D12 / M7 Ultra-Water 对齐。决策 D180–D186、R66–R70 见 `three-api-design.md` §37 |
| 原生通道能力矩阵（**M31**，2026-11-02） | ✅ `apps/shader-m31/` **13 项全 PASS**，把 FFT 海洋要吃的能力逐项钉死（每项都配一条能把「对/错」分开的可观测差值）：①32F/16F 渲染目标可渲可读（写 100.0 读回 100）；②**fp16 真的丢位**（`1+1/4096` 在 32F 读回 255、16F 读回 0）；③MRT 两附件分别读回（附件0 红/附件1 绿）；④`texelFetch` 读**非中心** texel 精确；⑤PCG `uvec2` 哈希（种子 1337/1338 → 255/177，走浮点上传会读到位模式）；⑥深度纹理**作附件**的遮挡（近处红写入→远处绿被拒→更近蓝通过，第三条是正对照）。**深度纹理不能当彩色采样器**：SPIRV-Cross 把 GLSL `sampler2D` 静态映射成 `texture2d<float>`，它不知道绑的是 `depth2d`，采样恒读 0——契约因此写成「深度=渲染附件」 |
| 第一片 FFT 海洋（**M32**，2026-11-02） | ✅ `apps/ocean-m32/` Tessendorf FFT：256² × 2 cascade（600 m / 85 m），风谱 `h0(k)` → 时间演化（bit-reversal 折进这一趟）→ 行/列 radix-2 DIT 各 8 级 → assemble（MRT 写位移+法线）→ 表面 pass（顶点纹理取值位移 + Fresnel/天空/太阳/泡沫），**34 pass/帧**跑 120 Hz。验收读回位移图极差 `-1.64..1.56 m`（spread 204/255，平面会是 0）。细档在自身 patch 外按距离淡出（原先 `clamp` ⇒ 海里一块「冻住的方格」）。**未做**：天空梯度/大气 LUT、caustics、水下 pass、喷雾、4 cascade、平面反射——与 Ultra-Water 的差距主要在第一项。缺陷与约束见 `three-api-design.md` §38 |
| 原生通道下游能力（**M33**，2026-11-02） | ✅ `apps/shader-m33/` **7 项全 PASS**，把 Ultra-Water 下游要吃的能力逐项钉死：①GLSL 辅助函数读写 uniform/结构体/采样器参数（r=21 g=148）；②`dFdx/dFdy`（编码后 `\|ddx\|*64=253`、`\|ddy\|*64=255`）；③加性混合累加（r=255/255 g=128/128，两帧叠加）；④`render(scene, camera)` 画进绑定的离屏目标；⑤离屏 walk 尊重相机视锥；⑥**`256x1024` 图集两个轴都不塌**（r=200/200 g=224/224）；⑦图集中心采样 == `texelFetch`（r=200 g=224） |
| Ultra-Water 全量对齐（**M34**，2026-11-02） | ✅ `apps/ocean-m34/` 把 Ultra-Water 的整条管线搬齐：4 级 FFT（600/85/12/2.1 m，各自独立 256² mip 链）、大气 LUT（transmittance + multiple-scattering + sky-view）、caustics、**平面反射**、不透明深度写进 alpha、**延迟水面**（采样不透明目标做折射 + Beer–Lambert）、spray、水下透镜/光柱、合成调色，**86 pass/帧**。7 条自检全 PASS（位移极差 `-10.0..10.0 m`、sky LUT `0.078..12.627`、反射 `0.078..10.0`、caustics `0.000..2.857`、水面覆盖 48.6%、光柱均值 0.0016、从下方 80.2% 底面）。**数值全绿之后另做了一轮视觉保真**：拿参考示例的浏览器截图按「地平线以下同相对区域」比对均值，抓出四个数值测不到的错——到 drawable 的 pass 漏了 sRGB 编码（中间调被整体压暗一倍）、天空反射照抄 1024 cube 的 LOD 公式落到 192x108 LUT 的最粗一级（暖色反射糊成灰）、`geoVar` 上界饱和让整片水同等粗糙（高光碎成白线）、海床沉到 -26 m 后红光被吃光（水体成黑板）。修完近场水色才对上参考的「浅潟湖沙底 + 金路」。**画面验收**靠新增的 `240x150` 十六进制帧转储（天空+云+岛+起伏海面），并由此抓出三个「画面全黑但不是渲染错」的陷阱：drawable 帧内读回是清屏色、`w.a > 0.5` 把「无水」tag 当水面、`inverse(mat4)` 在原生通道里让天空射线变 NaN。**采样器状态按 stage 分开**（`Context3DNative.setSamplerStateAtStage`，顶点 repeat 与片元 clamp 不再抢 unit 0）。详见 `three-api-design.md` §39 |

| Ultra-Water 收尾：着色器回到移植版 + 派发开销 + 60 Hz 封顶（**M34 续**，2026-11-03） | ✅ 三件互相独立、都以前一轮的真缺陷为依据的收口：①**着色器回到移植版**（D206）——上一轮的调色（反射 LOD、环境光乘子、`col *= 1.45`、SSS 项、final mix、glitter 掩码）是在 D204/D205 两个真缺陷还没修掉的画面上做的补偿，缺陷修完后整体撤回，连带撤掉为此新增的 `uSSS`/`uSkyView`/`uTime`/`uDebug` 与 `atmo_core`/`atmo_sky` 注入（保留会因两 stage 的 `precision highp sampler2D` 不一致而 link 失败）；`composite.frag` 只保留两处「写到哪里」的改动：唯一一处翻转与 drawable 的 sRGB OETF。②**CPU 100% 的根因是每 pass 25 µs 的动态派发**（D207）——`_native["setSamplerStateAtStage"](...)` 这种「Object 接收者 + 字符串名」的调用走 `as_dyn_call` 按名线性查表，实测 **25 µs**，把函数值存字段再调 **<0.5 µs**（50 倍）；一次 draw 6 次，于是 256² FFT pass 单 pass 200 µs 里只有 10 µs 是 Metal 编码，72 pass/帧 ⇒ 约 14 ms 纯派发。原生入口全部在构造期冻成字段后：单 pass 220→60 µs、`sim` 13.9→2.1 ms、帧 19–27→**4.6 ms**、33→**113 fps**。③**应用时钟封顶 60 Hz**（D209）——修完派发后 CPU 仍 83%，原因是宿主按 M16 设计把时钟同步到面板 120 Hz，一帧 4.6 ms 被要求一秒做 120 次；新增 `Stage3DApp.frameRateCap()`（默认 0 = 不封顶，`OceanM34` 返回 60）+ 纯函数 `capFrameRate(panel, cap)`（只能压不能抬），CPU **83% → 40%**、帧率 **59.9–60.2 fps**、帧间隔 p50/p95/p99 **16.8/17.7/18.0 ms**，与 Safari 里的参照页面（58 fps / 17.23 ms）同一节奏。回归 `tools/check-all-demos.sh` **58 个 demo 全 OK、0 失败**，`probes/apphost-smoke-m16/` 由 24 项扩到 **30 项 ALL PASS**。分歧 D206–D209、规则 R84–R87 见 `three-api-design.md` §39.11–§39.14 |
| 宿主 HUD + M34 控制面板（**M35**，2026-11-03） | ✅ 两件事，一件归宿主、一件归 demo：①**统计面板上提**（D210）——`Stage3DApp` 在 `createScene()` 之后自建 FPS/MS/MB/CALLS/TRIS 五块 HUD（`present` 之后更新，与 `afterFrame` 同一时序理由），子类用保护方法 `showStats():Boolean` 关掉（默认 `true`，目前只有主题就是 HUD 的 `stats-m15` 关），`frameDrawCalls()`/`frameTriangles()` 两个钩子让 demo 自己记账——M34 的帧里既有 `renderer.render()` 的场景也有一堆手工 `NativeShaderRenderer` pass（FFT 级联、反射、焦散、水面、合成），renderer 自报的计数器只看得见前者，实测 **76 CALLS（75–77）**。②**M34 控制面板按参照 lil-gui 分区重建**（D211–D214）——`CAMERA` / `SUN & SKY` / `WAVES` / `WATER` / `POST` 五段，单向数据流 `OceanPanelView`（asaotui 描述树）→ `OceanParams`（**作者单位**）→ 帧循环唯一的读者 `applyView()`/`applyParams()` → uniforms/bake/camera；太阳与云动一次重烘大气 LUT（`bakeAtmosphere()`），海况动一次重烘 JONSWAP 四路级联（`bakeSpectra()`），判定基准是「上次成功应用的值」而不是「与默认值不同」，所以拖动只在值真的动的那一帧重烘；便宜的量（吸收/散射/曝光/choppiness/泡沫）每帧直接推 uniform。六个命名视点与参照 `views` 逐行对应（Golden hour 3.5°/205°、Breakers 22°、Lagoon 52°、Open ocean 14°、Aerial 30°、Underwater 48°；`Flotsam` 不移植——那需要漂浮物几何，不是相机），视点是一次性快照、`view==0` 回到自动巡航。**关反射仍要绑采样器**：水面程序无条件采样 `uReflection`，Metal 里未绑定是校验失败而不是返回黑色，所以 `reflections=false` 时照样绑一张 1×1 黑贴图，跳过的只是整趟镜像渲染。不落（R88）：turbidity、岸线波浪、bloom/contrast/saturation/auto-exposure、质量与分辨率档——这些在移植版着色器里没有对应物，不做「拖了没反应」的假滑块。验收：窗口里真实鼠标事件驱动下拉/滑块/复选框/重置/折叠上屏；模型层 `probes/panel-params-m35/` **66 项 ALL PASS**（默认值 11 / 0..1 映射 7 / 21 个控件的按名双向映射与夹取 30 / 水色 8 / reset 4 / describe 4 / 未知名抛错 2），回归 `tools/check-all-demos.sh` **58 个 demo 全 OK、0 失败**，`apphost-smoke-m16` 30 项与 `stats-smoke-m15` 均 ALL PASS。分歧 D210–D214、规则 R88–R89 见 `three-api-design.md` §21.6/§39.15 |

> 数学库落地详情与每一条 three.js 出处见 `three-borrow-map.md` §1；API 形状见 `three-api-design.md`。

## 协作约定（开发者必读，2026-11-01 定稿）

> 这一节把这套代码**必须遵守的规矩**集中在一处。它是从 M21（AIR 参考运行通道）的实测教训里长出来的：
> 同一条规则在 AIR 上会变成黑屏 / 上传失败 / 整条 draw 被丢弃，而 AOT 侧一声不响地照跑——
> 「AOT 能跑」不构成正确性证据。工程细节（哪条指令、哪个错误号、哪次实测）记在 `three-api-design.md` §26，
> 本节只留**判断口径**，改代码前先看它。

### 1. 双后端对等：`能跑` ≠ `能编译`

- 每个 demo 的验收口径是**两个后端都能起窗出画**，截图 A/B 都要看；只 `mxmlc` 编译通过**不算完成**。
- 与 AIR 的差异**要么改掉，要么登记**（§26 → 本节第 6 条）。**禁止**「AOT 好使就这样」式的静默通过。

#### 1.1 节奏：**AOT 先行**，AIR 后置（2026-11-01 起）

> 这条只说**谁先谁后**，不改上面的判据。

- **迭代期唯一判据是「AOT 对着 three.js 参考」**：新功能/观感差异先用 AOT 侧证据定案——优先选
  **CPU 可算、可断言**的判据（解码锚点、方向→颜色映射、常量打包、纯函数表），其次才是上屏像素。
  判据是 `three-src/` 的算法与参考例程的数值，**不是**「看起来差不多」。
- **AIR 侧差异在迭代期只登记不修**：拿不到 AOT 侧解释的 AIR 分歧，先按本节第 6 条入册，
  继续往前推进框架；**不要**为了一个 AIR 差值停下功能开发。
- **收口期再把 AIR 清零**：发版前，登记在册的 AIR 差异必须逐条「改掉」或「判定为平台边界并报明」，
  口径不变。§1 的**底线**仍然成立——AIR 能跑而我们跑不出的，是遗留缺陷，不是增强。
- **为什么不双端并行推进**：AIR 侧取证通道比 AOT 慢且噪声大（32px 标题栏让 stage 尺寸不可比、
  `#1502` 长跑被掐、截图要过 Quartz 合成、`adl` 的 stdout 还是缓冲的），把每次改动都卡在双端
  比对，会把「写一个能力」变成「写一个能力 + 两套取证台」。而 AOT 是同源同算法的自家后端，
  对着参考值就能定案。**代价要在收口期一次付清**，不是取消这笔账。
- **当前唯一未解决的阻塞差异**：`adl` 会以 `#1502`（「script executed longer than 15 s」）
  在几秒内掐掉帧循环，根因未定（§7 与 `three-api-design.md` §26.11.6）。在它关掉之前，
  AIR 侧验收只覆盖「起窗 + 首帧/首秒正确」，**不能宣称长跑稳定**。

### 2. 构建入口：一个 demo 一个 `build.sh`

```bash
./apps/<demo>/build.sh          # 默认 aot
./apps/<demo>/build.sh air      # AIR 参考通道（mxmlc + adl）
./apps/<demo>/build.sh --run    # 构建后直接运行
```

- 实现只有一份：`tools/build-demo.sh`。`apps/<demo>/build.sh` 是薄入口（现在 20 个 demo 各一份）。
- **必须在仓库根跑**（相对资源路径与 `adl` 描述符解析都以此为基准）。
- **额外源根写在 `apps/<demo>/class-paths`**（每行一个，相对仓库根，`#` 起注释；缺文件 = 没有额外源根）：
  构建脚本把同一份清单喂给两端（AOT `--as-class-path`，AIR `-source-path+=`），
  所以「AOT 能编、AIR 缺类」在结构上不会发生。**`--as-class-path` 只对 `--air-app` 生效**（实测）。
- AIR SDK **靠发现、不靠硬编码**：`AIRSDK_HOME` → 常见安装路径 → `PATH` 上的 `mxmlc`/`adl`。
- AIR 侧固定用 `air-config.xml` + `frameworks/libs/air/airglobal.swc`，且 `-debug=true`（否则 `trace()` 不进 SWF）。
  `-compiler.strict=false` **只**用于「运行时确实存在、SWC 元数据滞后」的成员；缺 `import`、缺 `override` 必须改源码，不许靠宽松编译盖住。

#### 2.1 资源路径一律写 `app:/assets/...`

**不要写裸相对路径 `assets/foo.png`**（2026-11-01 起全部改掉）。裸相对路径在两端的落地基准
**不一样**：as-aot 按 **cwd** 解析，AIR 按 **SWF 所在目录**。结果就是「在仓库根跑一切正常，
双击可执行文件（cwd 为 `/`）就九个 ioError、随后每帧 `#1009` 洪水」——这不是渲染问题，
是路径语义问题。

`app:/` 是两端唯一拼写一致的锚点：as-aot 经 `as_local_path_from_url()` 落到 `as_app_dir()`
（可执行文件所在目录，见 `emit.ts`），AIR 落到 `applicationDirectory`（SWF 所在目录）。
配套：`tools/build-demo.sh` 在**每个后端产物旁边**建一个 `assets` 符号链接（AOT 建在可执行文件旁，
AIR 建在 SWF 旁），于是路径彻底与 cwd 无关。新增 demo 时照抄这套即可，不要再写裸相对路径。

#### 2.2 全部 demo 统一按增强模式构建（2026-11-02 起）

每个 `apps/<demo>/` 都有**两个**清单文件，二者缺一不可，否则拿到的是半增强构建：

| 文件 | 作用 | 缺了会怎样 |
|---|---|---|
| `features` = `native-shader` | 定义 `ASC_USE_NATIVE_SHADER=1`，注册 `Context3DNative`/`NativeProgram3D`，并链接 glslang + SPIRV-Cross | 默认构建：类根本不存在，`ShaderMaterial` 拒绝绘制 |
| `extra-roots` = `asaot.three.NativeShaderRenderer` | 把渲染器塞进 `--air-app` 可达闭包 | **有通道、没有渲染器**：`RendererFactory` 探测落空，静默退回 `AGALRenderer`，`describe()` 报 `native renderer=false` |

**为什么要 `extra-roots`**：`RendererFactory` 只能用 `getDefinitionByName("asaot.three.NativeShaderRenderer")`
探测（AS3 没有「类是否存在」的常量测试，静态引用在缺失时是 `#1046`/`#1065`），而**字符串不产生引用边**，
闭包看不见这个类。`shader-m30` 当初就踩过这个坑。

**代价（实测 `apps/rotating-cube`，它一行 GLSL 都不写）**：默认 7 643 440 B → 增强 12 495 744 B，
**+4.63 MB（+63%）**。原因是通道注册表从 `main` 可达，`-O2` 的调用图剪裁剪不掉它（§2.6 的
`static` 化只对**不可达**的函数有效）。所以「所有 demo 都增强」是**一致性换体积**的选择：
好处是任何 demo 都能直接跑 `ShaderMaterial`，代价是每个产物都驮着交叉编译器。
真正发布时可以只给写 GLSL 的 demo 保留这两个文件。

**行为不变的证据**（不是「看着一样」）：`m26-parity` 走 `NativeShaderRenderer` 与走 `AGALRenderer`
读回的 4 行 `PARITY` 统计**逐位相同**（`35.5/22.62/82.29`、`22.17/19.07/29.93`、`32.65/16/84.36`、
`20.76/17.07/28.86`）；`scene-m20`、`geometry-m11` 的整份日志逐字相同。`NativeShaderRenderer`
`extends AGALRenderer` 且**不覆写**标准绘制路径，所以 AGAL 材质原样走老路。

**AIR 侧完全不受影响**：`tools/build-demo.sh` 的 `build_air` 从不读这两个文件，`adl` 拿到的仍是默认
构建，`shader-m30`/`shader-m31` 依旧打印 `NO-CHANNEL` 并以 0 退出（§8 红线）。

**回退时必须清两处**：`--air-app` 会把 `features` **写进** `<Main>.build.json` 并在下次构建时沿用
（会打 `enhancements carried over from ...` 警告）。只删 `features` 文件**不足以**关掉它——
要么连 `<Main>.build.json` 一起删，要么用 `--features none`。


### 3. profile 与 AGAL 版本是**一对**决策

- 入口：`stage.stage3Ds[0].requestContext3D("auto", "enhanced")`；渲染器：`AGALRenderer.AGAL_VERSION = 4`。
- 两侧必须同时改。矩阵实测（`adl` 51.4.1，逐 profile × 版本二分）：**AGAL4 只在 `enhanced` 下合法**；
  `standardExtended` 到 v3 封顶，`standard` 只到 v2，`baseline*` 连 v2 都拒。
- 用 AGAL2+（`vc40+`/`fc36+`/3 位属性）的程序**必须**按版本 2 以上汇编，v1 的操作数上限是 28 且**汇编失败是静默的 0 字节**。

### 4. AGAL 合法性**以 AIR 为准**

AIR 的校验严格得多：程序在 AOT 下能画、在 AIR 下会**上传失败整帧黑**或**整条 draw 被丢**。这几条已经收敛进装配器（`AGALMiniAssembler`），
发射端不要再各自打补丁；新增发射点时要**假定**它们在：

| 规则 | AIR 表现 | 我们的处置 |
|---|---|---|
| 两个源操作数都是常量 | `#3625` 拒绝上传 | `hoistConstantOperands` 提前搬进空闲临时寄存器（同常量只搬一次） |
| 单源算术（`rcp/rsq/sqt/frc/nrm/abs/neg/sat/exp/log/sin/cos`）吃常量源 | `#3625`（文案误导，实为「常量源」） | 同上；`mov` 是唯一例外 |
| 输出寄存器 `oc`/`od` 被多条指令拼写 | `#3701` | 必须一条指令写满（`oc.w` 也要写） |
| `kil`/`if*` 源无显式标量 swizzle | `#3703` | 写 `kil ftN.xxxx` |
| 某个 varying 只写一部分分量 | `#3633` | 多次写可以，但四次写入要合起来覆盖 `xyzw` |
| mipfilter 字符串写成 `"none"` | `#2008` | 用 `"mipnone"`；无 mip 链的槽**必须**显式关 mip |
| 立方体贴图只上传 level 0 | `#3700` 整条 draw 被丢 | 上传**整条** mip 链（`uploadCubeChain`） |
| 顶点流 / 采样器与程序声明不一致 | `#3607` / `#3697` | 按程序声明绑定与解绑，不要「反正都绑上」 |

### 5. 性能口径：**AOT 最优优先**，CPU 预算优于无意义 GPU 指令

- 有取舍时以 **AOT 的性能**为准；若某个常量算式在 GPU 上要么非法（见上表）要么更贵，就**搬到 CPU 预算**（例：线框程序的
  `1/halfViewport`、雾的 `1/(far-near)`）。这类搬移把两条指令换成一条乘法，两端都更快也更合法。
- **但预算出来的常量必须真的上传，而且必须有钉子**：`fc37.w` 漏填过一次，雾在两端同时消失、所有探针仍全绿。
  所以每个「CPU 预备 / GPU 消费」的常量都要有一条探针把打包与实际读数对上（`linearFogScale` + `packFogConstants`）。
- 允许用 `Capabilities.manufacturer` 保留 AOT 更优路径再在 AIR 降级——但那是**显式降级**：要有探测、有测试、有文档。

### 6. 增强字段 / AIR 缺失 API 的访问方式

- as-aot 增强字段（如 `VsyncStateChangeAvailabilityEvent.refreshRate`）在 AIR 里不存在：**动态下标 + 兜包**。
  ```as3
  try { if (e["refreshRate"]) stage.frameRate = e["refreshRate"]; }
  catch (err:Error) { }
  ```
  禁止静态访问（AIR 会抛 `#1069` 或编译期找不到）。
- AIR 里**不存在**的方法不要引入（例：`setCubeTextureAt`——Adobe 的 `setTextureAt` 本就收 `TextureBase`，
  as-aot 把它窄化成 `Texture` 才逼出那个假扩展）；正确做法是把 as-aot 的声明**改成与 AIR 一致**。
- 未支持的能力一律**报明**（一次性诊断 + 文档），不许静默降级。

### 7. 调试纪律

- **要看的日志一律走 `flash.system.System.output()`，不要靠 `trace()`**
  （[System 文档](https://airsdk.dev/reference/actionscript/3.0/flash/system/System.html#output())）：
  `adl` 在 macOS **既不转发 `trace()`、也不打印未捕获错误**，而 `System.output()` 真到 stdout。
  实测（AIR 51.4.1 / macOS arm64）同一段输出的两端字节完全一致：AOT 侧是
  `as_system_output`（`fputs` + `fflush`），AIR 侧走同一 stdout，所以**一套日志格式覆盖两个后端**。
  它**不自己补换行**，要换行就自己写 `\n`：
  ```as3
  import flash.system.System;
  ...
  private function logLine(s:String):void { System.output(s + "\n"); }
  ```
  `Stage3DApp` 的宿主级诊断（`ready` / `resize` / `display Hz` / `frame error` + 堆栈）已全部走这条通道，
  因此**AIR 起的窗口可以直接用 `grep` 判读**，不必再截屏看标题。
- **同一条日志不要同时走 `trace()` 和 `System.output()`**：as-aot 的 `trace` 也写 stdout，会打出两遍。
  `Stage3DApp.logLine()` 是宿主与 19 个 demo 共用的唯一出口，新增日志就用它（或自己的
  `System.output`），不要再新开 `trace`。
- 窗口标题（`render error: …`）只作**第二通道**保留：stdout 被启动器吞掉时它还在，回归脚本也读它。
- **AIR 侧定位 GPU 错误先开 `enableErrorChecking = true`**
  （[Context3D 文档](https://airsdk.dev/reference/actionscript/3.0/flash/display3D/Context3D.html#enableErrorChecking)）：
  它把每个 draw 的校验都过一遍，能一次问出「哪条 AGAL / 哪个槽位 / 哪个流」不合格。
  **它是软件级校验、极慢**，定位完必须关掉再谈性能与帧时间。
- **判读前先结束进程再读日志**：`adl` 的 stdout 是缓冲的（实测同一次运行 419 B → `kill` 后
  1158 B）。「日志还没出来」很容易被当成「没有日志」。
- **`#1502` 不是 App Nap，根因未定**（旧结论已修正）：窗口在屏内/屏外/前台/后台、
  `-debug=true`/`false`、`<scriptTimeLimit>0|3` 都试过，结果一样；纯 `ENTER_FRAME` 计数的
  极简探针能跑满 30 s，而我们重负载的 demo 几秒内就抛（文案固定写「15 seconds」）。
  **这是当前唯一的双后端阻塞遗留**（`three-api-design.md` §26.11.6，含实测矩阵与下一步），
  不是渲染错误，**不要**靠降 `frameRate` 掩盖。
- `adl` 有时把窗口丢到屏幕工作区之外（实测 `position = (747, -969)`）：此时 `refresh` 为 0、
  帧率停在 60、截图也拿不到画面。判读前先读一次窗口坐标并 `set position` 归位。
- 临时插桩（`trace`/标题/计数/计时）**不得进最终证据**，收尾统一清。

### 8. UI 层：`asaotui` **就地链接**，座位固定「HUD 左上 / 面板右侧」

- **不复制**：`asaotui` 是并列 checkout，源根写在 `apps/<demo>/class-paths`
  （`../asaotui/seam`、`../asaotui/kit`）。复制一份就是分叉：控件修一次要改两处，而副本会静默落后。
- **座位**：`Stats` HUD 默认**左上**（`margin=8`）；控制面板固定 `300px` 贴右缘、全高；中间 3D 不被遮挡。
  两边都靠 `justifyContent: "flex-end"` / `alignAt` 描述，**不算绝对 x**，resize 时不需要重算。
- **单写者**：widget 只改 `PanelState`，**帧循环的 `applyState()` 是唯一写**
  `Scene`/`Light`/`Material`/`AGALRenderer` 的地方。禁止在控件回调里直接改场景——那正是 M20 雾 bug 的形状
  （两处都能写同一个值 ⇒ 「面板显示 34」与「shader 拿到 15」可以同时成立）。
- **窗口尺寸语义两端不同**（D142）：同一描述符 `1200×900`，AOT 的 stage 是 `1200×900`，
  AIR 的是 `1200×868`（含 32px 标题栏）。**跨端像素比对前先对齐 stage 尺寸**（读 `Stage3DApp ready: WxH`），
  否则差的是透视投影而不是渲染。

## 下一步

1. ~~浅克隆 three.js 源码到 `three-src/`~~ ✅（r187，`src/` 共 757 个 `.js`）。
2. ~~写 API 设计草案（`three-api-design.md`），再回填 borrow-map 的「借了」行~~ ✅。
3. **数学库 → 场景图 → 几何层 → 材质/灯光 → `AGALRenderer`** 全部落地 ✅。**M1 收官**：旋转立方体上屏（`apps/rotating-cube/`）。
   **M2 收官** ✅：`MeshStandardMaterial` PBR + GGX + `map` 纹理，PBR 立方体上屏（`apps/pbr-cube/`）。
   **M3 收官** ✅：`Loader` 接口 + `ObjectLoader`，JSON 场景加载并渲染（`apps/loader-scene/`）。
   **M4 收官** ✅：PBR 贴图族真采样 + 导数 TBN，三贴图立方体上屏（`apps/texture-maps/`）。
   **M5 收官** ✅：`FileLoader`/`ImageLoader`/`TextureLoader` + suzanne 磁盘加载，冒烟 8 节全绿 + 上屏验收 ✅。
   **M6 收官** ✅：`PointLight`/`SpotLight` + 渲染器多光逐光 additive pass（含 Frostbite 距离衰减 + 聚光锥角），三光源 demo 上屏验收 ✅（`apps/light-m6/`）。
   **M7 收官** ✅：`DirectionalLightShadow` + 深度 prepass 阴影，立方体投阴影 demo 上屏验收 ✅（`apps/shadow-m7/`）。
   **M8 收官** ✅：`GLTFLoader`（glTF 2.0 / GLB）落地，Duck.glb + DamagedHelmet.gltf 同屏上屏验收 ✅（`apps/gltf-m8/`）。
   **M9 收官** ✅：环境贴图 IBL（`CubeTexture` + `CubeTextureLoader` + `Scene.environment` + fs7 cube 采样），金属球粗糙度扫描仅由环境光照明上屏验收 ✅（`apps/env-m9/`）。
   **M10 收官** ✅：渲染质量（色调映射 ACESFilmic + 透明混合/alphaTest + 4x MSAA），镂空面板 + 三层重叠玻璃 + 过曝球三组 A/B 上屏验收 ✅（`apps/alpha-m10/`）。
   **M11 收官** ✅：几何族（Cylinder/Cone/Torus/Lathe/Tube/Circle/Ring/Edges）+ 曲线扫掠 + 线框 + `mergeGeometries` + 视锥剔除，七几何画廊与线框盒上屏验收 ✅（`apps/geometry-m11/`）。
   **M12 收官** ✅：动画核心（五种插值器 + glTF CUBICSPLINE）+ `Bone`/`Skeleton`/`SkinnedMesh` **CPU 蒙皮** + morph targets，6 骨节鞭 + 形变球 + 旋转方块三条轨道同屏，逐帧观测对照上屏验收 ✅（`apps/animation-m12/`）。
   **M13 收官** ✅：阴影质量（PCF 九抽头 + `normalBias` + 16 位深度打包 + 镂空 caster + `castShadow`/`receiveShadow` 真生效），环面投影 + 镂空薄板同屏，A/B 半影与 acne 两组量化对照上屏验收 ✅（`apps/shadow-m13/`）。
   **M14 收官** ✅：交互（`Ray`/`Raycaster`/`Mesh.raycast` 拾取 + `OrbitControls` 轨道相机 + Stage 事件桥），点击高亮 / 左拖绕行 / 滚轮缩放 / 右键平移四手势由真实系统鼠标事件驱动上屏验收 ✅（`apps/interaction-m14/`）。
   **M16 收官** ✅：应用宿主（`Stage3DApp`：显示刷新率同步到面板最大 Hz + 窗口 resize 重建 back buffer/投影），15 个 demo 收编为一个基类，120 Hz 起窗与三种窗口尺寸变化的上屏验收 ✅（`apps/*`、`probes/apphost-smoke-m16/`）。
   **M17 收官** ✅：纹理状态真生效（`wrapS/wrapT`、`minFilter/magFilter`、`generateMipmaps`+CPU mip 链、`flipY`、`colorSpace` sRGB 解码变体、`Scene.background`），修掉「字段在、渲染器不读」的静默失效与颜色贴图的**双重 gamma**，五面片判据式 demo + 51 项探针 + flipY 与颜色空间两组 A/B 上屏验收 ✅（`apps/texstate-m17/`、`probes/texstate-smoke-m17/`）。
   **M18 收官** ✅：UV 变换真生效（`offset`/`repeat`/`rotation`/`center`/`matrix`，六个贴图槽各一套，顶点 `dp4` 两行常量 + `vc40..vc51`），六面片共用同一几何 uv 的判据式 demo + 39 项探针，B/C/D/E/F 五个面片各有可测数字（4 格接缝 / 半张位移 / 中心不动 / 逐点镜像 / 三次重复）上屏验收 ✅（`apps/uv-m18/`、`probes/uv-smoke-m18/`）。
   **M19 收官** ✅：渲染状态真生效（`side`/`depthTest`/`depthWrite`/`blending`/`renderOrder`/`flatShading`/`wireframe`），唯一肉眼可见的 `DoubleSide` 失效修好，九面板 A/B + 59 项探针 + 像素级回归上屏验收 ✅（`apps/renderstate-m19/`、`probes/renderstate-smoke-m19/`）。
   **M15 收官** ✅：性能 HUD（借 three.js 例程里的 `stats.module.js`：80×48 面板 / 74×30 滚动图 / FPS·MS·MB 三页 + 自建 CALLS·TRIS），默认**右上角**、点一下翻页、在面板上拖拽不转相机，五页轮换与真实鼠标事件驱动的 A/B 上屏验收 ✅（`apps/stats-m15/`）。
   **M20 收官** ✅：四条「字段在、渲染器不读」的最后遗留（不透明材质的混合门禁 / 阴影剪隐藏子树 / `drawRange` 参与绘制 / `MeshBasicMaterial.map`）+ `Scene.fog` + `Scene.background` 三态，九组判据一屏 + 56 项探针上屏验收 ✅（`apps/scene-m20/`、`probes/scene-smoke-m20/`）。
   **M24 收官** ✅：UI 层接入 + 布局约定。`Stats` 默认锚点改**左上**（右侧让给控制面板）、面板 `300px` 贴右、
   `asaotui` 经 `class-paths` **就地链接**（不复制），数据流收成「widget → `PanelState` → 帧循环单写者」。
   demo `apps/panel-m24/` 八控件全部由真实鼠标事件驱动验收（线框/阴影/雾开关、Far 滑杆 34→15、左上 `stats x=8`），
   AOT 120 fps / `calls=5` 不变，AIR 196 KB SWF 起窗同形。顺带登记两端**窗口尺寸语义差异**（D142/R56）：
   跨端像素比对必须先对齐 stage 尺寸。three.js 三个例程（walk / lightprobe / gltf）的缺口审计与
   M25–M27 排期也写进 `three-api-design.md` §28：**HDR 环境光**（M25，观感差距主因）→
   **骨骼可视化 + 键盘 + 交叉淡入**（M26）→ **LightProbe 球谐光照**（M27）。
   **M26 收官** ✅：`webgl_animation_walk` 整例程搬成 demo `apps/walk-m26/`（方向键/WASD 走、Shift 跑、H 开关骨骼线、左拖绕轨道），三处新增各自收敛成一条可钉的形状——宿主 `keys` 桥（按下表 + 一帧边沿 + 失焦清表）、`AnimationAction` 的 crossFade/warp/sync、线段程序的顶点色变体。**下一步（M25）开工前必须先做的两件事**：
   1. ~~先给 AOT↔AIR 的**环境贴图观感差异**定性~~ ✅ **已完成**：根因是编译器 AGAL 逐分量展开造成的
      **读后写别名**（不是 cube 朝向、也不是 sRGB 编解码），已在 `as3compiler` 侧修复并沉淀为阶段三百四十六
      （`agal_mask_clobber`/`agal_snap_src`，见 `three-api-design.md` §29.5，证据链 `apps/cubeface-m25/` +
      `examples/stage346.as` + 单元钉子 + 全量 4664 PASS）。还剩一条**与它无关**的分歧：`walk-m26` 本体在
      `metalnessMap = map` 下 AOT 比 AIR 暗 ≈0.6x（地板逐点一致），已登记 §29.6，做法是先做最小复现
      `examples/stage347.as` 再逐条 AGAL 对齐——M25 的 HDR 不必等它，但收口时要一起验。
   2. AIR `#1502` 的间歇长帧（新栈落在 `SkinnedMesh._skinIntoAttributes()` ← 阴影 prepass）按 §26.11.6 的 (1)(2) 两步量：`getTimer()` 对墙钟、`updateDeform` 单帧耗时。它决定 AIR 侧能不能做长跑举证。
   **M21 收官** ✅：AIR 参考通道真正跑起来。`apps/<demo>/build.sh`（`aot` 默认 / `air`）经 `tools/build-demo.sh` 一份实现驱动 19 个 demo；AIR 侧 `mxmlc` 用 `air-config.xml` + `airglobal.swc`，**19/19 demo 双端编译 + 双端起窗、零错误**，`scene-m20` 双端截图像素一致。对齐的硬规则：**AGAL v4 ⇄ `enhanced` profile 是一对**（矩阵实测 v4 只在 `enhanced` 合法）、常量源操作数必须装配期消解（`#3625`，`AGALMiniAssembler` 新增 `validateAirOperands`/`hoistConstantOperands`）、顶点流与采样器必须与当前程序**精确一致**（`#3607`/`#3697`）、立方体贴图必须上传**整条** mip 链（`#3700`，并纠正 `createTexture` 第 4 参数是 `optimizeForRenderToTexture` 不是 mip 开关）。顺手修掉 AIR 才暴露的真缺陷：`TextureLoader.load` 协变返回（基类改不声明 `load`）、`StatsPanel` 遮蔽 `DisplayObject.name`、若干缺 `override` 与单文件多包级类。编译器侧 `as_agal_translate` 接受 v4、预算 400，新增钉子 `stage3d/agal-versions`，全量 **589/589** 绿；`probes/` **24/24 组、1044 项 0 FAIL**（6 组跑各自 `.build.json` 的 skia 解码）。分歧 D133–D137、规则 R46–R53 见 `three-api-design.md` §26。**M21 回归（M22 修）**：把雾的「两常量相减 + `rcp`」换成 CPU 预算的 `1/(far-near)` 时，**漏了把它上传到 `fc37.w`**（还是 0），线性雾在**两端同时彻底失效**——画面看起来就是「加了 AIR 之后光影变弱了」，而探针全绿（`fogFactorAt` 是它自己的算术，与 shader 不共代码）。现收敛成 `AGALRenderer.linearFogScale()` + `packFogConstants()` 两个纯函数（CPU 镜像、上传、shader 共用一套），加 9 条钉子（`probes/scene-smoke-m20/` C17–C25），双端截图像素复核：雾带远端棕色回归、`env-m9` 与 M20 逐像素 0.00% 差异（证明其余部位无回归）。**另：HDR 不是差异源**——AOT 的 Metal glue 全程 `MTLPixelFormatBGRA8Unorm`（颜色附件 / RTT / cube 全是 8 位），从来就没有 float 渲染目标，所以不存在「AOT 有 HDR、AIR 降级」这回事。

## 路线图（M4–M27，2026-11-01 更新）

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M4 · PBR 贴图族** ✅ | `normalMap`（+`normalScale`）/`roughnessMap`/`metalnessMap` 真采样；单 AGAL2 程序 + 1x1 中性纹理；导数 TBN（R8）；`BufferGeometry.computeTangents` | 新 demo 上屏 ✅（`apps/texture-maps/` 三立方体：鼓包/条纹/金属盘） |
| **M5 · 外部资产通路** ✅ | `FileLoader`（通用字节/文本 + path 前缀）+ `ImageLoader` + `TextureLoader`（字节→BitmapData→Texture）+ `ObjectLoader.parseGeometry`（裸几何 JSON）+ `computeVertexNormals` + R9 缺属性默认缓冲 | 冒烟 8 节全绿 ✅（真 suzanne 505 顶点 + 像素断言）；demo `apps/asset-load/` 磁盘加载 suzanne JSON + PNG 贴图，上屏验收 ✅（黑背景 + suzanne + 棋盘格立方体） |
| **M6 · 灯光族扩展** ✅ | `PointLight`（distance/decay）+ `SpotLight`；渲染器多光逐光 pass；物理衰减 | 点光衰减 + 多灯 demo 上屏 ✅（`apps/light-m6/` 方向光/红点光/白聚光三光源 additive，右白左红+顶高光+地面光斑） |
| **M7 · 阴影** ✅ | `DirectionalLightShadow`：深度 prepass render-to-texture（深度存颜色，R11 式）+ 主 pass 采样比较（硬阴影） | 立方体在平面上投阴影 ✅（`apps/shadow-m7/`） |
| **M8 · GLTF 资产通路** ✅ | `GLTFLoader`（借 r187 `examples/jsm/loaders/GLTFLoader.js`，5006 行）：GLB/glTF 2.0 核心解析管线——GLB 信封（JSON/BIN chunk）、buffer/bufferView/accessor（6 分量类型 + 小端 + normalized + sparse）、交错 bufferView 解析时去步长、TRIANGLES/STRIP/FAN → `BufferGeometry`、材质 `pbrMetallicRoughness` → `MeshStandardMaterial`（baseColor/metallicRoughness/normal/emissive 因子 + emissiveTexture/occlusionTexture；alphaMode → transparent/opacity；doubleSided → side）+ unlit → `MeshBasicMaterial`、纹理/图像（bufferView 内嵌 + 外部 + data URI，Skia 解码；sampler → wrap/filter；flipY=false）、节点 TRS/matrix、`PerspectiveCamera`/`OrthographicCamera`、KHR_lights_punctual（依赖 M6）。不落：Draco/meshopt/basisu 压缩、skins、animations、morph targets（逐条登记遗留） | r187 现成模型上屏 ✅：Duck.glb + DamagedHelmet.gltf 同屏（`apps/gltf-m8/`）；冒烟 46 项全 PASS |
| **M9 · 环境贴图 IBL** ✅ | `CubeTexture`（六面 `BitmapData`，+X/-X/+Y/-Y/+Z/-Z）+ `CubeTextureLoader`（六图异步填面、末面单次 `onLoad`）+ `MeshStandardMaterial.envMap`/`envMapIntensity` + `Scene.environment`；`AGALRenderer` 新增 fs7 cube 采样：漫反射 irradiance（法线 N 处一采，与 `AmbientLight` 合并后再过 AO）+ 镜面反射 `reflect(-V,N)`、`mix(R,N,r²)`，以及粗糙度向 irradiance 的 prefilter 替代 + Karis `EnvBRDFApprox`（不采 BRDF_LUT）；无 env 时绑 8×8 中性白 cube 且 `envMapIntensity=0`，**不新增程序变体**。不落：PMREM 预卷积链、`DataTexture`、天空盒（`scene.background` 贴图） | 五金属球粗糙度扫描仅由环境贴图照明 ✅（`apps/env-m9/`）；A/B：去掉 `scene.environment` 后整排纯黑 |
| **M10 · 渲染质量** ✅ | `AGALRenderer.toneMapping`（`NoToneMapping`/`LinearToneMapping`/`ACESFilmicToneMapping`，常量与顺序逐条对齐 r187 `tonemapping_pars_fragment.glsl.js`）+ `toneMappingExposure`；材质 `alphaTest` 新字段，`transparent`/`opacity`/`depthWrite` 由「只有 API 形状」变为真生效——透明物体单独 pass，按相机平方距离**远到近**插入排序，`sourceAlpha`/`oneMinusSourceAlpha`、关深度写，opaque 仍先画；`alphaTest` 编译成 `sub`+`kil`（硬切，AGAL 无 `fwidth`）；glTF `alphaMode` 三态分别落到 `alphaTest`/`transparent`+`depthWrite`/无。AGAL1 指令 cap 200→400。Metal 后端 4x MSAA（`ASC_S3D_MSAA=4` opt-in，RTT/阴影 pass 恒单采样）。不落：`scene.background` 天空盒、`WireframeGeometry`、逐物体 `renderOrder` | 镂空 alphaTest 面板 + 三层重叠玻璃 + 过曝球上屏 ✅（`apps/alpha-m10/`）；三组 A/B（色调映射 / 排序方向 / alphaTest 开关）均可肉眼判定；冒烟 32 项全 PASS |
| **M11 · 几何族 + 剔除** ✅ | `CylinderGeometry`/`ConeGeometry`/`TorusGeometry`/`CircleGeometry`/`RingGeometry`/`LatheGeometry`/`TubeGeometry`/`EdgesGeometry` + `LineSegments`/`LineBasicMaterial`（Stage3D 无线图元 ⇒ 顶点程序屏幕空间扩展）+ `Curve`/`CatmullRomCurve3`/`FrenetFrames` + `mergeGeometries`；`Plane`/`Frustum` 视锥剔除 + `object.frustumCulled`；顺带修阴影采样越界守卫 | 几何族画廊 + 线框盒 + 40 个屏外盒上屏 ✅（`apps/geometry-m11/`：`drawCalls=17 / triangles=5428 / culled=40` 稳定；`DRAW_EDGES` 与 `FRUSTUM_CULLING` 两组常量 A/B）；冒烟 103 项 ALL PASS |
| **M12 · 动画 / 蒙皮 / 形变** ✅ | `AnimationClip`/`KeyframeTrack`（Number/Vector/Quaternion/Color/Boolean）× `AnimationMixer`/`AnimationAction` × `PropertyBinding`/`PropertyMixer`，五种插值器（Discrete/Linear/QuaternionLinear/Cubic + glTF CUBICSPLINE 2303）；`Bone`/`Skeleton`/`SkinnedMesh` **CPU 蒙皮** + `Mesh` morph targets；`GLTFLoader` 扩 `skins`/`animations`/`JOINTS_0`/`WEIGHTS_0`/`targets` | 6 骨节鞭 + 形变球 + 旋转方块上屏 ✅（`apps/animation-m12/`：位置/四元数/形变权重三条轨道同时驱动，`skinChecksum` 865.991↔1061.9015、形变半径 0.72↔1.36，`bindChecksum` 不变）；冒烟 110 项 ALL PASS；分歧 D66–D87、R22 见 §17 |
| **M13 · 阴影质量** ✅ | PCF 3×3 九抽头（`LightShadow.radius` 语义 = texel 半径，`fc27..fc35` 静态偏移 + `fc24` 核）+ `normalBias`（顶点沿世界法线推开接收点）与 `bias` 符号（`z += bias`，正 bias 制造 acne）+ **16 位两字节深度打包**（`hi=floor(d·255)/255`、`lo=frac(d·255)`，`dp3` 解包）+ `castShadow` 过滤 caster / `receiveShadow` 走 `vc22`→`v5` varying 混合 + `alphaTest` 镂空 caster（`shadowDepthKind`）；编译期 AGSL 校验（R23）与顶点临时寄存器整写规则（R24）。**红线**：采样槽 `fs0..fs7` 占满 ⇒ 一 draw 只能一张阴影图（D93），第二盏方向光能亮不投影；多光源阴影**不做** | 环面投影 + 镂空薄板同屏 ✅（`apps/shadow-m13/`：A/B 半影 0%→19.3%、错误自阴影 34.5%→2.6%、镂空投影 4 窗透光）；冒烟 47 项 ALL PASS；指令 300/400；分歧 D88–D93、R23–R24 见 §18 |
| **M14 · 交互** ✅ | `Ray`（`at`/`recast`/球·平面·盒·三角求交，watertight 共享边）+ `Raycaster`（透视/正交 `setFromCamera`、递归遍历、**稳定**距离排序）+ `Mesh.raycast`（世界包围球早退 → 逆矩阵进局部 → 局部 AABB → `drawRange` 逐三角 → `side` 绕序（`BackSide` 反绕序）→ 重心插值 uv/normal → 世界距离 + `near`/`far`）+ `Pointer` 的 AIR 像素→NDC 桥 + `OrbitControls`（rotate/dolly/pan 状态机、极角·方位·距离夹取、damping、正交 zoom、`saveState/reset`）+ `Camera.updateProjectionMatrix` 基类声明（R25）。不落：hover 拾取、`layers`/`params`、Line/Points/SkinnedMesh 拾取、多材质 groups、触摸/键盘控制 | 四手势上屏 ✅（`apps/interaction-m14/`：点击绿盒/环面命中日志、271px 拖拽明确不拾取、滚轮拉近、右键平移）；冒烟 110 项 ALL PASS；指令不变 300/400；分歧 D94–D100、R25–R26 见 §19 |
| **M15 · 性能 HUD** ✅ | `Stats`（stats.js 的 `begin`/`end`/`update` 时钟：MS 每帧归一化 200、FPS 每 1000ms 归一化 100、MB 每秒）+ `StatsPanel`（80×48 面板、9px 标签、74×30 图列缓冲、min/max 终生单调）+ 点击翻页 + 锚定（`Stats.anchorX` 纯函数，随 `Event.RESIZE` 重锚）+ `stopPropagation` 的鼠标截断（R27）。不落：`Stats.dom`、`devicePixelRatio` 缩放、`renderer.info` 整体移植、面板拖拽/透明度调节 | 5 页轮换 + HUD 上拖拽不转相机 + 开/关 HUD 帧时间对照，全部由真实系统鼠标事件驱动上屏 ✅（`apps/stats-m15/`）；冒烟 76 项 ALL PASS；指令预算不变 163/400、300/400；分歧 D101–D104、R27 见 §20。历史上默认**右上**，**M24 起改为左上**（`alignAt`，D139）——右侧要留给控制面板 |
| **M16 · 应用宿主** ✅ | `Stage3DApp`（`seam/asaot/three/app/`）：`NO_SCALE`+`TOP_LEFT` 的 stage 配置、`vsyncEnabled=true`、`VsyncStateChangeAvailabilityEvent` → `stage.frameRate`（`frameRateForRefresh` 归一，未知不写；`frameRateCap()` 的上限经 `capFrameRate` 只压不抬，D209）、`Event.RESIZE` → `renderer.setSize` + 透视 `aspect`/`updateProjectionMatrix` + `onViewportResize` 钩子、`ENTER_FRAME` 的 `updateFrame → render → present → afterFrame` 定序、`renderer`/`refreshRate` 只读访问器。不落：显示器刷新率探测（AIR 无 API）、每帧 resize 轮询、`scaleMode` 变体、`contentsScale` 变化、正交相机自动 refit、多窗口宿主 | 15 个 demo 全部 `extends Stage3DApp` 后重编起窗 ✅（15/15 `frameRate=120 refresh=120`）；stat 面板/交互/立方体三种 resize 上屏验收（HUD 重锚、射线仍准、画面不拉伸）；冒烟 30 项 ALL PASS；指令预算不变；分歧 D105–D108、D209、R28、R87 见 §21/§39.13 |
| **M18 · UV 变换** ✅ | `Texture.offset/repeat/rotation/center/matrix/matrixAutoUpdate` + `updateMatrix()` + `Matrix3.setUvTransform`（r187 公式）；顶点程序新增 16 条指令（12 `dp4` + 4 `mov`）把 `va2` 变换成六个槽的 varying，常量 `vc40..vc51`（每槽两行 `(m00,m10,0,m20)`/`(m01,m11,0,m21)`，仿射靠 `FLOAT_2` 默认 `w=1` 收尾，R32）；片元各槽改读自己的 varying，法线贴图 uv 移到 `v2.zw` 且切线帧导数同源（R33）；alpha 镂空 caster 的阴影程序只传 `vc40`/`vc41` 走同一变换。不落：`texture.channel` 多 UV 集、`envMap` 的 UV 变换 | 六面片共用同一几何 uv 上屏 ✅（`apps/uv-m18/`：B 接缝 25.5/50.5/75.5%、C 接缝 50.5%、D 中心像素不变、E 与 A 逐点镜像、F 三组采样原样重复三次）；冒烟 39 项 ALL PASS；片元指令不变（163/400、300/400）；分歧 D115–D118、R32–R34 见 §23 |
| **M20 · 静默失效收官 + 场景雾 / 背景** ✅ | ①不透明材质的 `NormalBlending` 门禁（`transparent=false` + `opacity<1` 不再画成半透明；不透明 draw 也不再走「读目标缓冲」的 ROP 路径，D126）；②阴影 pass 在**递归之前**剪 `visible=false` 的子树（藏起来的组不再投影，D127）；③`geometry.drawRange` 成为渲染约束（`drawTriangles` 的偏移/个数；索引单位、三角形对齐、容量夹取；主 pass 与 caster pass 同一对函数，D128）；④`MeshBasicMaterial.map`（`map_fragment` 的 `diffuseColor *= texel` 连 alpha 一起乘 ⇒ glTF `KHR_materials_unlit` 的 `baseColorTexture` 不再被丢，D129）；⑤`Scene.fog`（`Fog`/`FogExp2` 逐片元 mix，常量 `fc37..fc40`，无 `smoothstep`/`exp2` 故手写 `clamp→t²(3-2t)` 与自然 `exp`，**只加在 base pass**，`Material.fog` 逐材质 opt-out，D130/R40/R41）；⑥`Scene.background`（`Color` 清屏 / `CubeTexture` 天空盒 / 2D `Texture` 全屏四边形；sRGB 背景贴图的 decode 变体**跳过色调映射**，D131/R42）。**顺带修掉两个后端级缺陷**：Metal pass 在「本帧有 depth/stencil clear」时必须强制挂深度附件——否则全屏 `depthCompare="always"` 的背景四边形会丢掉整帧深度清除，这正是 M20 blend 面板「看不见背后」的真根因（R43）+ MSAA 路径补 depth-stencil 附件；**AGAL 用到 `vc40+`/`fc36+` 的程序必须按版本 2 汇编**（默认 v1 的操作数上限 28，且汇编失败是**静默的 0 字节**，运行时才炸 `AGAL: bytecode too short for header`，R44）。不落：`RenderTarget`/`VideoTexture`/多层背景、线框与线段不加雾、`drawRange` 与 `geometry.groups` 的组合、`MeshBasicMaterial.map` 的 UV 变换 | 九组判据一屏上屏 ✅（`apps/scene-m20/`：A/B 条纹 vs 纯灰 `(127,127,127)`、D 纯粉 `(235,72,113)` 不透 vs E 混色 `(147,162,132)`、F `150 of 200 triangles` 阶梯缺口、G 上条远端染雾棕而下条全程蓝、H 左墙阴影覆盖 15.89% vs 右墙 0.00%、2D 棋盘背景与 cube 天空盒两张截图）；冒烟 **56 项 ALL PASS**（A 混合门禁 9 / B `drawRange` 14 / C 雾模式与因子 16 / D 雾默认值 7 / E 场景与材质默认值 9）；指令 163/400 不变、阴影 + 雾 **256/400（+15）**；19 个 demo 重编起窗全绿、24 组探针 **1060 项 PASS / 0 FAIL**；Starling 基准 31,344 对象 ~120fps 无异常；分歧 D126–D132、R40–R45 见 §25 |
| **M19 · 渲染状态** ✅ | `Material.side` → `setCulling`（反序映射：后端 CW 正面 vs three.js CCW）、`depthTest`/`depthWrite` → `setDepthTest` 两半边（`depthTest=false` 兼关写）、`blending` 五模式 → `setBlendFactors`（`CustomBlending` 降级 + 诊断）、`Object3D.renderOrder` → 两张列表首排序键、`flatShading` → 位置导数的面法线（+1 指令）、`wireframe` → 三角形边展开成屏幕空间四边形（复用 M11 线段程序）。不落：`depthFunc`/`colorWrite`/`stencilWrite`/`polygonOffset`/`alphaToCoverage`、`CustomBlending` 因子、`groupOrder` 分桶、线框光照与去重、阴影 `shadowSide` 翻转 | 九面板 A/B 上屏 ✅（`apps/renderstate-m19/`：A 只剩背景 vs B 板在、C/D 远绿盖近红、E 三种混合亮度可测、F `renderOrder` 压过遍历序、G/H 平直切面、I 线框球）；冒烟 59 项 ALL PASS；指令 163/400 不变（flat 变体 164）；分歧 D119–D124、R35–R39 见 §24 |
| **M24 · UI 层接入 + 布局约定** ✅ | `Stats` 默认锚点右上→**左上**（`alignAt: "left"|"right"`，非法值抛错、默认值写字符串字面量）、`anchorFor(align, stageWidth, margin)` 纯函数随 `RESIZE` 重锚；控制面板 `300px` 贴右缘全高、根节点 `justifyContent: "flex-end"` 描述而不是绝对 x；`apps/<demo>/class-paths` → `tools/build-demo.sh` 同一份源根清单喂两端（AOT `--as-class-path`、AIR `-source-path+=`），`asaotui` **就地链接不复制**；数据流单写者（widget → `PanelState` → 帧循环 `applyState()`）。不落：面板拖拽/折叠/持久化、主题切换 UI、`Stage` 键盘桥（归 M26） | 八控件由 Quartz 真实鼠标事件驱动上屏 ✅（`apps/panel-m24/`：`stats x=8 panelW=300`、线框 `wireframe=true`、关阴影+关雾、Far 34→15、120 fps / `calls=5` / `tris=50`）；AIR 196,498 B SWF 起窗同形；冒烟 `stats-smoke-m15` F 节 10 项（全套 81 项）ALL PASS；两端窗口尺寸语义差异登记为 D142/R56；分歧 D139–D142、R56–R58 见 §27 |
| **M25 · HDR 环境光** ✅ | `.hdr`（Radiance RGBE：平铺/旧 RLE/新 RLE + `±X`/`±Y`/`EXPOSURE`）**与 `.exr`（OpenEXR：NONE/RLE、HALF/FLOAT，D167–D169）** → `HDRImage` → `EquirectangularToCube` **CPU 烘焙**六面（cube 无 float/mip 存储，D152/§36.2）→ 8 位**伽马编码的线性辐照度** + `CubeTexture.hdrScale` 还原（D154）→ `scene.environment`/`scene.background`/`backgroundIntensity`/`backgroundBlurriness`/`environmentIntensity`；背景变体 `_bgCubeProgramHdr{,Blur,Blur9}`（`blurTapsFor` 按 `blurriness` 选 0/5/9 tap，D156），标准片元不变。不落：PMREM 预卷积链（N4）、ZIP/PIZ/PXR24/B44/DWA 压缩（按名拒绝）、`backgroundBlurriness` 的 LOD 语义、烘焙线程化 | 冒烟 `probes/hdr-smoke-m25/` **69 项 ALL PASS**（RGBE 锚点 / 六面朝向与经度镜像 / 三种扫描线 / 拒绝 xyze 与非 HDR / 编码与 `hdrScale` 互逆 / `autoScale` 分位 / 模糊分档 / EXR 两档压缩 + 五种拒绝）；demo `apps/hdr-m25/` 单张 HDR 照明五球 + 七个按键（含 `.hdr` ↔ `.exr` 换源），AOT 日志 `bake 128px in 17ms, autoScale=64, hdrScale=64`；**M25-R1 预滤波阶梯**已由 §35（D174/D175/D178）补齐：6 档 CPU 粗糙度 cube + `fs7` 按 `material.roughness` 选档 + `PrefilterJob` 分帧烘焙，仍**不是** PMREM/mip LOD；分歧 D152–D169、D174–D179、N4 见 §30/§33/§35 |
| **M26 · 骨骼可视化 + 键盘 + 交叉淡入** ✅ | `SkeletonHelper`（+`setColors`，复用 M11 线段程序 + 顶点色变体）、`Stage3DApp.keys` 键盘桥（按下表 + 一帧边沿 + `DEACTIVATE` 清表）、`AnimationAction.crossFadeTo/From/syncWith/warp/halt` | `Soldier.glb` 走/跑由**真实按键**切换并交叉淡入（含 warp 速率）、骨骼线可见 ✅（`apps/walk-m26/`）；`probes/anim-smoke-m26/` **59 项 ALL PASS**；分歧 D143–D151、R59–R62 见 §29 |
| **M27 · LightProbe** ✅ | `SphericalHarmonics3`（二阶级数，r187 的三组六位小数基常数）+ `LightProbe`（`intensity`/`version`）+ `LightProbeGenerator.fromCubeTexture`（立体角权重归一到 `4π` 的 SH9 投影）/`toIrradianceCube`（**CPU 烘 16×16 irradiance cube，纹素存 `E/π`**，D176） | 探针 SH9 **不在片元里求值**：忠实实现约 40 条 AGAL，而标准片元已到 `308/400` 且 `fs0..fs7` 满员（D175/D176）⇒ 渲染器把求过和的 irradiance 绑到 `fs7`，只在 `probe`/`version` 变化时重烘；探针与环境抢同一槽 ⇒ **有环境就用环境、探针被忽略并只警告一次**。`probes/lightprobe-smoke-m27/` **36 项 ALL PASS**（常数环境 `E = πL`、方向性环境对暴力余弦积分 +Y 0.7% / +X 2.3%、`E/π` 与 sRGB 往返、四种拒绝路径）；分歧 D176 见 §35.4 |
> 前提（2026-10-31 确认）：AGAL2/3/4 profile 完整支持——贴图/多光/阴影的寄存器与指令预算不再受限；
> 指令 cap 已在 M10 按 AGAL1 基线上调到 400（`as3compiler/src/runtime.ts` 的 `agal_instr ins[400]`），
> 超出时仍按 profile 提升。web 目标暂缓（移出路线图）。
>
> **MSAA 是 opt-in**：`ASC_S3D_MSAA=2|4` 才开，默认 1（Air 等价路径）。RTT（阴影 prepass、`drawToBitmapData`）
> 恒单采样，`resolve` 在帧末一次性完成（Metal 无 blit resolve，走零 draw 的 `MultisampleResolve` pass）。
