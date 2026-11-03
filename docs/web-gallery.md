# 浏览器 gallery：把 asaot3d 的每个 demo 编成网页

> 一句话：`tools/build-web.cjs` 把 `apps/` 里的每个 demo 编成 `site/<dir>/index.html`，
> `tools/gen-gallery.cjs` 生成左侧列表 + `<iframe>` 的集合页，`tools/verify-web.cjs`
> 在真浏览器里逐个上屏核对，`tools/publish-web.sh` 推到 `gh-pages`。
>
> 线上地址：**https://raygyoe.github.io/as3compiler-asaot3d/**（`gh-pages` 分支，孤儿提交，
> 每次发布整体替换）。

## 1. 目录与命令

| 工具 | 职责 |
|---|---|
| `tools/web-demos.json` | **目录表**：分组、标题、一句话说明；`nativeOnly` 标记只能跑原生的 demo（见 §4） |
| `tools/build-web.cjs` | 逐 demo 编译（`--target wasm --package web`）、裁剪资产、注入字体、汇总 `site/demos.json`，末尾自动调 gallery |
| `tools/gen-gallery.cjs` | 只读 `site/demos.json` → `site/index.html`（左列表 / iframe 切换 / `#hash` 路由 / 键盘上下 / 搜索） |
| `tools/verify-web.cjs` | 起静态服务器 + 自带无头 Chrome，逐页读 `__ascStdout`/`__ascErrors` 并截图 |
| `tools/serve-web.cjs` | 本地预览（`.wasm` 的 MIME 是 `application/wasm`，见 §5） |
| `tools/publish-web.sh` | 把 `site/` 作为一个 orphan 提交推到 `gh-pages` |

```bash
export EMSDK_HOME=../build-tools/emsdk      # 相对写法可以，脚本会自己 resolve 成绝对路径
node tools/build-web.cjs                 # 全部 -> site/（--jobs 4 默认；--only a,b 只编几个）
node tools/serve-web.cjs                 # http://127.0.0.1:8990/
node tools/verify-web.cjs --shots         # 29 页逐个上屏 + 截图到 temp/web-shots/
tools/publish-web.sh --no-build          # 推 gh-pages（--dry-run 只准备提交）
```

`site/` 是**构建产物**（约 260 MB wasm），已被 `.gitignore` 排除；发布走 `gh-pages` 分支，
不进 main 的历史。

### iframe 永远铺满 stage，只等比缩放 demo 自己的 canvas

gallery 里 `<iframe>` 恒为 `100% × 100%`（可用面积的最大值），被缩放的是**demo 页面里的
`<canvas>`**：按 `canvas.width/height`（物理像素，含 DPR）等比缩到 `min(fw/w, fh/h)`，允许超过 1
（放大时把 `image-rendering` 从 `pixelated` 换成 `auto`，缩小时保持原样）。理由有两层：

1. **缩放 frame 会让页面跑在一个不存在的视口里**。demo 页是 `body { min-height: 100vh;
   display: flex }` + 固定逻辑尺寸的 canvas，把 frame 设成 1200×900 再 `transform: scale()`
   之后，页面量到的视口和真实 stage 无关，指针坐标也得二次换算。
2. **量尺的时机不能靠猜**。`web_glue` 是在 `main()` 里给 canvas 写内联 CSS 尺寸的；此前
   gallery 在 `load + 700ms` 量一次就定死，而 3–10 MB 的 wasm 加字体 fetch 经常比 700ms 长，
   于是量到的是 HTML 默认 300×150，frame 被钉成那个大小且再也不重算——**切换 demo 后窗口很小，
   手动刷新（命中缓存、`main()` 赢得竞赛）才变大**。现在用 `ResizeObserver` 盯 canvas，并在
   `load` 后再补两次幂等的重算；`canvas.style.width` 还没被写入时一律不量（那是加载中的默认态）。

### `EMSDK_HOME` 必须按绝对路径交给 emcc

脚本第一件事就是把 `EMSDK_HOME` resolve 成绝对路径，看着多余，其实是踩出来的：emcc 把
「SDK 根 + 版本」记在自己的 cache 里做 sanity 比对，`../build-tools/emsdk` 与解析后的绝对路径
**指向同一处却拼写不同**，它判定「配置变了」→ 清缓存 + 重写 sanity 戳。并发时就变成四个子进程
轮流清对方正在写的缓存，emcc 在最后一条 warning 之后**以非零码退出但不打任何 error**：一次
`--jobs 4` 全量构建全 FAIL，日志尾部还停在一句普通的 `-Wparentheses-equality` 上。
现在传相对路径也不会再触发（脚本自己转绝对），但手敲 emcc 时仍然要注意这一点。

