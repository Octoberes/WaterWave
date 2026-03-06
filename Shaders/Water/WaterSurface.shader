Shader "WaterWave/URP2D/WaterSurface"
{
    Properties
    {
        // 深水区域的基础颜色。
        _BaseColor ("Base Color", Color) = (0.07, 0.42, 0.58, 0.9)
        // 浅水区域颜色（与深度混合使用）。
        _ShallowColor ("Shallow Color", Color) = (0.22, 0.68, 0.78, 0.9)
        // 波峰泡沫颜色。
        _FoamColor ("Foam Color", Color) = (0.9, 0.98, 1, 1)

        // Tilemap/世界空间边界：用于将世界坐标映射到水面UV。
        _WaterBoundsMin ("Water Bounds Min", Vector) = (0,0,0,0)
        _WaterBoundsMax ("Water Bounds Max", Vector) = (16,6,0,0)
        // 边界附近的透明度软过渡。
        _BoundsFade ("Bounds Fade", Range(0.001, 0.25)) = 0.03

        // 深度参数：来源于地块 Mask，并限制最深上限。
        _DepthMask ("Depth Mask", 2D) = "white" {}
        _MaxDepth ("Max Depth", Range(0, 1)) = 1
        _DepthEdgeFade ("Depth Edge Fade", Range(0.01, 0.5)) = 0.16

        // 波形参数（Gerstner 多波叠加）。
        _GerstnerAmplitude ("Gerstner Amplitude", Range(0, 1)) = 0.2
        _WaveRTStrength ("Wave RT Strength", Range(0, 1)) = 0.35

        _WaveA1 ("Wave1 Amplitude", Range(0, 1)) = 0.25
        _WaveL1 ("Wave1 Length", Range(0.05, 3)) = 0.8
        _WaveS1 ("Wave1 Speed", Range(0, 5)) = 1.2
        _WaveD1 ("Wave1 Direction", Vector) = (1, 0.35, 0, 0)

        _WaveA2 ("Wave2 Amplitude", Range(0, 1)) = 0.2
        _WaveL2 ("Wave2 Length", Range(0.05, 3)) = 0.5
        _WaveS2 ("Wave2 Speed", Range(0, 5)) = 1.8
        _WaveD2 ("Wave2 Direction", Vector) = (-0.65, 0.8, 0, 0)

        _WaveA3 ("Wave3 Amplitude", Range(0, 1)) = 0.15
        _WaveL3 ("Wave3 Length", Range(0.05, 3)) = 1.3
        _WaveS3 ("Wave3 Speed", Range(0, 5)) = 0.95
        _WaveD3 ("Wave3 Direction", Vector) = (0.3, 1.0, 0, 0)

        // 屏幕空间反射（SSR）参数。
        _SSRStrength ("SSR Strength", Range(0, 2)) = 0.8
        _SSRStepSize ("SSR Step Size", Range(0.002, 0.08)) = 0.02
        _SSRSteps ("SSR Steps", Range(4, 48)) = 16

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
            #pragma multi_compile_local_fragment _ WATER_LOW_QUALITY

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_WaveRT);
            SAMPLER(sampler_WaveRT);
            TEXTURE2D(_DepthMask);
            SAMPLER(sampler_DepthMask);

            TEXTURE2D_X(_CameraOpaqueTexture);
            SAMPLER(sampler_CameraOpaqueTexture);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                half4 _ShallowColor;
                half4 _FoamColor;
                float4 _WaterBoundsMin;
                float4 _WaterBoundsMax;
                float _BoundsFade;
                float _MaxDepth;
                float _DepthEdgeFade;

                float _GerstnerAmplitude;
                float _WaveRTStrength;

                float _WaveA1;
                float _WaveL1;
                float _WaveS1;
                float4 _WaveD1;

                float _WaveA2;
                float _WaveL2;
                float _WaveS2;
                float4 _WaveD2;

                float _WaveA3;
                float _WaveL3;
                float _WaveS3;
                float4 _WaveD3;

                float _SSRStrength;
                float _SSRStepSize;
                float _SSRSteps;
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
                float3 positionWS : TEXCOORD0;
                float4 screenPos : TEXCOORD1;
            };

            float2 Hash22(float2 p)
            {
                p = frac(p * float2(5.3983, 5.4427));
                p += dot(p.yx, p.xy + 19.19);
                return frac(float2(p.x * p.y, p.x + p.y));
            }

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
                        minDist = min(minDist, dot(p, p));
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
                output.screenPos = ComputeScreenPos(output.positionCS);
                return output;
            }

            float2 CalcWaterUV(float3 positionWS)
            {
                float2 minB = _WaterBoundsMin.xy;
                float2 maxB = _WaterBoundsMax.xy;
                float2 sizeB = max(maxB - minB, 0.001);
                return saturate((positionWS.xy - minB) / sizeB);
            }

            float BoundsMask(float2 waterUV)
            {
                float edge = min(min(waterUV.x, waterUV.y), min(1.0 - waterUV.x, 1.0 - waterUV.y));
                return saturate(edge / max(_BoundsFade, 1e-4));
            }

            // 只在左/上/右产生深浅渐变，下边保持深水。
            float CalcDirectionalDepth01(float2 waterUV)
            {
                float sideTopDist = min(min(waterUV.x, 1.0 - waterUV.x), 1.0 - waterUV.y);
                float sideTopFactor = saturate(sideTopDist / max(_DepthEdgeFade, 1e-4));

                // 由地块 Mask 提供基础深度（默认白图=全深水）。
                float maskDepth = SAMPLE_TEXTURE2D(_DepthMask, sampler_DepthMask, waterUV).r;

                return saturate(maskDepth * sideTopFactor * _MaxDepth);
            }

            void GerstnerWave(float2 uv, float2 dir, float amp, float wavelength, float speed, float t, inout float height, inout float2 grad)
            {
                float2 d = normalize(dir + 1e-5);
                float k = TWO_PI / max(wavelength, 1e-4);
                float phase = k * dot(d, uv) + speed * t;

                height += amp * sin(phase);
                grad += amp * k * cos(phase) * d;
            }

            void CalcGerstner(float2 waterUV, float t, out float height, out float3 normalWS)
            {
                float h = 0;
                float2 grad = 0;

                GerstnerWave(waterUV, _WaveD1.xy, _WaveA1 * _GerstnerAmplitude, _WaveL1, _WaveS1, t, h, grad);
                GerstnerWave(waterUV, _WaveD2.xy, _WaveA2 * _GerstnerAmplitude, _WaveL2, _WaveS2, t, h, grad);
                GerstnerWave(waterUV, _WaveD3.xy, _WaveA3 * _GerstnerAmplitude, _WaveL3, _WaveS3, t, h, grad);

                height = h;
                normalWS = normalize(float3(-grad.x, 1.0, -grad.y));
            }

            half3 TraceSSR(float2 screenUV, float3 normalWS)
            {
                float2 dir = normalWS.xz;
                float dirLen2 = max(dot(dir, dir), 1e-6);
                float2 stepDir = dir * rsqrt(dirLen2) * _SSRStepSize;
                float2 uv = screenUV;
                half3 accum = 0;
                float weight = 0;

                int steps = (int)round(_SSRSteps);
                [loop]
                for (int i = 0; i < steps; i++)
                {
                    uv += stepDir;
                    if (any(uv < 0) || any(uv > 1)) break;

                    half3 sampleCol = SAMPLE_TEXTURE2D_X(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, uv).rgb;
                    float w = 1.0 - (i / max((float)steps, 1.0));
                    accum += sampleCol * w;
                    weight += w;
                }
                return (weight > 0.0) ? accum / weight : 0;
            }

            float CalcProceduralCaustics(float2 waterUV, float3 normalWS, float t)
            {
                float2 causticsUV = waterUV * _CausticsScale;
                causticsUV += normalWS.xz * _CausticsDistort;
                causticsUV += float2(0.17, -0.23) * t * _CausticsSpeed;

                float distortion = FBM(causticsUV * 1.9 + t * 0.25) - 0.5;
                causticsUV += distortion * 0.45;

                float v0 = Voronoi(causticsUV * _CausticsCellDensity);
                float v1 = Voronoi((causticsUV + float2(1.7, -2.4)) * (_CausticsCellDensity * 0.8));
                float caustics = 1.0 - saturate(min(v0, v1) * 1.7);
                return pow(caustics, _CausticsSharpness);
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                float2 waterUV = CalcWaterUV(input.positionWS);
                float boundsMask = BoundsMask(waterUV);
                float t = _Time.y;

                float gerstnerHeight;
                float3 gerstnerNormal;
                CalcGerstner(waterUV, t, gerstnerHeight, gerstnerNormal);

                float waveRT = SAMPLE_TEXTURE2D(_WaveRT, sampler_WaveRT, waterUV).r;
                float wave = gerstnerHeight + waveRT * _WaveRTStrength;

                float3 normalWS = normalize(lerp(float3(0, 1, 0), gerstnerNormal, saturate(abs(wave) + 0.2)));

                float depth01 = CalcDirectionalDepth01(waterUV);
                half3 waterCol = lerp(_ShallowColor.rgb, _BaseColor.rgb, depth01);

                #if defined(WATER_LOW_QUALITY)
                    half3 reflected = SAMPLE_TEXTURE2D_X(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, screenUV).rgb;
                #else
                    half3 reflected = TraceSSR(screenUV, normalWS);
                #endif
                waterCol = lerp(waterCol, reflected, _SSRStrength * depth01);

                float caustics = CalcProceduralCaustics(waterUV + wave * 0.08, normalWS, t);
                waterCol += _CausticsStrength * caustics * (1.0 - depth01) * _ShallowColor.rgb;

                float crest = saturate(abs(wave) * (2.0 + _GerstnerAmplitude * 4.0));
                half foam = smoothstep(0.5, 0.95, crest) * saturate(1.0 - depth01 * 0.85);
                waterCol = lerp(waterCol, _FoamColor.rgb, foam * 0.65);

                half alpha = _BaseColor.a * boundsMask;
                return half4(waterCol, alpha);
            }
            ENDHLSL
        }
    }
}
