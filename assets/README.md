# asaot3d 测试资产（assets/）

> 本目录只放**回归测试资产**，不放产品美术。

## models/

| 文件 | 来源 | 许可说明 |
|---|---|---|
| `suzanne_buffergeometry.json` | three.js 仓库 r187 `examples/models/json/suzanne_buffergeometry.json`（MIT），io_three 导出格式，505 顶点 position+index | 猴头模型源自 Blender（GPL）的测试模型；本文件只作几何回归测试数据，不进入产品发行物 |
| `WaltHeadLo_buffergeometry.json` | 同上路径（MIT），BufferGeometry.toJSON 格式 4.5（约 5k 顶点，含 uuid/type 顶层字段） | 经典 three.js 测试头部模型；同上只作测试数据 |
| `suzanne-scene.json` | `tools/make-suzanne-scene.js` 生成：把裸几何包成 ObjectLoader 场景信封（format 4.5），uuid 由脚本分配 | 生成产物，随脚本重跑可复现 |
| `gltf/Duck.glb` | Khronos glTF-Sample-Models `2.0/Duck/glTF-Binary/Duck.glb`（120484 B）；模型来自 Sony Computer Entertainment，**CC BY 4.0**（见同目录来源注释） | 二进制 GLB：1 个 mesh / 1 个材质 / 1 张 baseColor 贴图（bufferView 内嵌 PNG）+ 采样器 minFilter 9986；节点带 0.01 等比缩放矩阵 |
| `gltf/DamagedHelmet/DamagedHelmet.gltf` + `.bin` + 5 张 JPEG | Khronos glTF-Sample-Models `2.0/DamagedHelmet/glTF/`；模型 by theblueturtle_，**CC BY-NC 4.0**（仅作本地回归测试数据，不进入任何发行物） | 外部 `.bin`（558504 B）+ 外部贴图：baseColor / metallicRoughness / normal / occlusion / emissive；节点 rotation = +90° 绕 X（Z-up 资产转 Y-up） |
| `textures/cube/SwedishRoyalCastle/{px,nx,py,ny,pz,nz}.jpg` | three.js 仓库 r187 `examples/textures/cube/SwedishRoyalCastle/`（MIT，6 张 512×512 JPEG，按 +X/-X/+Y/-Y/+Z/-Z 命名）；照片内容为瑞典皇家城堡，仅作 IBL 回归测试数据 | 六面立方体环境贴图（M9）：`CubeTextureLoader` 直接吃这六个文件名 |
| （data URI 最小用例） | 不落盘：`probes/gltf-smoke-m8/gltf-smoke-m8.as` 内联构造 | 内嵌 ushort 索引 + float 位置、无 NORMAL（钉 `computeVertexNormals` 兜底）与 `data:` buffer 解码通路 |

## textures/

| 文件 | 来源 |
|---|---|
| `checker.png` / `uvgrid.png` / `bead-normal.png` | `tools/gen-png.js` 生成（node 内置 zlib，零依赖）：棋盘格 / RGB 渐变 / 圆拱法线贴图。全部自产，无第三方许可问题 |

## 下载与再生成

```sh
# 模型（three.js r187）
curl -sL -o assets/models/suzanne_buffergeometry.json \
  https://raw.githubusercontent.com/mrdoob/three.js/r187/examples/models/json/suzanne_buffergeometry.json
curl -sL -o assets/models/WaltHeadLo_buffergeometry.json \
  https://raw.githubusercontent.com/mrdoob/three.js/r187/examples/models/json/WaltHeadLo_buffergeometry.json

# glTF 样本（M8）
mkdir -p assets/models/gltf/DamagedHelmet
curl -sL -o assets/models/gltf/Duck.glb \
  https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/main/2.0/Duck/glTF-Binary/Duck.glb
for f in DamagedHelmet.gltf DamagedHelmet.bin Default_albedo.jpg \
         Default_metalRoughness.jpg Default_normal.jpg Default_AO.jpg Default_emissive.jpg; do
  curl -sL -o "assets/models/gltf/DamagedHelmet/$f" \
    "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/main/2.0/DamagedHelmet/glTF/$f"
done

# 立方体环境贴图（M9）
mkdir -p assets/textures/cube/SwedishRoyalCastle
for f in px nx py ny pz nz; do
  curl -sL -o "assets/textures/cube/SwedishRoyalCastle/$f.jpg" \
    "https://raw.githubusercontent.com/mrdoob/three.js/r187/examples/textures/cube/SwedishRoyalCastle/$f.jpg"
done

# 贴图与场景打包
node tools/gen-png.js
node tools/make-suzanne-scene.js
```

## 运行时路径约定

demo/探针从仓库根（`asaot3d/`）运行，加载器用相对路径（`assets/models/...`），
依赖进程 CWD = 仓库根。构建清单里的路径相对清单文件自身目录解析，与此无关。