## 2. 为什么每个 demo 都拷一份到 `temp/web-app/<dir>/`

`--air-app` 会把**整个 app 目录**打进页面的虚拟文件系统（浏览器没有 `app:/assets/...` 那种
目录，只能靠打包）。打包是目录粒度的，就地编译会把 `assets/` 的 8 MB 全塞进**每个** `.data`
——其中 6.9 MB 的模型只有两个 demo 读。所以 `build-web.cjs` 先拷一份「描述符 + src/ + 这个
demo 真正点名的资产」到 `temp/web-app/<dir>/` 再编：

- `site/` 里每个 demo 的 `.data` 只在几百 KB 到 3 MB（`asset-load`/`gltf-m8` 例外，它们本来就要大资产）；
- 生成的 `.c`、构建清单、wasm 中间产物都落在 `temp/`，源目录保持干净（`[no-src-litter]` 同口径）。

资产清单是**按源码里的字符串字面量**扫出来的（`assets/...`），这是一个静态近似，所以：
`//` 注释先被剥掉（`walk-m26` 曾因为一句「拷进 assets/ 以免跑歪」的注释把整棵资产树打进 `.data`），
而**裁剪是否裁过头由运行期证明**——`verify-web.cjs` 会把 `ioError` / `#2032` / `cannot load`
当作失败（§5）。

## 3. 字体：每个页面都会 fetch 一次 `../fonts/Arial.ttf`

wasm 沙箱里没有系统字体，`TextField`（每个 demo 的 stats HUD、M24/M34 的 asaotui 面板标签）
不注入字节就是**空白文字**，而空白文字不会让任何构建失败。`build-web.cjs` 因此改写生成页里的
`var FONT_URLS = [...];`（断言这个模式存在，避免发射器改名后静默失效），字体在站点根目录只放一份。

## 4. 29/29：`native-shader` 的 WebGL2 直通臂

本文件早先在这里写着「M30/M31/M32/M33/M34 五个 demo 不能在浏览器上跑，因为 WebGL2 侧的通道尚未实现」。
**那条判定是错的，已于 2026-11-03 撤回。** 作者写的是 GLSL ES 3.00 源语言，而 GLSL ES 3.00 正是 WebGL2
的原生着色语言；把它 `GLSL → SPIR-V → MSL` 再放进浏览器，绕的是我们自己的弯。现在：

| | 原生（Metal） | 浏览器（WebGL2） |
|---|---|---|
| 编译链 | glslang → SPIR-V → SPIRV-Cross → MSL | 直接 `glCompileShader`（ES 3.00） |
| 链接工具库 | `vendor/glslang` + `vendor/SPIRV-Cross` | **不链接**（wasm 里没有它们） |
| 反射 | SPIRV-Cross 资源列表 | 驱动：链接后 program 上的 `glGetActiveUniform` |

`nativeOnly` 字段因此**一个都不剩**，目录表里 29 条全部可玩。规矩没变：哪天真有跑不了的 demo，仍然
写进 `nativeOnly` 并写明原因（AGENTS.md §1.5：宁可列出来说「为什么不行」，也不许静默少几行）。细节
（槽位按 (kind, stage) 编号、unit 在两 stage 之间不重叠、`glFrontFace` 必须翻转）见编译器文档
`as3compiler/docs/zh-cn/native-shader.md` §6.11。

**这次开通道时抓到三个「编译过、结果错」**，都只在 WebGL2 出现，记在这里因为它们是这条通道的常识：

1. **渲染目标登记表写死 32 项**（`S3DRtTex rtTex[32]`）。WebGL2 拿不到 `glGetTexLevelParameteriv`（ES 3.1
   才有），FBO 尺寸只能靠这张表反查；32 项一满就**静默不登记**，之后每个目标都用**屏幕尺寸**建 FBO ⇒
   viewport 大四倍、LUT 烘成常数、整幅黑。改成可增长的 `realloc` 表（失败也不吞，打一行）。
2. **采样器槽位跨 kind 连续编号** ⇒ 采样器落到 slot 8..10，超出采样器表；加上绑定循环按 AGAL 的 8 个
   纹理寄存器遍历，`ocean-m32` 的 10 个采样器有 2 个永远不绑。两个都修了（按 (kind, stage) 编号；
   循环到 `S3D_MAX_NATIVE_TEX = 16`，并按「本程序声明了哪些 slot」绑，未绑的采样器读到黑色而不是上一帧
   的残留贴图）。
3. **正面朝向要翻转而不是补全剔除模式**：AGAL 顶点级取反裁剪空间 Y，原生程序不取反，同一批三角形绕序
   相反。补全 cull 模式能救回画面，但 `gl_FrontFacing` 还是反的 —— `ocean-m34` 的水面 pass 把每个片元
   判成「水面下侧」。`glFrontFace(nativeMode ? GL_CW : GL_CCW)` 一行解决两件事。

