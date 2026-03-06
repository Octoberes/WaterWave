using UnityEngine;

#if UNITY_EDITOR
using UnityEditor;
#endif

namespace WaterWave
{
    /// <summary>
    /// 驱动水体 Compute 模拟，并将结果绑定到目标材质。
    /// 通过 ExecuteAlways 支持编辑器预览，同时不改变 Play 模式行为。
    /// </summary>
    [ExecuteAlways]
    public class WaterSimulationDriver : MonoBehaviour
    {
        [Header("Simulation")]
        [SerializeField] private ComputeShader simulationCompute;
        [SerializeField, Min(16)] private int simulationResolution = 256;
        [SerializeField, Min(0.001f)] private float damping = 1.2f;
        [SerializeField, Min(0.001f)] private float propagation = 18f;

        [Header("Material Binding")]
        [SerializeField] private Renderer targetRenderer;
        [SerializeField] private string waveTextureProperty = "_WaveRT";
        [SerializeField] private string depthMaskProperty = "_DepthMask";

        [Header("Water Bounds")]
        [SerializeField] private bool autoSyncBoundsFromRenderer = true;
        [SerializeField, Min(0f)] private float boundsPadding = 0.1f;
        [SerializeField] private string boundsMinProperty = "_WaterBoundsMin";
        [SerializeField] private string boundsMaxProperty = "_WaterBoundsMax";

        [Header("Mask Source")]
        [SerializeField] private Texture externalWaterMask;
        [SerializeField] private bool fillWhiteWhenNoMask = true;

        [Header("Editor Preview")]
        [SerializeField] private bool previewInEditMode = true;
        [SerializeField, Range(1f, 120f)] private float previewFps = 30f;
        [SerializeField, Min(0f)] private float previewTimeScale = 1f;

        private static readonly int WaveHeightRT = Shader.PropertyToID("_WaveHeightRT");
        private static readonly int WaveVelocityRT = Shader.PropertyToID("_WaveVelocityRT");
        private static readonly int WaterMaskRT = Shader.PropertyToID("_WaterMaskRT");
        private static readonly int DeltaTime = Shader.PropertyToID("_DeltaTime");
        private static readonly int Damping = Shader.PropertyToID("_Damping");
        private static readonly int Propagation = Shader.PropertyToID("_Propagation");
        private static readonly int TextureSize = Shader.PropertyToID("_TextureSize");

        private RenderTexture waveHeightRT;
        private RenderTexture waveVelocityRT;
        private RenderTexture waterMaskRT;

        private int propagateKernel = -1;
        private float lastTickTime;
        private MaterialPropertyBlock propertyBlock;

        private void OnEnable()
        {
            AutoAssignRendererIfNeeded();
            EnsureResources();
            lastTickTime = CurrentRealtime();
        }

        private void OnDisable()
        {
            ReleaseResources();
        }

        private void OnValidate()
        {
            simulationResolution = Mathf.Max(16, simulationResolution);
            previewFps = Mathf.Clamp(previewFps, 1f, 120f);
            previewTimeScale = Mathf.Max(0f, previewTimeScale);
            boundsPadding = Mathf.Max(0f, boundsPadding);

            AutoAssignRendererIfNeeded();
            EnsureResources();
            BindWaterProperties();
        }

        private void Update()
        {
            if (!CanSimulate())
            {
                return;
            }

            if (Application.isPlaying)
            {
                SimulateFrame(Time.deltaTime);
                return;
            }

            if (!previewInEditMode)
            {
                return;
            }

            float now = CurrentRealtime();
            float minStep = 1f / previewFps;
            float dt = (now - lastTickTime) * previewTimeScale;
            if (dt < minStep)
            {
                return;
            }

            SimulateFrame(dt);
            lastTickTime = now;

            #if UNITY_EDITOR
            // 在编辑器预览模式下刷新场景视图。
            EditorApplication.QueuePlayerLoopUpdate();
            SceneView.RepaintAll();
            #endif
        }

        private void AutoAssignRendererIfNeeded()
        {
            if (targetRenderer == null)
            {
                targetRenderer = GetComponent<Renderer>();
            }
        }

        private bool CanSimulate()
        {
            return simulationCompute != null && propagateKernel >= 0;
        }

