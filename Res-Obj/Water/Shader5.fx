// Water_CalmDeepSea.fx - Calm deep sea with smooth multi-scale waves
// 5-octave SMOOTH noise FBM — rounded wave profiles, no sharp peaks
// Visible swells with fine surface ripples from bump normals
// Deep blue with scattered specular highlights on wave slopes
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
// Smooth procedural noise
// ============================================================

float hash(float2 p)
{
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 43758.5453);
}

float noise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return -1.0 + 2.0 * lerp(
        lerp(hash(i), hash(i + float2(1.0, 0.0)), u.x),
        lerp(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x),
        u.y);
}

// 5-octave smooth noise FBM
// Pure noise() = smooth rounded wave profiles (no triangular peaks)
// Pure rotation (magnitude=1) between octaves keeps UV stable
// Per-octave directional propagation + decreasing speed = organic random motion
float seaHeight(float2 xz, float time)
{
    float2 uv = xz;
    uv.x *= 0.75;

    float h    = 0.0;
    float freq = 0.055;
    float amp  = 0.55;

    // Pure rotation ~37 deg (magnitude 1)
    float2x2 rot = float2x2(0.80, 0.60, -0.60, 0.80);

    // Octave 0 — main rolling swells (speed 0.35)
    h += (noise((uv + time * 0.35 * float2( 0.72, 0.48)) * freq)
        + noise((uv - time * 0.35 * float2( 0.40, 0.65)) * freq)) * 0.5 * amp;
    uv = mul(uv, rot);
    freq *= 2.1; amp *= 0.48;

    // Octave 1 — secondary swells (speed 0.28)
    h += (noise((uv + time * 0.28 * float2( 0.50, 0.85)) * freq)
        + noise((uv - time * 0.28 * float2( 0.82, 0.25)) * freq)) * 0.5 * amp;
    uv = mul(uv, rot);
    freq *= 2.1; amp *= 0.48;

    // Octave 2 — medium waves (speed 0.22)
    h += (noise((uv + time * 0.22 * float2( 0.88, 0.18)) * freq)
        + noise((uv - time * 0.22 * float2( 0.22, 0.90)) * freq)) * 0.5 * amp;
    uv = mul(uv, rot);
    freq *= 2.1; amp *= 0.48;

    // Octave 3 — small waves (speed 0.16)
    h += (noise((uv + time * 0.16 * float2( 0.35, 0.70)) * freq)
        + noise((uv - time * 0.16 * float2( 0.65, 0.50)) * freq)) * 0.5 * amp;
    uv = mul(uv, rot);
    freq *= 2.1; amp *= 0.48;

    // Octave 4 — fine ripple (speed 0.10)
    h += (noise((uv + time * 0.10 * float2( 0.60, 0.55)) * freq)
        + noise((uv - time * 0.10 * float2( 0.45, 0.72)) * freq)) * 0.5 * amp;

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

    // 3-layer bump UVs — well-separated scales, moderate scroll
    float bt = time * 0.22;
    output.BumpUV01.xy = pos.xz * 0.018 + float2(bt * 0.14, bt * 0.09);
    output.BumpUV01.zw = pos.xz * 0.052 + float2(-bt * 0.11, bt * 0.24);
    output.BumpUV2FH.xy = pos.xz * 0.13  + float2(bt * 0.20, -bt * 0.14);

    float3 viewVec = pos - CamPos;
    output.ViewDir = viewVec;
    output.BumpUV2FH.z = saturate((length(viewVec) - FogStart) / max(FogEnd - FogStart, 0.001));
    output.BumpUV2FH.w = h;

    return output;
}

// ACES filmic tonemapping
float3 ACESFilm(float3 x)
{
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

float4 WaterPS(VS_OUTPUT input) : COLOR
{
    // 3-layer bump normals — moderate for visible fine ripple texture
    float3 n0 = tex2D(BumpSampler, input.BumpUV01.xy).rgb * 2.0 - 1.0;
    float3 n1 = tex2D(BumpSampler, input.BumpUV01.zw).rgb * 2.0 - 1.0;
    float3 n2 = tex2D(BumpSampler, input.BumpUV2FH.xy).rgb * 2.0 - 1.0;
    float3 bumpN = normalize(n0 + n1 + n2);

    // Moderate bump — adds visible fine ripple without dominating wave shape
    float3 normal = normalize(float3(
        input.WaveNorm.x + bumpN.x * 0.22,
        input.WaveNorm.y,
        input.WaveNorm.z + bumpN.y * 0.22
    ));

    float3 V = normalize(input.ViewDir);
    float3 lightDir = normalize(float3(0.0, 0.78, 0.62));
    float viewDist = length(input.ViewDir);

    // Schlick fresnel (F0 = 0.02)
    float NdotV = saturate(dot(normal, -V));
    float fresnel = 0.02 + 0.98 * pow(1.0 - NdotV, 5.0);

    // Reflection — sky with horizon haze
    float3 R = reflect(V, normal);
    float ry = max(R.y, 0.0);
    float3 skyZenith  = float3(0.14, 0.26, 0.48);
    float3 skyHorizon = float3(0.40, 0.48, 0.58);
    float skyGrad = pow(1.0 - ry, 3.0);
    float3 reflected = lerp(skyZenith, skyHorizon, skyGrad);

    // Deep blue water body
    float depthFade = saturate(viewDist * 0.0015);
    float3 shallowColor = float3(0.012, 0.065, 0.120);
    float3 deepColor    = float3(0.005, 0.035, 0.070);
    float3 waterBody = lerp(shallowColor, deepColor, depthFade);

    // Subtle diffuse on slopes
    float NdotL = saturate(dot(normal, lightDir));
    waterBody += float3(0.008, 0.020, 0.015) * NdotL;

    // Fresnel blend
    float3 color = lerp(waterBody, reflected, fresnel);

    // Wave slope brightening — light catching wave faces
    float slope = 1.0 - saturate(input.WaveNorm.y);
    float waveH = input.BumpUV2FH.w;
    float slopeBright = saturate(slope * 3.0) * saturate(waveH * 1.5 + 0.3);
    color += float3(0.04, 0.06, 0.07) * slopeBright;

    // Specular — visible highlights on wave slopes
    float spec1 = pow(max(dot(R, lightDir), 0.0), 384.0);
    color += spec1 * 12.0 * float3(0.90, 0.93, 0.98);

    // Broader glow
    float spec2 = pow(max(dot(R, lightDir), 0.0), 28.0);
    color += spec2 * 0.10 * float3(0.65, 0.72, 0.82);

    // Fog
    color = lerp(color, FogColor, input.BumpUV2FH.z);

    // ACES tonemapping
    color = ACESFilm(color);

    // Gamma
    color = pow(max(color, 0.0), 1.0 / 2.2);

    return float4(color, 0.92);
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
