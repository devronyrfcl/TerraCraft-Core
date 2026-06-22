sampler2D _MainTex;
sampler2D _Heightmap;
sampler2D _NormalMap;
float4 _Heightmap_TexelSize;
float _HeightmapScale;
float4 _TerrainPosScale;
float4 _TerrainBounds;

int _SrcFactor;
int _DstFactor;
int _BlendOp;
float _Opacity;

float4 _MinMaxHeight;
float4 _MinMaxSlope;
float4 _MinMaxCurvature;
float3 _Direction;
float2 _DirectionLevels;
float4 _NoiseScaleOffset;
float4 _Levels;
sampler2D _MaskTexture;
float4 _TilingParams;
int _Channel;

struct appdata
{
    float4 vertex : POSITION;
    float2 uv : TEXCOORD0;
};
struct v2f
{
    float2 uv : TEXCOORD0;
    float4 vertex : SV_POSITION;
};

v2f vert(appdata v)
{
    v2f o;
    o.vertex = UnityObjectToClipPos(v.vertex);
    o.uv = v.uv;
    return o;
}

float ApplyBlend(float src, float dst)
{
    float result = 0;
    switch (_BlendOp)
    {
        case 0:
            result = src * dst;
            break;
        case 1:
            result = src + dst;
            break;
        case 2:
            result = src - dst;
            break;
        case 3:
            result = min(src, dst);
            break;
        case 4:
            result = max(src, dst);
            break;
        default:
            result = src * dst;
            break;
    }
    return lerp(dst, result, _Opacity);
}

float4 frag_height(v2f i) : SV_Target
{
    float height = tex2D(_Heightmap, i.uv).r * _HeightmapScale;
    float minMask = saturate((height - _MinMaxHeight.x) / _MinMaxHeight.z);
    float maxMask = saturate((_MinMaxHeight.y - height) / _MinMaxHeight.w);
    float mask = minMask * maxMask;
    return float4(ApplyBlend(mask, tex2D(_MainTex, i.uv).r), 0, 0, 1);
}

float4 frag_slope(v2f i) : SV_Target
{
    float3 normal = tex2D(_NormalMap, i.uv).xyz * 2 - 1;
    float slope = acos(normal.y) * 57.2958;
    float minMask = saturate((slope - _MinMaxSlope.x) / _MinMaxSlope.z);
    float maxMask = saturate((_MinMaxSlope.y - slope) / _MinMaxSlope.w);
    float mask = minMask * maxMask;
    return float4(ApplyBlend(mask, tex2D(_MainTex, i.uv).r), 0, 0, 1);
}

float4 frag_curvature(v2f i) : SV_Target
{
    float2 uv = i.uv;
    float hL = tex2D(_Heightmap, uv + float2(-_Heightmap_TexelSize.x, 0)).r;
    float hR = tex2D(_Heightmap, uv + float2(_Heightmap_TexelSize.x, 0)).r;
    float hD = tex2D(_Heightmap, uv + float2(0, -_Heightmap_TexelSize.y)).r;
    float hU = tex2D(_Heightmap, uv + float2(0, _Heightmap_TexelSize.y)).r;
    float curvature = abs(hL + hR + hD + hU - 4 * tex2D(_Heightmap, uv).r);
    float minMask = saturate((curvature - _MinMaxCurvature.x) / _MinMaxCurvature.z);
    float maxMask = saturate((_MinMaxCurvature.y - curvature) / _MinMaxCurvature.w);
    float mask = minMask * maxMask;
    return float4(ApplyBlend(mask, tex2D(_MainTex, i.uv).r), 0, 0, 1);
}

float4 frag_texturemask(v2f i) : SV_Target
{
    float2 uv = i.uv;
    if (_TilingParams.y > 0.5)
        uv = (i.uv * _TerrainBounds.zw) + _TerrainBounds.xy;
    uv *= _TilingParams.x;
    float mask = tex2D(_MaskTexture, uv)[_Channel];
    return float4(ApplyBlend(mask, tex2D(_MainTex, i.uv).r), 0, 0, 1);
}

float random(float2 st)
{
    return frac(sin(dot(st.xy, float2(12.9898, 78.233))) * 43758.5453123);
}
float noise(float2 st)
{
    float2 i = floor(st), f = frac(st);
    float a = random(i), b = random(i + float2(1, 0)), c = random(i + float2(0, 1)), d = random(i + float2(1, 1));
    float2 u = f * f * (3 - 2 * f);
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float4 frag_noise(v2f i) : SV_Target
{
    float mask = noise(i.uv * _NoiseScaleOffset.xy + _NoiseScaleOffset.zw);
    mask = saturate((mask - _Levels.x) / (_Levels.y - _Levels.x + 0.0001));
    return float4(ApplyBlend(mask, tex2D(_MainTex, i.uv).r), 0, 0, 1);
}

float4 frag_direction(v2f i) : SV_Target
{
    float3 normal = tex2D(_NormalMap, i.uv).xyz * 2 - 1;
    float dotProduct = dot(normal, normalize(_Direction)) * 0.5 + 0.5;
    float mask = saturate((dotProduct - _DirectionLevels.x) / (_DirectionLevels.y - _DirectionLevels.x + 0.0001));
    return float4(ApplyBlend(mask, tex2D(_MainTex, i.uv).r), 0, 0, 1);
}