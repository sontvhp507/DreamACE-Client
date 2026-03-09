// Water_CalmLake.fx - Calm lake with 8 golden-angle Gerstner waves
// Non-repeating wave patterns from incommensurate wavelengths
// vs_3_0/ps_3_0

texture MainTex;
texture NormalTex;
texture DistortTex;

sampler2D BumpSampler = sampler_state {
    Texture = <NormalTex>;
    MinFilter = LINEAR; MagFilter = LINEAR; MipFilter = LINEAR;
    AddressU = WRAP; AddressV = WRAP;
};

float MoveFactor;
float FogStart;
float FogEnd;
float3 FogColor;
float3 CamPos;
float4x4 View;
float4x4 ViewProj;

// ============================================================
// Gerstner wave with deep-water dispersion
// ============================================================

float gerstnerWave(float2 xz, float time, float2 dir, float wl, float steep)
{
    float2 d = normalize(dir);
    float k = 6.2832 / wl;
    float c = sqrt(9.8 / k);
    float f = k * (dot(d, xz) - c * time);
    return (steep / k) * sin(f);
}

// 8 waves with golden-angle (137.5 deg) direction spacing
// Wavelengths follow near-Fibonacci sequence: 113, 73, 47, 31, 19, 13, 8, 5
// These ratios are irrational so the combined pattern never repeats
float seaHeight(float2 xz, float time)
{
    float h = 0.0;
    h += gerstnerWave(xz, time, float2( 1.000,  0.000), 113.0, 0.10);
    h += gerstnerWave(xz, time, float2(-0.737,  0.676),  73.0, 0.08);
    h += gerstnerWave(xz, time, float2( 0.087, -0.996),  47.0, 0.06);
    h += gerstnerWave(xz, time, float2( 0.609,  0.793),  31.0, 0.04);
    h += gerstnerWave(xz, time, float2(-0.985, -0.174),  19.0, 0.025);
    h += gerstnerWave(xz, time, float2( 0.843, -0.537),  13.0, 0.015);
    h += gerstnerWave(xz, time, float2(-0.259,  0.966),   8.0, 0.010);
    h += gerstnerWave(xz, time, float2(-0.454, -0.891),   5.0, 0.008);
    return h;
}

struct VS_INPUT
{
    float3 Position : POSITION;
    float3 Normal   : NORMAL;
    float2 TexCoord : TEXCOORD0;
};

struct VS_OUTPUT
{
    float4 Position  : POSITION;
    float4 BumpUV01  : TEXCOORD0;
    float4 BumpUV2FH : TEXCOORD1;
    float3 ViewDir   : TEXCOORD2;
    float3 WaveNorm  : TEXCOORD3;
};

VS_OUTPUT WaterVS(VS_INPUT input)
{
    VS_OUTPUT output;
    float3 pos = input.Position;
    float time = MoveFactor;

    float h = seaHeight(pos.xz, time);
    pos.y += h;

    // Finite-difference normal
    float eps = 2.5;
    float hx = seaHeight(pos.xz + float2(eps, 0.0), time);
    float hz = seaHeight(pos.xz + float2(0.0, eps), time);
    output.WaveNorm = normalize(float3(h - hx, eps, h - hz));

    output.Position = mul(float4(pos, 1.0), ViewProj);

    // Dual-layer bump UVs - gentle calm ripple detail
    float bt = time * 0.25;
    output.BumpUV01.xy = pos.xz * 0.03 + float2(bt * 0.15, bt * 0.10);
    output.BumpUV01.zw = pos.xz * 0.065 + float2(-bt * 0.08, bt * 0.18);
    output.BumpUV2FH.xy = pos.xz * 0.13 + float2(bt * 0.22, -bt * 0.12);

    float3 viewVec = pos - CamPos;
    output.ViewDir = viewVec;
    output.BumpUV2FH.z = saturate((length(viewVec) - FogStart) / max(FogEnd - FogStart, 0.001));
    output.BumpUV2FH.w = h;

    return output;
}

float4 WaterPS(VS_OUTPUT input) : COLOR
{
    // 3-layer bump for calm ripples
    float3 n0 = tex2D(BumpSampler, input.BumpUV01.xy).rgb * 2.0 - 1.0;
    float3 n1 = tex2D(BumpSampler, input.BumpUV01.zw).rgb * 2.0 - 1.0;
    float3 n2 = tex2D(BumpSampler, input.BumpUV2FH.xy).rgb * 2.0 - 1.0;
    float3 bumpN = normalize(n0 + n1 + n2);

    // Gentle bump perturbation
    float3 normal = normalize(float3(
        input.WaveNorm.x + bumpN.x * 0.15,
        input.WaveNorm.y,
        input.WaveNorm.z + bumpN.y * 0.15
    ));

    float3 V = normalize(input.ViewDir);
    float3 lightDir = normalize(float3(0.3, 1.0, 0.5));

    // Gentle Schlick fresnel
    float NdotV = saturate(dot(normal, -V));
    float fresnel = 0.04 + 0.35 * pow(1.0 - NdotV, 4.0);

    float3 R = reflect(V, normal);

    // Soft pastel sky
    float skyGrad = saturate(R.y * 0.5 + 0.5);
    float3 skyColor = float3(0.55, 0.70, 0.85);
    float3 reflColor = lerp(skyColor * 0.65, skyColor * 1.2, skyGrad);

    // Clear turquoise base
    float3 baseColor = float3(0.10, 0.30, 0.33);

    // Subtle diffuse
    float NdotL = saturate(dot(normal, lightDir));
    baseColor += float3(0.03, 0.06, 0.05) * NdotL;

    // Blend by fresnel
    float3 color = lerp(baseColor, reflColor, fresnel);

    // Subtle specular - tight highlight
    float3 H = normalize(lightDir - V);
    float spec = pow(saturate(dot(normal, H)), 120.0) * 0.25;
    color += spec;

    // Fog
    color = lerp(color, FogColor, input.BumpUV2FH.z);

    return float4(color, 0.50);
}

technique WaterTech
{
    pass P0
    {
        AlphaBlendEnable = TRUE;
        SrcBlend = SRCALPHA;
        DestBlend = INVSRCALPHA;
        ZEnable = TRUE;
        ZWriteEnable = FALSE;
        CullMode = NONE;

        VertexShader = compile vs_3_0 WaterVS();
        PixelShader  = compile ps_3_0 WaterPS();
    }
}
