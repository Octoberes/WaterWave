Shader "WaterWave/URP2D/WaterSurface"
{
    Properties
    {
        // Base color set for deep water areas.
        _BaseColor ("Base Color", Color) = (0.07, 0.42, 0.58, 0.85)
        // Color for shallow areas (used with depth delta blend).
        _ShallowColor ("Shallow Color", Color) = (0.18, 0.63, 0.7, 0.85)
        // Foam tint for crests.
        _FoamColor ("Foam Color", Color) = (0.87, 0.97, 1, 1)

        // Tilemap/world bounds used to remap world position into water UV.
        _WaterBoundsMin ("Water Bounds Min", Vector) = (0,0,0,0)
        _WaterBoundsMax ("Water Bounds Max", Vector) = (16,6,0,0)
        // Soft alpha fade near bounds edge.
        _BoundsFade ("Bounds Fade", Range(0.001, 0.25)) = 0.03

        // Wave appearance controls.
        _WaveHeight ("Wave Height", Range(0, 1)) = 0.18
        _WaveFrequency ("Wave Frequency", Range(0.1, 8)) = 2.7
        _WaveSpeed ("Wave Speed", Range(0, 6)) = 1.2
        _NormalStrength ("Normal Strength", Range(0, 2)) = 0.55

        // SSR controls.
        _SSRStrength ("SSR Strength", Range(0, 2)) = 0.8
        _SSRStepSize ("SSR Step Size", Range(0.002, 0.08)) = 0.02
        _SSRSteps ("SSR Steps", Range(4, 48)) = 16

        // Procedural caustics controls (no LUT required).
        _CausticsScale ("Caustics Scale", Range(0.2, 24)) = 5.2
        _CausticsSpeed ("Caustics Speed", Range(0, 8)) = 1.4
        _CausticsStrength ("Caustics Strength", Range(0, 2)) = 0.72
        _CausticsCellDensity ("Caustics Cell Density", Range(1, 24)) = 8
        _CausticsSharpness ("Caustics Sharpness", Range(0.5, 12)) = 3.2
        _CausticsDistort ("Caustics Distort", Range(0, 2)) = 0.65

        // Simulated wave field texture from compute pass.
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

            // Toggle lightweight path for low-end targets.
            #pragma multi_compile_local_fragment _ WATER_LOW_QUALITY

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            TEXTURE2D(_WaveRT);
            SAMPLER(sampler_WaveRT);

            TEXTURE2D_X(_CameraOpaqueTexture);
            SAMPLER(sampler_CameraOpaqueTexture);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                half4 _ShallowColor;
                half4 _FoamColor;
                float4 _WaterBoundsMin;
                float4 _WaterBoundsMax;
                float _BoundsFade;
                float _WaveHeight;
                float _WaveFrequency;
                float _WaveSpeed;
                float _NormalStrength;
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
                float2 uv : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float4 screenPos : TEXCOORD2;
            };

            // Small hash utility for procedural noise.
            float2 Hash22(float2 p)
            {
                p = frac(p * float2(5.3983, 5.4427));
                p += dot(p.yx, p.xy + 19.19);
                return frac(float2(p.x * p.y, p.x + p.y));
            }

            // Value noise for macro wave and detail distortion.
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

            // Fractal noise: low quality (2 octave) / normal (4 octave).
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

            // Voronoi cell distance: used for procedural caustics lines.
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

            // Map world position into [0..1] uv based on tilemap bounds.
            float2 CalcWaterUV(float3 positionWS)
            {
                float2 minB = _WaterBoundsMin.xy;
                float2 maxB = _WaterBoundsMax.xy;
                float2 sizeB = max(maxB - minB, 0.001);
                return saturate((positionWS.xy - minB) / sizeB);
            }

            // Fade alpha near bounds edges.
            float BoundsMask(float2 waterUV)
            {
                float edge = min(min(waterUV.x, waterUV.y), min(1.0 - waterUV.x, 1.0 - waterUV.y));
                return saturate(edge / max(_BoundsFade, 1e-4));
            }

            // Approximate normal from wave field gradient.
            float3 ApproxWaterNormal(float2 waterUV, float t, float wave)
            {
                float2 waveUV = waterUV * _WaveFrequency + float2(0.0, t * _WaveSpeed);
                float stepLen = 0.03;
                float waveX = FBM((waveUV + float2(stepLen, 0)) * 3.1);
                float waveY = FBM((waveUV + float2(0, stepLen)) * 3.1);

                float hx = (waveX - wave) * _NormalStrength;
                float hy = (waveY - wave) * _NormalStrength;

                return normalize(float3(-hx, 1.0, -hy));
            }

            // Cheap SSR tracing along a normal-driven screen direction.
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
                    if (any(uv < 0) || any(uv > 1))
                    {
                        break;
                    }

                    half3 sampleCol = SAMPLE_TEXTURE2D_X(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, uv).rgb;
                    float w = 1.0 - (i / max((float)steps, 1.0));
                    accum += sampleCol * w;
                    weight += w;
                }

                return (weight > 0.0) ? accum / weight : 0;
            }

            // Procedural caustics from animated Voronoi + fbm distortion.
            float CalcProceduralCaustics(float2 waterUV, float3 normalWS, float t)
            {
                float2 causticsUV = waterUV * _CausticsScale;
                causticsUV += normalWS.xz * _CausticsDistort;
                causticsUV += float2(0.17, -0.23) * t * _CausticsSpeed;

                float distortion = FBM(causticsUV * 1.9 + t * 0.25) - 0.5;
                causticsUV += distortion * 0.45;

                float v0 = Voronoi(causticsUV * _CausticsCellDensity);
                float v1 = Voronoi((causticsUV + float2(1.7, -2.4)) * (_CausticsCellDensity * 0.8));
                float v = min(v0, v1);

                // Invert and sharpen to create bright thin caustics lines.
                float caustics = 1.0 - saturate(v * 1.7);
                caustics = pow(caustics, _CausticsSharpness);
                return caustics;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                float2 waterUV = CalcWaterUV(input.positionWS);
                float boundsMask = BoundsMask(waterUV);
                float t = _Time.y;

                // Mix compute wave RT and procedural noise wave for stability + detail.
                float waveRT = SAMPLE_TEXTURE2D(_WaveRT, sampler_WaveRT, waterUV).r;
                float proceduralWave = FBM((waterUV + float2(0, t * _WaveSpeed)) * (_WaveFrequency * 2.0));
                float wave = saturate(0.6 * proceduralWave + 0.4 * waveRT) * _WaveHeight;

                float3 normalWS = ApproxWaterNormal(waterUV + wave * 0.2, t, proceduralWave);

                // Depth delta for shallow/deep color blend.
                half rawSceneDepth = SampleSceneDepth(screenUV);
                float sceneEyeDepth = LinearEyeDepth(rawSceneDepth, _ZBufferParams);

                #if defined(SHADER_API_GLES) || defined(SHADER_API_GLES3)
                    float rawWaterDepth = saturate(input.positionCS.z / input.positionCS.w * 0.5 + 0.5);
                #else
                    float rawWaterDepth = saturate(input.positionCS.z / input.positionCS.w);
                #endif

                float waterEyeDepth = LinearEyeDepth(rawWaterDepth, _ZBufferParams);
                float depthDelta = saturate((sceneEyeDepth - waterEyeDepth) * 0.2);

                half3 waterCol = lerp(_ShallowColor.rgb, _BaseColor.rgb, depthDelta);

                // Reflection: full trace or low-cost fallback.
                #if defined(WATER_LOW_QUALITY)
                    half3 reflected = SAMPLE_TEXTURE2D_X(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, screenUV).rgb;
                #else
                    half3 reflected = TraceSSR(screenUV, normalWS);
                #endif
                waterCol = lerp(waterCol, reflected, _SSRStrength * saturate(1.0 - depthDelta));

                // Procedural caustics (Voronoi-based).
                float caustics = CalcProceduralCaustics(waterUV, normalWS, t);
                waterCol += _CausticsStrength * caustics * (1.0 - depthDelta) * _ShallowColor.rgb;

                // Foam mostly appears on shallow and high-wave areas.
                half foam = smoothstep(0.65, 0.95, saturate(waveRT * 0.5 + proceduralWave * 0.5)) * saturate(1.0 - depthDelta);
                waterCol = lerp(waterCol, _FoamColor.rgb, foam * 0.65);

                half alpha = _BaseColor.a * boundsMask;
                return half4(waterCol, alpha);
            }
            ENDHLSL
        }
    }
}