        private void EnsureResources()
        {
            if (simulationCompute != null && propagateKernel < 0)
            {
                propagateKernel = simulationCompute.FindKernel("CSWavePropagate");
            }

            waveHeightRT = EnsureRT(waveHeightRT, simulationResolution, "WaterWave_Height");
            waveVelocityRT = EnsureRT(waveVelocityRT, simulationResolution, "WaterWave_Velocity");
            waterMaskRT = EnsureRT(waterMaskRT, simulationResolution, "WaterWave_Mask");

            RefreshMask();
            BindWaterProperties();
        }

        private static RenderTexture EnsureRT(RenderTexture rt, int resolution, string name)
        {
            bool invalid = rt == null || !rt.IsCreated() || rt.width != resolution || rt.height != resolution;
            if (!invalid)
            {
                return rt;
            }

            if (rt != null)
            {
                rt.Release();
                Object.DestroyImmediate(rt);
            }

            var created = new RenderTexture(resolution, resolution, 0, RenderTextureFormat.RFloat)
            {
                name = name,
                enableRandomWrite = true,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp
            };
            created.Create();
            return created;
        }

        private void RefreshMask()
        {
            if (waterMaskRT == null)
            {
                return;
            }

            if (externalWaterMask != null)
            {
                // 指定了外部地块遮罩时，使用外部遮罩覆盖内部 RT。
                Graphics.Blit(externalWaterMask, waterMaskRT);
                return;
            }

            if (fillWhiteWhenNoMask)
            {
                // 未指定地块遮罩时，默认整张 RT 绘制为白色：全区域为水面。
                Graphics.Blit(Texture2D.whiteTexture, waterMaskRT);
            }
        }

        private void BindWaterProperties()
        {
            if (targetRenderer == null || waveHeightRT == null)
            {
                return;
            }

            propertyBlock ??= new MaterialPropertyBlock();
            targetRenderer.GetPropertyBlock(propertyBlock);
            propertyBlock.SetTexture(waveTextureProperty, waveHeightRT);
            propertyBlock.SetTexture(depthMaskProperty, waterMaskRT);

            if (autoSyncBoundsFromRenderer)
            {
                Bounds bounds = targetRenderer.bounds;
                Vector3 min = bounds.min - Vector3.one * boundsPadding;
                Vector3 max = bounds.max + Vector3.one * boundsPadding;

                propertyBlock.SetVector(boundsMinProperty, new Vector4(min.x, min.y, min.z, 0f));
                propertyBlock.SetVector(boundsMaxProperty, new Vector4(max.x, max.y, max.z, 0f));
            }

            targetRenderer.SetPropertyBlock(propertyBlock);
        }

        private void SimulateFrame(float dt)
        {
            if (dt <= 0f)
            {
                return;
            }

            // 每帧同步遮罩，确保编辑器修改外部遮罩后立即生效。
            RefreshMask();

            simulationCompute.SetTexture(propagateKernel, WaveHeightRT, waveHeightRT);
            simulationCompute.SetTexture(propagateKernel, WaveVelocityRT, waveVelocityRT);
            simulationCompute.SetTexture(propagateKernel, WaterMaskRT, waterMaskRT);
            simulationCompute.SetFloat(DeltaTime, dt);
            simulationCompute.SetFloat(Damping, damping);
            simulationCompute.SetFloat(Propagation, propagation);
            simulationCompute.SetVector(TextureSize, new Vector2(simulationResolution, simulationResolution));

            int groups = Mathf.CeilToInt(simulationResolution / 8f);
            simulationCompute.Dispatch(propagateKernel, groups, groups, 1);

            BindWaterProperties();
        }

        private static float CurrentRealtime()
        {
            #if UNITY_EDITOR
            return (float)EditorApplication.timeSinceStartup;
            #else
            return Time.realtimeSinceStartup;
            #endif
        }

        private void ReleaseResources()
        {
            ReleaseRT(ref waveHeightRT);
            ReleaseRT(ref waveVelocityRT);
            ReleaseRT(ref waterMaskRT);
        }

        private static void ReleaseRT(ref RenderTexture rt)
        {
            if (rt == null)
            {
                return;
            }

            rt.Release();
            Object.DestroyImmediate(rt);
            rt = null;
        }
    }
}
