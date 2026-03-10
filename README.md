# WaterWave (URP 2D Water Algorithm Showcase)

这个仓库用于**算法验证与展示**，不是可直接运行的 Unity 工程。

## 包含内容

- `Shaders/Water/WaterSurface.shader`
  - 面向 URP 2D 的水面渲染 Shader。
  - 包含：
    - Tilemap 边界参数映射（`_WaterBoundsMin/_WaterBoundsMax`）
    - 基于世界单位的边缘深度淡出（`_DepthEdgeFadeWorld`）
    - 边界淡出遮罩（`_BoundsFade`）
    - 低开销程序噪波波浪（FBM）
    - 反射改为直接采样外部输入的 `Reflection RT`，并按波浪法线进行 UV 扭曲
    - **基于 Voronoi + 噪波的参数化焦散模拟（不使用 LUT，深水区域保留弱焦散）**
    - 可选低质量关键字 `WATER_LOW_QUALITY`
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
4. 由相机输出一张 RT，并将其作为材质 `_ReflectionRT` 输入（Shader 不负责相机引用与位置校正）。
5. （可选，若仍使用波场 Compute）将 tilemap 占用区域烘焙到 `_WaterMaskRT`，作为水域约束。
6. （可选）交互时（点击、落物、角色入水）执行 `CSAddImpulse` 注入扰动。
7. 如需在编辑器预览（非 Play）：
   - 将 `WaterSimulationDriver` 挂到水面对象
   - 绑定 `ComputeShader` 与水面 `Renderer`
   - 勾选 `Preview In Edit Mode`
8. 按平台调节：
   - 降低波场 RT 分辨率
   - 启用 `WATER_LOW_QUALITY`
   - 调整 `_ReflectionDistort` 与 `_ReflectionStrength` 平衡表现/稳定性

## 说明

为保持仓库轻量，本仓库不包含 Unity 项目文件（`Assets/`, `ProjectSettings/`, `Packages/`）。