## 5. 验收口径：构建绿色 ≠ 页面上屏

wasm 页面在运行期失败的样子是**一块黑画布**：构建绿灯、HTTP 200、每一个字节都送达，控制台之外
没有任何东西抗议。所以 `verify-web.cjs` 同时看四件事：

| 信号 | 失败判据 |
|---|---|
| `window.__ascErrors` | 页面级未捕获错误 / 未处理 rejection |
| `window.__ascStdout` | 页面的 `trace()` 全部落到这里；一行都没有 = `main()` 没跑到 |
| `Stage3DApp frame error:` | 运行期画家错误（着色器编译失败就是走这条，见 §6） |
| 截图（`--shots`） | 解码 PNG 做颜色普查，少于 3 种颜色 = 空白页 |
| 页面自报结论 | stdout 里出现 `FAIL`/`FAILED` 行 = 失败，**页面加载成功不算通过** |

外加 `ioError` / `#2032` / `cannot load` 等加载失败文案。

**最后一行是关键**：每个 demo 跑完都会自己下结论（`... OK` / `PASS ...` 或 `FAILED (n check(s))` /
`FAIL ...`）。只验「页面加载 + 有 stdout」会让一个自检红的 demo 停在 PASS 列 —— `shader-m33`（导数写进
了被读回着色器覆盖掉的 alpha）与 `ocean-m34`（水面覆盖 0%）都这样漏过网。现在 `verify-web.cjs` 把页面
里的 `FAIL` 行当作失败，并把它们原样打出来。

**它自带浏览器**：早期版本借用「系统里任何一个开了 DevTools 端口的 Chrome」，结果是受制于别人的
标签页状态——实测能无限挂住（某个 demo 卡住主线程时 `Runtime.evaluate` 永远不回，而无超时的
Promise 就一直等）。现在 `launchOwnChrome()` 用一次性 profile 起 `--headless=new`、端口 0（问
系统要），并**给每个 CDP 调用加超时**，跑完 kill 掉；`--cdp PORT` 才是显式借用。

## 6. ES 1.00 → ES 3.00：一次真实的黑画布 bug

第一轮 24 页全 PASS（stdout 正常、无异常），但截图里 `pbr-cube`/`gltf-m8`/`panel-m24` 的画布是
纯黑的。原因不在引擎，而在 AGAL→GLSL 的发射器：它按 **ES 1.00** 发射，遇到 `ddx`/`ddy` 就写
`#extension GL_OES_standard_derivatives : enable`。在 WebGL2 上下文里这个扩展**已经升为核心特性**，
没有可 enable 的东西：

```
WARNING: 0:1: 'GL_OES_standard_derivatives' : extension is not supported
ERROR: 0:51: 'dFdx' : no matching overloaded function found
```

于是每个用到导数的片元程序每帧编译失败，页面照旧打印 650 行正常日志。修法是把 GLSL 目标整体
升到 `#version 300 es`（导数与 `gl_InstanceID` 都在核心里，WebGL2 原生编译这一版）：

| ES 1.00 | ES 3.00 |
|---|---|
| `attribute` / `varying` | `in` / `out`（片元侧 `in`） |
| `texture2D` / `textureCube` / `*Lod` | `texture` / `textureLod` |
| `gl_FragColor` | 声明 `out vec4 as_outColor;` |
| `gl_FragDepthEXT` + `GL_EXT_frag_depth` | `gl_FragDepth`（核心，无扩展） |

`iid` 仍然在 GLSL 目标上被**拒绝**：`gl_InstanceID` 是 `int`，而 AGAL 的 `iid` 是广播成
`float4` 的寄存器，GL 侧这条广播还没接（拒绝时说清原因，而不是发射出一个驱动编不过的标识符）。

回归钉子同步改到新形态：`test/unit/stage3d.ts` 的 dialect 隔离组、`examples/stage80.as`、
`examples/vertex-texture.as`。

## 7. 体积与发布

- 每个 demo 一份 wasm，**约 8 MB**（Skia + 运行时静态链进来），整站约 210 MB。
  GitHub Pages 单站上限 1 GB、单文件 100 MB，现在都在线内；首屏只加载被选中的那一个 demo。
- 页面之间共享的只有 `fonts/Arial.ttf` 与 `index.html`，没有公共 wasm 可切——每个 demo 编译
  不同的代码，链接期没法合并（`static` 化 + dead-strip 已经把不可达的剪掉了）。
- 首次发布后需要在仓库 **Settings → Pages → Source: Deploy from a branch → `gh-pages` / (root)**
  点一次；之后每次 `tools/publish-web.sh` 只推一个 orphan 提交。