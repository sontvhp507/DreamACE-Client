// Water_OceanRealistic.fx - Realistic ocean inspired by Shadertoy deep ocean
// 5-octave FBM with deep-water dispersion (large waves propagate faster)
// Subsurface scattering, ACES tonemapping, high-shininess specular, foam
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

// 5-octave FBM with per-octave DECREASING time speed
// Deep-water dispersion: large swells propagate faster than small ripples
// amp *= 0.5 preserves detail in higher octaves (vs 0.30 previously)
// Per-octave directional propagation breaks standing wave patterns
float seaHeight(float2 xz, float time)
{
    float freq   = 0.16;
    float amp    = 0.6;
    float choppy = 4.0;
    float2 uv = xz;
    uv.x *= 0.75;

    float h = 0.0;
    float d;

    // Octave 0 — dominant swell, fastest propagation (speed 0.40)
    d  = sea_octave((uv + time * 0.40 * float2( 0.78, 0.42)) * freq, choppy);
    d += sea_octave((uv - time * 0.40 * float2( 0.35, 0.68)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.75; amp *= 0.5; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 1 — cross swell (speed 0.33)
    d  = sea_octave((uv + time * 0.33 * float2( 0.55, 0.82)) * freq, choppy);
    d += sea_octave((uv - time * 0.33 * float2( 0.80, 0.30)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.75; amp *= 0.5; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 2 — medium chop (speed 0.27)
    d  = sea_octave((uv + time * 0.27 * float2( 0.90, 0.15)) * freq, choppy);
    d += sea_octave((uv - time * 0.27 * float2( 0.20, 0.92)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.75; amp *= 0.5; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 3 — fine wind waves (speed 0.20)
    d  = sea_octave((uv + time * 0.20 * float2( 0.30, 0.72)) * freq, choppy);
    d += sea_octave((uv - time * 0.20 * float2( 0.68, 0.45)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.6, 1.2, -1.2, 1.6));
    freq *= 1.75; amp *= 0.5; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 4 — micro ripples, slowest propagation (speed 0.14)
    d  = sea_octave((uv + time * 0.14 * float2( 0.62, 0.55)) * freq, choppy);
    d += sea_octave((uv - time * 0.14 * float2( 0.48, 0.70)) * freq, choppy);
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

    // Finite-difference normal — tighter epsilon for more detail
    float eps = 2.0;
    float hx = seaHeight(pos.xz + float2(eps, 0.0), time);
    float hz = seaHeight(pos.xz + float2(0.0, eps), time);
    output.WaveNorm = normalize(float3(h - hx, eps, h - hz));

    output.Position = mul(float4(pos, 1.0), ViewProj);

    // 3-layer bump UVs with non-uniform irrational-ish scales
    float bt = time * 0.30;
    output.BumpUV01.xy = pos.xz * 0.035 + float2(bt * 0.24, bt * 0.16);
    output.BumpUV01.zw = pos.xz * 0.072 + float2(-bt * 0.18, bt * 0.38);
    output.BumpUV2FH.xy = pos.xz * 0.15  + float2(bt * 0.32, -bt * 0.22);

    float3 viewVec = pos - CamPos;
    output.ViewDir = viewVec;
    output.BumpUV2FH.z = saturate((length(viewVec) - FogStart) / max(FogEnd - FogStart, 0.001));
    output.BumpUV2FH.w = h;

    return output;
}

// ACES filmic tonemapping curve
float3 ACESFilm(float3 x)
{
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

// Procedural sky with horizon haze
float3 getSkyColor(float3 e)
{
    e.y = max(e.y, 0.0);
    float3 skyZenith  = float3(0.15, 0.30, 0.60);
    float3 skyHorizon = float3(0.55, 0.65, 0.78);
    float grad = pow(1.0 - e.y, 3.0);
    return lerp(skyZenith, skyHorizon, grad);
}

float4 WaterPS(VS_OUTPUT input) : COLOR
{
    // 3-layer scrolling bump normals
    float3 n0 = tex2D(BumpSampler, input.BumpUV01.xy).rgb * 2.0 - 1.0;
    float3 n1 = tex2D(BumpSampler, input.BumpUV01.zw).rgb * 2.0 - 1.0;
    float3 n2 = tex2D(BumpSampler, input.BumpUV2FH.xy).rgb * 2.0 - 1.0;
    float3 bumpN = normalize(n0 + n1 + n2);

    // Strong bump perturbation for fine surface detail
    float3 normal = normalize(float3(
        input.WaveNorm.x + bumpN.x * 0.40,
        input.WaveNorm.y,
        input.WaveNorm.z + bumpN.y * 0.40
    ));

    float3 V = normalize(input.ViewDir);
    float3 lightDir = normalize(float3(0.0, 0.78, 0.62));
    float viewDist = length(input.ViewDir);

    // Schlick fresnel (F0 = 0.02 for water-air interface)
    float NdotV = saturate(dot(normal, -V));
    float fresnel = 0.02 + 0.98 * pow(1.0 - NdotV, 5.0);

    // Reflection
    float3 R = reflect(V, normal);
    float3 reflected = getSkyColor(R);

    // Water body color — depth-dependent deep ocean blue-green
    float depthFade = saturate(viewDist * 0.002);
    float3 waterBody = lerp(float3(0.0, 0.05, 0.12), float3(0.0, 0.02, 0.06), depthFade);

    // Height fraction for SSS intensity (map wave height to [0,1])
    float waveH = input.BumpUV2FH.w;
    float heightFrac = saturate((waveH + 1.2) / 2.4);
    waterBody += float3(0.0, 0.04, 0.02) * heightFrac;

    // Subsurface scattering — light passing through wave crests
    float3 sssDir = normalize(-lightDir + normal * 0.20);
    float sssVdotH = pow(saturate(dot(-V, sssDir)), 8.0) * 0.40;
    float3 sss = float3(0.05, 0.80, 0.70) * sssVdotH * heightFrac;

    // Combine water body + SSS
    float3 refracted = waterBody + sss;

    // Fresnel blend: refraction vs reflection
    float3 color = lerp(refracted, reflected, fresnel);

    // Foam on steep wave crests
    float slope = 1.0 - saturate(input.WaveNorm.y);
    float crestH = max(waveH, 0.0);
    float foam = saturate(crestH * 0.7) * saturate(slope * 6.0);
    foam = foam * foam;
    color = lerp(color, float3(0.75, 0.78, 0.82), foam * 0.5);

    // Primary specular — tight sun disk (Phong power 512)
    float spec = pow(max(dot(R, lightDir), 0.0), 512.0);
    color += spec * 60.0 * float3(1.0, 0.97, 0.90);

    // Secondary specular — broader sun glow
    float spec2 = pow(max(dot(R, lightDir), 0.0), 32.0);
    color += spec2 * 0.25 * float3(0.80, 0.76, 0.65);

    // Fog
    color = lerp(color, FogColor, input.BumpUV2FH.z);

    // ACES filmic tonemapping (HDR → SDR)
    color = ACESFilm(color);

    // Gamma correction (linear → sRGB)
    color = pow(max(color, 0.0), 1.0 / 2.2);

    return float4(color, 0.90);
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
