# 浏览器 gallery：把 asaot3d 的每个 demo 编成网页

> 一句话：`tools/build-web.cjs` 把 `apps/` 里的每个 demo 编成 `site/<dir>/index.html`，
> `tools/gen-gallery.cjs` 生成左侧列表 + `<iframe>` 的集合页，`tools/verify-web.cjs`
> 在真浏览器里逐个上屏核对，`tools/publish-web.sh` 推到 `gh-pages`。

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
node tools/verify-web.cjs --shots         # 24 页逐个上屏 + 截图到 temp/web-shots/
tools/publish-web.sh --no-build          # 推 gh-pages（--dry-run 只准备提交）
```

`site/` 是**构建产物**（约 210 MB wasm），已被 `.gitignore` 排除；发布走 `gh-pages` 分支，
不进 main 的历史。

### `EMSDK_HOME` 必须按绝对路径交给 emcc

脚本第一件事就是把 `EMSDK_HOME` resolve 成绝对路径，看着多余，其实是踩出来的：emcc 把
「SDK 根 + 版本」记在自己的 cache 里做 sanity 比对，`../build-tools/emsdk` 与解析后的绝对路径
**指向同一处却拼写不同**，它判定「配置变了」→ 清缓存 + 重写 sanity 戳。并发时就变成四个子进程
轮流清对方正在写的缓存，emcc 在最后一条 warning 之后**以非零码退出但不打任何 error**：一次
`--jobs 4` 全量构建 24/24 全 FAIL，日志尾部还停在一句普通的 `-Wparentheses-equality` 上。
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

## 4. `nativeOnly`：五个 demo 为什么不在这个站上

`web-demos.json` 里 M30/M31/M32/M33/M34 标了 `nativeOnly`：

```
绘制走 Context3DNative（GLSL ES 3.00 → SPIR-V → MSL）；WebGL2 侧的通道尚未实现
```

这不是「顺手砍掉」：`--features native-shader` 与 `--target wasm` 的组合会被编译器直接**拒绝**
（`src/build.ts` 有明确的门）。目录表里保留它们并写明原因，gallery 里也照样列出、点开显示这段
说明——访问者应当看到「这个 demo 存在、为什么不在浏览器上」，而不是默默少五条（AGENTS.md §1.5）。

## 5. 验收口径：构建绿色 ≠ 页面上屏

wasm 页面在运行期失败的样子是**一块黑画布**：构建绿灯、HTTP 200、每一个字节都送达，控制台之外
没有任何东西抗议。所以 `verify-web.cjs` 同时看四件事：

| 信号 | 失败判据 |
|---|---|
| `window.__ascErrors` | 页面级未捕获错误 / 未处理 rejection |
| `window.__ascStdout` | 页面的 `trace()` 全部落到这里；一行都没有 = `main()` 没跑到 |
| `Stage3DApp frame error:` | 运行期画家错误（着色器编译失败就是走这条，见 §6） |
| 截图（`--shots`） | 解码 PNG 做颜色普查，少于 3 种颜色 = 空白页 |

外加 `ioError` / `#2032` / `cannot load` 等加载失败文案。

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