// Water_TropicalSea.fx - Bright tropical ocean with 4-octave directional FBM
// Fast small waves, HSV color grading, per-octave directional propagation
// with scene lighting
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
float3 LightDirection;
float3 LightColor;

// ============================================================
// Procedural wave functions (tropical variant - different hash)
// ============================================================

float hash(float2 p)
{
    float h = dot(p, float2(127.1, 311.7));
    return frac(sin(h) * 83758.5469);
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

// 4-octave tropical FBM with per-octave directional propagation
// Fast (high time multipliers), small freq (0.30), low amp (0.35)
// Asymmetric rotation matrix (1.7, -1.2, 1.2, 1.4)
float seaHeight(float2 xz, float time)
{
    float freq = 0.30;
    float amp = 0.35;
    float choppy = 2.0;
    float2 uv = xz;
    uv.x *= 0.75;

    float h = 0.0;
    float d;

    // Octave 0 - main tropical ripples
    d  = sea_octave((uv + time * float2(1.20, 0.50)) * freq, choppy);
    d += sea_octave((uv - time * float2(0.40, 1.10)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.7, -1.2, 1.2, 1.4));
    freq *= 1.9; amp *= 0.32; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 1 - cross ripples
    d  = sea_octave((uv + time * float2(0.80, 1.30)) * freq, choppy);
    d += sea_octave((uv - time * float2(1.00, 0.30)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.7, -1.2, 1.2, 1.4));
    freq *= 1.9; amp *= 0.32; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 2 - fine shimmer
    d  = sea_octave((uv + time * float2(1.40, 0.70)) * freq, choppy);
    d += sea_octave((uv - time * float2(0.60, 1.30)) * freq, choppy);
    h += d * amp;
    uv = mul(uv, float2x2(1.7, -1.2, 1.2, 1.4));
    freq *= 1.9; amp *= 0.32; choppy = lerp(choppy, 1.0, 0.2);

    // Octave 3 - sparkle detail
    d  = sea_octave((uv + time * float2(0.90, 1.10)) * freq, choppy);
    d += sea_octave((uv - time * float2(1.20, 0.60)) * freq, choppy);
    h += d * amp;

    return h;
}

// ============================================================
// HSV color space conversion
// ============================================================

float3 rgb2hsv(float3 c)
{
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.zy, K.wz), float4(c.yz, K.xy), step(c.z, c.y));
    float4 q = lerp(float4(p.xyw, c.x), float4(c.x, p.yzx), step(p.x, c.x));
    float dd = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * dd + e)), dd / (q.x + e), q.x);
}

float3 hsv2rgb(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
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

    float eps = 3.5;
    float hx = seaHeight(pos.xz + float2(eps, 0.0), time);
    float hz = seaHeight(pos.xz + float2(0.0, eps), time);
    output.WaveNorm = normalize(float3(h - hx, eps, h - hz));

    output.Position = mul(float4(pos, 1.0), ViewProj);

    float bt = time * 0.55;
    output.BumpUV01.xy = pos.xz * 0.038 + float2(bt * 0.28, bt * 0.18);
    output.BumpUV01.zw = pos.xz * 0.076 + float2(-bt * 0.18, bt * 0.45);
    output.BumpUV2FH.xy = pos.xz * 0.155 + float2(bt * 0.38, -bt * 0.28);

    float3 viewVec = pos - CamPos;
    output.ViewDir = viewVec;
    output.BumpUV2FH.z = saturate((length(viewVec) - FogStart) / max(FogEnd - FogStart, 0.001));
    output.BumpUV2FH.w = h;

    return output;
}

float seaDiffuse(float3 n, float3 l, float p)
{
    return pow(dot(n, l) * 0.4 + 0.6, p);
}

float4 WaterPS(VS_OUTPUT input) : COLOR
{
    float3 n0 = tex2D(BumpSampler, input.BumpUV01.xy).rgb * 2.0 - 1.0;
    float3 n1 = tex2D(BumpSampler, input.BumpUV01.zw).rgb * 2.0 - 1.0;
    float3 n2 = tex2D(BumpSampler, input.BumpUV2FH.xy).rgb * 2.0 - 1.0;
    float3 bumpN = normalize(n0 + n1 + n2);

    float3 normal = normalize(float3(
        input.WaveNorm.x + bumpN.x * 0.28,
        input.WaveNorm.y,
        input.WaveNorm.z + bumpN.y * 0.28
    ));

    float3 V = normalize(input.ViewDir);
    float3 lightDir = normalize(-LightDirection);
    float viewDist = length(input.ViewDir);

    // Cubic fresnel * 0.45
    float facing = saturate(1.0 - dot(normal, -V));
    float fresnel = facing * facing * facing * 0.45;

    float3 R = reflect(V, normal);

    // Bright tropical sky
    float3 skyE = R;
    skyE.y = max(skyE.y, 0.0);
    float ey = skyE.y;
    float sc = 1.0 - ey;
    float3 reflected = float3(sc * sc, 1.0 - ey, 0.6 + (1.0 - ey) * 0.4) * 0.99 * LightColor;

    // Bright teal base with green-cyan diffuse
    float3 refracted = float3(0.08, 0.22, 0.25)
        + seaDiffuse(normal, lightDir, 80.0) * float3(0.5, 0.85, 0.65) * 0.25 * LightColor;

    float3 color = lerp(refracted, reflected, fresnel);

    // Height-based coloring with distance attenuation
    float waveH = input.BumpUV2FH.w;
    float atten = max(1.0 - dot(input.ViewDir, input.ViewDir) * 0.001, 0.0);
    color += float3(0.5, 0.85, 0.65) * max(waveH - 0.5, 0.0) * 0.15 * atten * LightColor;

    // Thin crest ridge
    float slope = 1.0 - saturate(input.WaveNorm.y);
    float ridge = saturate(max(waveH, 0.0) * 1.5) * saturate(slope * 5.0);
    color += float3(0.10, 0.12, 0.14) * ridge * LightColor;

    // Tight sparkly specular (power 120)
    float spec = pow(max(dot(R, lightDir), 0.0), 120.0);
    float specNorm = (120.0 + 8.0) / 25.13;
    color += spec * specNorm * 0.4 * LightColor;

    // Fog
    color = lerp(color, FogColor, input.BumpUV2FH.z);

    // Gamma
    color = pow(max(color, 0.0), 0.75);

    // HSV post-processing for stylized tropical look
    float3 hsv = rgb2hsv(color);
    hsv.y += 0.15;  // boost saturation
    hsv.x -= 0.02;  // slight hue shift toward cyan
    color = hsv2rgb(hsv);

    return float4(color, 0.85);
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
