# WaterWave (URP 2D Water Algorithm Showcase)

这个仓库用于**算法验证与展示**，不是可直接运行的 Unity 工程。

## 包含内容

- `Shaders/Water/WaterSurface.shader`
  - 面向 URP 2D 的水面渲染 Shader。
  - 包含：
    - Tilemap 边界参数映射（`_WaterBoundsMin/_WaterBoundsMax`）
    - 基于世界单位的边缘深度淡出（`_DepthEdgeFadeWorld`）
    - 边界淡出遮罩（`_BoundsFade`）
    - 低开销程序噪波波浪（FBM）+ 波场 RT 混合
    - 手动平面反射：按屏幕高度镜像上方场景并支持 UV 扰动（仅镜像该高度以上场景内容）
    - 2D 反射默认依赖 `CameraSortingLayerTexture`（`_CameraOpaqueTexture` 仅兼容回退）
    - **基于 Voronoi + 噪波的参数化焦散模拟（不使用 LUT，深水区域保留弱焦散）**
    - 焦散亮线基于 Voronoi 距离高值区域，避免亮暗反相
    - 可选低质量关键字 `WATER_LOW_QUALITY`
    - 可选回退关键字 `WATER_REFLECT_OPAQUE_FALLBACK`（仅在 Sorting Layer Texture 不可用时使用）
    - 反射控制参数：`_ReflectionHeight/_ReflectionDistort/_ReflectionEdgeFade`
- `Shaders/Water/WaterSimulation.compute`
  - 轻量 2D 波方程传播 Compute Shader。
  - 包含：
    - `CSWavePropagate`：波传播 + 阻尼 + 水域遮罩约束
    - `CSAddImpulse`：向波场注入扰动（点击/碰撞）
- `Scripts/Water/WaterSimulationDriver.cs`
  - `ExecuteAlways` 驱动脚本，支持在 Editor 非运行状态预览水面（可开关）。
  - 运行模式与编辑器模式分离，避免影响 Play 模式行为。

## 建议接入方式（在你的 Unity 项目中）

1. 在运行时/编辑器中从 Tilemap 计算世界空间边界。
2. 将边界传入材质参数：
   - `_WaterBoundsMin`
   - `_WaterBoundsMax`
3. 使用 `_DepthEdgeFadeWorld`（世界单位，例如 `0.8`）统一控制左右/上边界浅水过渡距离。
4. 在 URP 2D Renderer 中开启 **Camera Sorting Layer Texture**，以提供 2D 反射采样源。
5. 将 tilemap 占用区域烘焙到 `_WaterMaskRT`，作为 Compute 的水域约束。
6. 每帧执行 `CSWavePropagate`，把 `_WaveHeightRT` 绑定到 `WaterSurface.shader` 的 `_WaveRT`。
7. 交互时（点击、落物、角色入水）执行 `CSAddImpulse` 注入扰动。
8. 如需在编辑器预览（非 Play）：
   - 将 `WaterSimulationDriver` 挂到水面对象
   - 绑定 `ComputeShader` 与水面 `Renderer`
   - 勾选 `Preview In Edit Mode`
9. 按平台调节：
   - 降低波场 RT 分辨率
   - 启用 `WATER_LOW_QUALITY`
   - 调整 `_ReflectionDistort` 与 `_ReflectionEdgeFade` 平衡表现/稳定性

## 说明

为保持仓库轻量，本仓库不包含 Unity 项目文件（`Assets/`, `ProjectSettings/`, `Packages/`）。
