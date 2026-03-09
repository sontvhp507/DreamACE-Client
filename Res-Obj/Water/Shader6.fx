// Water_Seascape.fx - Classic ocean with 4-octave directional FBM
// Per-octave directional wave propagation for natural random wave crests
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
// Procedural wave functions
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

float sea_octave(float2 uv, float choppy)
{
    uv += noise(uv);
    float2 wv = 1.0 - abs(sin(uv));
    float2 swv = abs(cos(uv));
    wv = lerp(wv, swv, wv);
    return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

// 4-octave FBM with per-octave DIRECTIONAL wave propagation
// Each octave pair travels in different directions creating natural randomness
// instead of standing-wave tiled patterns from uniform time*0.8
float seaHeight(float2 xz, float time)
{
    float freq = 0.14;
    float amp = 0.6;
    float choppy = 2.2;
    float2 uv = xz;
    uv.x *= 0.75;

    float h = 0.0;
    float d;

    // Octave 0 - primary swell NE / counter-swell SW
    d  = sea_octave((uv + time * float2(0.80, 0.40)) * freq, choppy);
    d += sea_octave((uv - time * float2(0.30, 0.70)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.9; amp *= 0.35; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 1 - cross waves at different angle
    d  = sea_octave((uv + time * float2(0.50, 0.90)) * freq, choppy);
    d += sea_octave((uv - time * float2(0.85, 0.25)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.9; amp *= 0.35; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 2 - fine detail with faster diagonal propagation
    d  = sea_octave((uv + time * float2(1.10, 0.20)) * freq, choppy);
    d += sea_octave((uv - time * float2(0.15, 1.05)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.9; amp *= 0.35; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 3 - micro ripples
    d  = sea_octave((uv + time * float2(0.70, 0.65)) * freq, choppy);
    d += sea_octave((uv - time * float2(0.55, 0.90)) * freq, choppy);
    h += d * amp;

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
    float eps = 3.0;
    float hx = seaHeight(pos.xz + float2(eps, 0.0), time);
    float hz = seaHeight(pos.xz + float2(0.0, eps), time);
    output.WaveNorm = normalize(float3(h - hx, eps, h - hz));

    output.Position = mul(float4(pos, 1.0), ViewProj);

    // 3-layer bump UVs with non-uniform irrational-ish scales to prevent tiling
    float bt = time * 0.45;
    output.BumpUV01.xy = pos.xz * 0.035 + float2(bt * 0.28, bt * 0.17);
    output.BumpUV01.zw = pos.xz * 0.071 + float2(-bt * 0.19, bt * 0.42);
    output.BumpUV2FH.xy = pos.xz * 0.15  + float2(bt * 0.37, -bt * 0.26);

    float3 viewVec = pos - CamPos;
    output.ViewDir = viewVec;
    output.BumpUV2FH.z = saturate((length(viewVec) - FogStart) / max(FogEnd - FogStart, 0.001));
    output.BumpUV2FH.w = h;

    return output;
}

float3 getSkyColor(float3 e)
{
    float ey = (max(e.y, 0.0) * 0.8 + 0.2) * 0.8;
    float sc = 1.0 - ey;
    return float3(sc * sc, sc, 0.6 + sc * 0.4) * 0.95;
}

float seaDiffuse(float3 n, float3 l, float p)
{
    return pow(dot(n, l) * 0.4 + 0.6, p);
}

float4 WaterPS(VS_OUTPUT input) : COLOR
{
    // 3-layer scrolling bump normals
    float3 n0 = tex2D(BumpSampler, input.BumpUV01.xy).rgb * 2.0 - 1.0;
    float3 n1 = tex2D(BumpSampler, input.BumpUV01.zw).rgb * 2.0 - 1.0;
    float3 n2 = tex2D(BumpSampler, input.BumpUV2FH.xy).rgb * 2.0 - 1.0;
    float3 bumpN = normalize(n0 + n1 + n2);

    // Stronger bump perturbation for fine surface detail
    float3 normal = normalize(float3(
        input.WaveNorm.x + bumpN.x * 0.35,
        input.WaveNorm.y,
        input.WaveNorm.z + bumpN.y * 0.35
    ));

    float3 V = normalize(input.ViewDir);
    float3 lightDir = normalize(float3(0.0, 0.78, 0.62));
    float viewDist = length(input.ViewDir);

    // Schlick fresnel (pow5)
    float NdotV = saturate(dot(normal, -V));
    float fresnel = 0.02 + 0.98 * pow(1.0 - NdotV, 5.0);

    float3 R = reflect(V, normal);
    float3 reflected = getSkyColor(R);

    // Depth-varied base color (darker further away)
    float depthFade = saturate(viewDist * 0.002);
    float3 waterBase = lerp(float3(0.0, 0.04, 0.10), float3(0.0, 0.02, 0.06), depthFade);

    float3 refracted = waterBase
        + seaDiffuse(normal, lightDir, 80.0) * float3(0.3, 0.38, 0.25) * 0.10;

    float3 color = lerp(refracted, reflected, fresnel);

    // Height-based color variation (brighter near crests)
    float waveH = input.BumpUV2FH.w;
    float atten = max(1.0 - viewDist * viewDist * 0.00001, 0.0);
    color += float3(0.0, 0.04, 0.03) * saturate(waveH * 0.8) * atten;

    // Crest edge highlights
    float slope = 1.0 - saturate(input.WaveNorm.y);
    float ridge = saturate(max(waveH, 0.0) * 1.5) * saturate(slope * 5.0);
    color += float3(0.10, 0.12, 0.14) * ridge;

    // Specular - normalized Phong power 60
    float spec = pow(max(dot(R, lightDir), 0.0), 60.0);
    float specNorm = (60.0 + 8.0) / 25.13;
    color += spec * specNorm * float3(1.0, 0.95, 0.8);

    // Fog
    color = lerp(color, FogColor, input.BumpUV2FH.z);

    // Gamma
    color = pow(max(color, 0.0), 0.65);

    return float4(color, 0.88);
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
