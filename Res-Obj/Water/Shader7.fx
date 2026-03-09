// Water_ClearOcean.fx - Clear bright ocean with 5-octave billow noise
// Per-octave time variation for non-repeating turbulent patterns
// Fresnel Schlick pow5, bright blue-teal palette, specular highlights
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
// Hash-based 2D noise (0..1 range)
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
    return lerp(
        lerp(hash(i), hash(i + float2(1.0, 0.0)), u.x),
        lerp(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), u.x),
        u.y);
}

// ============================================================
// 5-octave 3D rotation billow FBM with per-octave time variation
// Each octave uses a different time direction to break periodicity
// billow: abs(noise - 0.5) * 2 creates crinkly turbulence
// ============================================================

float seaHeight(float2 xz, float time)
{
    float3 pos = float3(xz.x, 0.0, xz.y);
    pos *= 0.2;
    float f = 0.0;

    // Octave 1 - main turbulence
    pos += time * float3(0.00, 0.12, 0.12);
    pos = (pos.yzx + pos.zyx * float3(1.0, -1.0, 1.0)) / 1.41421356;
    f = f * 2.0 + abs(noise(pos.xz) - 0.5) * 2.0;
    pos *= 2.0;

    // Octave 2 - cross turbulence (different time direction)
    pos += time * float3(0.08, 0.00, -0.06);
    pos = (pos.yzx + pos.zyx * float3(1.0, -1.0, 1.0)) / 1.41421356;
    f = f * 2.0 + abs(noise(pos.xz) - 0.5) * 2.0;
    pos *= 2.0;

    // Octave 3 - diagonal turbulence
    pos += time * float3(-0.05, 0.10, 0.04);
    pos = (pos.yzx + pos.zyx * float3(1.0, -1.0, 1.0)) / 1.41421356;
    f = f * 2.0 + abs(noise(pos.xz) - 0.5) * 2.0;
    pos *= 2.0;

    // Octave 4 - fine detail
    pos += time * float3(0.04, -0.03, 0.09);
    pos = (pos.yzx + pos.zyx * float3(1.0, -1.0, 1.0)) / 1.41421356;
    f = f * 2.0 + abs(noise(pos.xz) - 0.5) * 2.0;
    pos *= 2.0;

    // Octave 5 - micro detail
    pos += time * float3(-0.07, 0.06, 0.03);
    pos = (pos.yzx + pos.zyx * float3(1.0, -1.0, 1.0)) / 1.41421356;
    f = f * 2.0 + abs(noise(pos.xz) - 0.5) * 2.0;

    f /= 32.0;
    return (0.5 - f) * 1.8;
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

    float eps = 3.0;
    float hx = seaHeight(pos.xz + float2(eps, 0.0), time);
    float hz = seaHeight(pos.xz + float2(0.0, eps), time);
    output.WaveNorm = normalize(float3(h - hx, eps, h - hz));

    output.Position = mul(float4(pos, 1.0), ViewProj);

    float bt = time * 0.3;
    output.BumpUV01.xy = pos.xz * 0.024 + float2(bt * 0.18, bt * 0.11);
    output.BumpUV01.zw = pos.xz * 0.058 + float2(-bt * 0.11, bt * 0.32);
    output.BumpUV2FH.xy = pos.xz * 0.12 + float2(bt * 0.28, -bt * 0.18);

    float3 viewVec = pos - CamPos;
    output.ViewDir = viewVec;
    output.BumpUV2FH.z = saturate((length(viewVec) - FogStart) / max(FogEnd - FogStart, 0.001));
    output.BumpUV2FH.w = h;

    return output;
}

float4 WaterPS(VS_OUTPUT input) : COLOR
{
    float3 n0 = tex2D(BumpSampler, input.BumpUV01.xy).rgb * 2.0 - 1.0;
    float3 n1 = tex2D(BumpSampler, input.BumpUV01.zw).rgb * 2.0 - 1.0;
    float3 n2 = tex2D(BumpSampler, input.BumpUV2FH.xy).rgb * 2.0 - 1.0;
    float3 bumpN = normalize(n0 + n1 + n2);

    // Moderate bump perturbation
    float3 normal = normalize(float3(
        input.WaveNorm.x + bumpN.x * 0.32,
        input.WaveNorm.y,
        input.WaveNorm.z + bumpN.y * 0.32
    ));

    float3 V = normalize(input.ViewDir);
    float3 lightDir = normalize(float3(0.0, 0.78, 0.62));
    float viewDist = length(input.ViewDir);

    // Fresnel (Schlick pow5)
    float NdotV = saturate(dot(normal, -V));
    float fresnel = 0.02 + 0.98 * pow(1.0 - NdotV, 5.0);

    // Bright clear sky reflection
    float3 R = reflect(V, normal);
    float ry = max(R.y, 0.0);
    float3 skyZenith  = float3(0.30, 0.50, 0.75);
    float3 skyHorizon = float3(0.55, 0.65, 0.78);
    float skyGrad = pow(1.0 - ry, 3.0);
    float3 reflected = lerp(skyZenith, skyHorizon, skyGrad);

    // Clear bright water body — teal-blue, transparent
    float depthFade = saturate(viewDist * 0.002);
    float3 shallowColor = float3(0.04, 0.14, 0.18);
    float3 deepColor    = float3(0.02, 0.08, 0.12);
    float3 waterBody = lerp(shallowColor, deepColor, depthFade);

    // Diffuse lighting
    float NdotL = saturate(dot(normal, lightDir));
    waterBody += float3(0.02, 0.05, 0.04) * NdotL;

    // Fresnel blend
    float3 color = lerp(waterBody, reflected, fresnel);

    // Wave slope brightening
    float waveHeight = max(input.BumpUV2FH.w, 0.0);
    float slope = 1.0 - saturate(input.WaveNorm.y);
    float slopeBright = saturate(slope * 3.0) * saturate(waveHeight * 1.5 + 0.2);
    color += float3(0.05, 0.08, 0.10) * slopeBright;

    // Light foam at crests
    float crestFoam = pow(saturate(waveHeight * 1.8) * saturate(slope * 4.0), 2.0);
    color = lerp(color, float3(0.80, 0.85, 0.90), crestFoam * 0.5);

    // Specular — sun highlight
    float spec = pow(max(dot(R, lightDir), 0.0), 128.0);
    color += spec * 3.0 * float3(1.0, 0.97, 0.92);

    // Broader glow
    float spec2 = pow(max(dot(R, lightDir), 0.0), 20.0);
    color += spec2 * 0.08 * float3(0.7, 0.75, 0.85);

    // Fog
    color = lerp(color, FogColor, input.BumpUV2FH.z);

    // Gamma (1/2.2)
    color = pow(max(color, 0.0), 0.4545);

    return float4(color, 0.72);
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
