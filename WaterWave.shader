Shader "Custom/WaterWave"
{
    Properties
    {
        _BaseColor ("Base Color", Color) = (0.07, 0.42, 0.58, 0.85)
        _ShallowColor ("Shallow Color", Color) = (0.18, 0.63, 0.7, 0.85)
        _FoamColor ("Foam Color", Color) = (0.87, 0.97, 1, 1)

        _WaterBoundsMin ("Water Bounds Min", Vector) = (0,0,0,0)
        _WaterBoundsMax ("Water Bounds Max", Vector) = (16,6,0,0)

        _WaveHeight ("Wave Height", Range(0, 1)) = 0.18
        _WaveFrequency ("Wave Frequency", Range(0.1, 8)) = 2.7
        _WaveSpeed ("Wave Speed", Range(0, 6)) = 1.2
        _NormalStrength ("Normal Strength", Range(0, 2)) = 0.55

        _SSRStrength ("SSR Strength", Range(0, 2)) = 0.8
        _SSRStepSize ("SSR Step Size", Range(0.002, 0.08)) = 0.02
        _SSRSteps ("SSR Steps", Range(4, 48)) = 16

        _CausticsScale ("Caustics Scale", Range(0.2, 12)) = 3.1
        _CausticsSpeed ("Caustics Speed", Range(0, 5)) = 1.4
        _CausticsStrength ("Caustics Strength", Range(0, 2)) = 0.72

        _WaveRT ("Wave Simulation RT", 2D) = "black" {}
        _CausticsLUT ("Caustics LUT", 2D) = "gray" {}
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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            TEXTURE2D(_WaveRT);
            SAMPLER(sampler_WaveRT);
            TEXTURE2D(_CausticsLUT);
            SAMPLER(sampler_CausticsLUT);

            TEXTURE2D_X(_CameraOpaqueTexture);
            SAMPLER(sampler_CameraOpaqueTexture);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                half4 _ShallowColor;
                half4 _FoamColor;
                float4 _WaterBoundsMin;
                float4 _WaterBoundsMax;
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
                float sum = 0;
                float amp = 0.5;
                float2 p = uv;
                [unroll(4)]
                for (int i = 0; i < 4; i++)
                {
                    sum += ValueNoise(p) * amp;
                    p = p * 2.07 + 13.7;
                    amp *= 0.5;
                }
                return sum;
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

            float2 CalcWaterUV(float3 positionWS)
            {
                float2 minB = _WaterBoundsMin.xy;
                float2 maxB = _WaterBoundsMax.xy;
                float2 sizeB = max(maxB - minB, 0.001);
                return saturate((positionWS.xy - minB) / sizeB);
            }

            float3 ApproxWaterNormal(float2 waterUV, float t)
            {
                float2 waveUV = waterUV * _WaveFrequency + float2(0.0, t * _WaveSpeed);
                float wave = FBM(waveUV * 3.1);
                float waveX = FBM((waveUV + float2(0.03, 0)) * 3.1);
                float waveY = FBM((waveUV + float2(0, 0.03)) * 3.1);

                float h = wave * _WaveHeight;
                float hx = (waveX - wave) * _NormalStrength;
                float hy = (waveY - wave) * _NormalStrength;

                float3 n = normalize(float3(-hx, 1.0, -hy));
                return n;
            }

            half3 TraceSSR(float2 screenUV, float3 normalWS)
            {
                float2 stepDir = normalize(normalWS.xz + 1e-5) * _SSRStepSize;
                float2 uv = screenUV;
                half3 accum = 0;
                float weight = 0;

                [loop]
                for (int i = 0; i < (int)_SSRSteps; i++)
                {
                    uv += stepDir;
                    if (any(uv < 0) || any(uv > 1))
                    {
                        break;
                    }

                    half3 sampleCol = SAMPLE_TEXTURE2D_X(_CameraOpaqueTexture, sampler_CameraOpaqueTexture, uv).rgb;
                    float w = 1.0 - (i / max(_SSRSteps, 1.0));
                    accum += sampleCol * w;
                    weight += w;
                }

                return (weight > 0.0) ? accum / weight : 0;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 screenUV = input.screenPos.xy / input.screenPos.w;
                float2 waterUV = CalcWaterUV(input.positionWS);
                float t = _Time.y;

                float waveRT = SAMPLE_TEXTURE2D(_WaveRT, sampler_WaveRT, waterUV).r;
                float proceduralWave = FBM((waterUV + float2(0, t * _WaveSpeed)) * (_WaveFrequency * 2.0));
                float wave = saturate(0.6 * proceduralWave + 0.4 * waveRT);

                float3 normalWS = ApproxWaterNormal(waterUV + wave * 0.2, t);

                half depthRaw = SampleSceneDepth(screenUV);
                float sceneEyeDepth = LinearEyeDepth(depthRaw, _ZBufferParams);
                float waterEyeDepth = LinearEyeDepth(input.positionCS.z / input.positionCS.w, _ZBufferParams);
                float depthDelta = saturate((sceneEyeDepth - waterEyeDepth) * 0.2);

                half3 waterCol = lerp(_ShallowColor.rgb, _BaseColor.rgb, depthDelta);

                half3 reflected = TraceSSR(screenUV, normalWS);
                waterCol = lerp(waterCol, reflected, _SSRStrength * saturate(1.0 - depthDelta));

                float2 causticsUV = waterUV * _CausticsScale + normalWS.xz * 0.5 + t * _CausticsSpeed;
                half causticsLUT = SAMPLE_TEXTURE2D(_CausticsLUT, sampler_CausticsLUT, causticsUV).r;
                half caustics = saturate(causticsLUT * 1.8 + FBM(causticsUV * 2.3));

                waterCol += _CausticsStrength * caustics * (1.0 - depthDelta) * _ShallowColor.rgb;

                half foam = smoothstep(0.65, 0.95, wave) * saturate(1.0 - depthDelta);
                waterCol = lerp(waterCol, _FoamColor.rgb, foam * 0.65);

                half alpha = _BaseColor.a;
                return half4(waterCol, alpha);
            }
            ENDHLSL
        }
    }
}
