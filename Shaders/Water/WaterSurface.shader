Shader "WaterWave/URP2D/WaterSurface"
{
    Properties
    {
        // 深水区域的基础颜色。
        _BaseColor ("Base Color", Color) = (0.07, 0.42, 0.58, 0.85)
        // 浅水区域颜色（与深度差混合使用）。
        _ShallowColor ("Shallow Color", Color) = (0.18, 0.63, 0.7, 0.85)
        // 波峰泡沫颜色。
        _FoamColor ("Foam Color", Color) = (0.87, 0.97, 1, 1)

        // Tilemap/世界空间边界：用于将世界坐标映射到水面UV。
        _WaterBoundsMin ("Water Bounds Min", Vector) = (0,0,0,0)
        _WaterBoundsMax ("Water Bounds Max", Vector) = (16,6,0,0)
        // 边界附近的透明度软过渡。
        _BoundsFade ("Bounds Fade", Range(0.001, 0.25)) = 0.03
        // 以世界单位控制左右/上边缘的浅水过渡距离。
        _DepthEdgeFadeWorld ("Depth Edge Fade World", Float) = 0.8

        // 波形外观参数。
        _WaveHeight ("Wave Height", Range(0, 1)) = 0.18
        _WaveFrequency ("Wave Frequency", Range(0.1, 8)) = 2.7
        _WaveSpeed ("Wave Speed", Range(0, 6)) = 1.2
        _NormalStrength ("Normal Strength", Range(0, 2)) = 0.55

        // 手动平面反射参数：按屏幕高度镜像上半部分场景并进行UV扰动。
        _ReflectionStrength ("Reflection Strength", Range(0, 2)) = 0.8
        _ReflectionHeight ("Reflection Height (Screen Y)", Range(0, 1)) = 0.5
        _ReflectionDistort ("Reflection Distort", Range(0, 0.2)) = 0.03
        _ReflectionEdgeFade ("Reflection Edge Fade", Range(0.001, 0.2)) = 0.04

        // 程序化焦散参数（不依赖 LUT）。
        _CausticsScale ("Caustics Scale", Range(0.2, 24)) = 5.2
        _CausticsSpeed ("Caustics Speed", Range(0, 8)) = 1.4
        _CausticsStrength ("Caustics Strength", Range(0, 2)) = 0.72
        _CausticsCellDensity ("Caustics Cell Density", Range(1, 24)) = 8
        _CausticsSharpness ("Caustics Sharpness", Range(0.5, 12)) = 3.2
        _CausticsDistort ("Caustics Distort", Range(0, 2)) = 0.65

        // 来自 Compute Pass 的波场纹理。
        _WaveRT ("Wave Simulation RT", 2D) = "black" {}
    }

    SubShader
    {
        Tags
        {
            "RenderType"="Transparent"
            "Queue"="Transparent"
            "RenderPipeline"="UniversalPipeline"
        }

        Pass
        {
            Name "Universal2D"
            Tags { "LightMode"="Universal2D" }

            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.5

            // 低端平台的轻量渲染分支开关。
            #pragma multi_compile_local_fragment _ WATER_LOW_QUALITY
            // 2D 反射默认使用 Sorting Layer Texture，可按平台/材质切换到 Opaque 回退。
            #pragma multi_compile_local_fragment _ WATER_REFLECT_OPAQUE_FALLBACK

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            TEXTURE2D(_WaveRT);
            SAMPLER(sampler_WaveRT);

            TEXTURE2D_X(_CameraOpaqueTexture);
            SAMPLER(sampler_CameraOpaqueTexture);

            TEXTURE2D_X(_CameraSortingLayerTexture);
            SAMPLER(sampler_CameraSortingLayerTexture);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                half4 _ShallowColor;
                half4 _FoamColor;
                float4 _WaterBoundsMin;
                float4 _WaterBoundsMax;
                float _BoundsFade;
                float _DepthEdgeFadeWorld;
                float _WaveHeight;
                float _WaveFrequency;
                float _WaveSpeed;
                float _NormalStrength;
                float _ReflectionStrength;
                float _ReflectionHeight;
                float _ReflectionDistort;
                float _ReflectionEdgeFade;
                float _CausticsScale;
                float _CausticsSpeed;
                float _CausticsStrength;
                float _CausticsCellDensity;
                float _CausticsSharpness;
                float _CausticsDistort;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float4 screenPos : TEXCOORD2;
            };

            // 程序噪波使用的小型哈希函数。
            float2 Hash22(float2 p)
            {
                p = frac(p * float2(5.3983, 5.4427));
                p += dot(p.yx, p.xy + 19.19);
                return frac(float2(p.x * p.y, p.x + p.y));
            }

            // Value Noise：用于大尺度波形和细节扰动。
            float ValueNoise(float2 uv)
            {
                float2 i = floor(uv);
                float2 f = frac(uv);
                float2 u = f * f * (3.0 - 2.0 * f);

                float a = dot(Hash22(i + float2(0, 0)), float2(1, 0));
                float b = dot(Hash22(i + float2(1, 0)), float2(1, 0));
                float c = dot(Hash22(i + float2(0, 1)), float2(1, 0));
                float d = dot(Hash22(i + float2(1, 1)), float2(1, 0));

                return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
            }

            // 分形噪波：低质量2层 / 常规4层。
            float FBM(float2 uv)
            {
                float sum = 0.0;
                float amp = 0.5;
                float2 p = uv;

                #if defined(WATER_LOW_QUALITY)
                    const int octaves = 2;
                #else
                    const int octaves = 4;
                #endif

                [loop]
                for (int i = 0; i < octaves; i++)
                {
                    sum += ValueNoise(p) * amp;
                    p = p * 2.07 + 13.7;
                    amp *= 0.5;
                }
                return sum;
            }

            // Voronoi 单元距离：用于生成焦散线。
            float Voronoi(float2 uv)
            {
                float2 g = floor(uv);
                float2 f = frac(uv);
                float minDist = 1.0;

                [unroll]
                for (int y = -1; y <= 1; y++)
                {
                    [unroll]
                    for (int x = -1; x <= 1; x++)
                    {
                        float2 o = float2(x, y);
                        float2 h = Hash22(g + o);
                        float2 p = o + h - f;
                        float d = dot(p, p);
                        minDist = min(minDist, d);
                    }
                }

                return sqrt(minDist);
            }

            Varyings vert(Attributes input)
            {
                Varyings output;
                VertexPositionInputs posInputs = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionCS = posInputs.positionCS;
                output.positionWS = posInputs.positionWS;
                output.uv = input.uv;
                output.screenPos = ComputeScreenPos(output.positionCS);
                return output;
            }

            // 基于 Tilemap 边界将世界坐标映射到 [0..1] UV。
            float2 CalcWaterUV(float3 positionWS)
            {
                float2 minB = _WaterBoundsMin.xy;
                float2 maxB = _WaterBoundsMax.xy;
                float2 sizeB = max(maxB - minB, 0.001);
                return saturate((positionWS.xy - minB) / sizeB);
            }

            // 边界边缘透明度衰减。
            float BoundsMask(float2 waterUV)
            {
                float edge = min(min(waterUV.x, waterUV.y), min(1.0 - waterUV.x, 1.0 - waterUV.y));
                return saturate(edge / max(_BoundsFade, 1e-4));
            }

            // 场景深度与水面深度差，叠加左右/上边界的浅水过渡。
            float CalcDepth01(float2 waterUV, float3 positionWS)
            {
                float4 positionCS = TransformWorldToHClip(positionWS);
                float2 screenUV = GetNormalizedScreenSpaceUV(positionCS);
                half rawSceneDepth = SampleSceneDepth(screenUV);
                float sceneEyeDepth = LinearEyeDepth(rawSceneDepth, _ZBufferParams);

                #if defined(SHADER_API_GLES) || defined(SHADER_API_GLES3)
                    float rawWaterDepth = saturate(positionCS.z / positionCS.w * 0.5 + 0.5);
                #else
                    float rawWaterDepth = saturate(positionCS.z / positionCS.w);
                #endif

                float waterEyeDepth = LinearEyeDepth(rawWaterDepth, _ZBufferParams);
                float depth01 = saturate((sceneEyeDepth - waterEyeDepth) * 0.2);

                float distLeft = positionWS.x - _WaterBoundsMin.x;
                float distRight = _WaterBoundsMax.x - positionWS.x;
                float distTop = _WaterBoundsMax.y - positionWS.y;
                float distEdge = min(distLeft, min(distRight, distTop));

                float sideTopFactor = saturate(distEdge / max(_DepthEdgeFadeWorld, 1e-4));

                return depth01 * sideTopFactor;
            }

            // 根据波场梯度近似法线。
            float3 ApproxWaterNormal(float2 waterUV, float t, float wave)
            {
                float2 waveUV = waterUV * _WaveFrequency + float2(0.0, t * _WaveSpeed);
                float stepLen = 0.03;
                float waveX = FBM((waveUV + float2(stepLen, 0)) * 3.1);
                float waveY = FBM((waveUV + float2(0, stepLen)) * 3.1);

                float hx = (waveX - wave) * _NormalStrength;
                float hy = (waveY - wave) * _NormalStrength;

                // URP 2D 下屏幕平面主要对应 XY，法线朝向相机（+Z）。
                return normalize(float3(-hx, -hy, 1.0));
            }

            // 反射源采样：默认 Sorting Layer，必要时回退 Opaque。
            half3 SampleReflectionColor(float2 uv)
            {
                #if defined(WATER_REFLECT_OPAQUE_FALLBACK)
                    return SAMPLE_TEXTURE2D_X(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, uv).rgb;
                #else
                    return SAMPLE_TEXTURE2D_X(_CameraSortingLayerTexture, sampler_CameraSortingLayerTexture, uv).rgb;
                #endif
            }

            half4 CalcPlanarReflection(float2 screenUV, float3 normalWS, float depthDelta)
            {
                float mirrorY = _ReflectionHeight * 2.0 - screenUV.y;
                float2 reflectedUV = float2(screenUV.x, mirrorY);
                reflectedUV += normalWS.xy * _ReflectionDistort;

                float inMirrorRange = step(0.0, mirrorY) * step(mirrorY, 1.0);
                float mirrorFromAbove = step(_ReflectionHeight, mirrorY);

                float2 edgeDist2 = min(reflectedUV, 1.0 - reflectedUV);
                float edgeDist = min(edgeDist2.x, edgeDist2.y);
                float edgeFade = saturate(edgeDist / max(_ReflectionEdgeFade, 1e-4));

                half3 reflected = SampleReflectionColor(saturate(reflectedUV));
                float depthMask = lerp(0.35, 1.0, saturate(1.0 - depthDelta));
                float weight = _ReflectionStrength * inMirrorRange * mirrorFromAbove * edgeFade * depthMask;
                return half4(reflected, saturate(weight));
            }

            // 使用动画 Voronoi + FBM 扰动生成程序化焦散。
            float CalcProceduralCaustics(float2 waterUV, float3 normalWS, float t)
            {
                float2 causticsUV = waterUV * _CausticsScale;
                causticsUV += normalWS.xy * _CausticsDistort;
                causticsUV += float2(0.17, -0.23) * t * _CausticsSpeed;

                float distortion = FBM(causticsUV * 1.9 + t * 0.25) - 0.5;
                causticsUV += distortion * 0.45;

                float v0 = Voronoi(causticsUV * _CausticsCellDensity);
                float v1 = Voronoi((causticsUV + float2(1.7, -2.4)) * (_CausticsCellDensity * 0.8));
                float v = min(v0, v1);

                // 使用距离高值区域形成亮线，避免亮暗反相。
                float caustics = saturate(v * 1.7);
                caustics = pow(caustics, _CausticsSharpness);
                return caustics;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                float2 waterUV = CalcWaterUV(input.positionWS);
                float boundsMask = BoundsMask(waterUV);
                float t = _Time.y;

                // 混合 Compute 波场与程序噪波：兼顾稳定性与细节。
                float waveRT = SAMPLE_TEXTURE2D(_WaveRT, sampler_WaveRT, waterUV).r;
                float proceduralWave = FBM((waterUV + float2(0, t * _WaveSpeed)) * (_WaveFrequency * 2.0));
                float wave = saturate(0.6 * proceduralWave + 0.4 * waveRT) * _WaveHeight;

                float3 normalWS = ApproxWaterNormal(waterUV + wave * 0.2, t, proceduralWave);

                // 用深度差进行浅水/深水颜色混合，并在左右/上边界强制趋浅。
                float depthDelta = CalcDepth01(waterUV, input.positionWS);

                half3 waterCol = lerp(_ShallowColor.rgb, _BaseColor.rgb, depthDelta);

                // 手动平面反射：按指定屏幕高度镜像上方场景，再进行法线扰动。
                half4 reflectionData = CalcPlanarReflection(screenUV, normalWS, depthDelta);
                waterCol = lerp(waterCol, reflectionData.rgb, reflectionData.a);

                // 程序化焦散（基于 Voronoi）。
                float caustics = CalcProceduralCaustics(waterUV, normalWS, t);
                float causticsMask = lerp(0.25, 1.0, saturate(1.0 - depthDelta));
                waterCol += _CausticsStrength * caustics * causticsMask * _ShallowColor.rgb;

                // 泡沫主要出现在浅水与高波动区域。
                half foam = smoothstep(0.65, 0.95, saturate(waveRT * 0.5 + proceduralWave * 0.5)) * saturate(1.0 - depthDelta);
                waterCol = lerp(waterCol, _FoamColor.rgb, foam * 0.65);

                half alpha = _BaseColor.a * boundsMask;
                return half4(waterCol, alpha);
            }
            ENDHLSL
        }
    }
}
