Shader "Hidden/TerraCraft/Modifier"
{
    Properties
    {
        _MainTex("Input", 2D) = "black" {}
        _BlendOp("Blend Operation", float) = 0
        _Opacity("Opacity / 100", float) = 1
        _Heightmap ("Heightmap", 2D) = "black" {}
        _NormalMap("NormalMap", 2D) = "bump" {}
        _MaskTexture("Mask", 2D) = "white" {}

        _MinMaxHeight("MinMaxHeight", Vector) = (0,1,0,0)
        _MinMaxCurvature("MinMaxCurvature", Vector) = (0,1,0,0)
        _MinMaxSlope("MinMaxSlope", Vector) = (0,1,0,0)

        _HeightmapScale("Height scale", float) = 0
    }

    HLSLINCLUDE

    #include "UnityCG.cginc"

    float _BlendOp;
    float _Opacity;
    
    sampler2D _MainTex;
    sampler2D _MaskTexture;
    
    sampler2D _Heightmap;
    float4 _Heightmap_TexelSize;
    
    sampler2D _NormalMap;
    float4 _NormalMap_TexelSize;
    
    float4 _MinMaxHeight;
    float4 _MinMaxCurvature;
    float4 _MinMaxSlope;

    float _HeightmapScale;
    float _CurvatureRadius;
    uint _CurvatureSolver;
    
    float3 _Direction;
    float4 _DirectionLevels;
    
    float4 _NoiseScaleOffset;
    float4 _Levels;
    uint _NoiseType;
    
    float _Channel;
    float2 _TilingParams;
    float4 _TerrainPosScale;
    float4 _TerrainBounds;

    #define BASE _BlendOp == 0 || _BlendOp == 1 || _BlendOp == 3 ? 0.0 : 1.0

    struct Varyings
    {
        float2 uv : TEXCOORD0;
        float4 vertex : SV_POSITION;
    };
    
    Varyings vert(float4 vertex : POSITION, float2 uv : TEXCOORD0)
    {
        Varyings o;
        o.vertex = UnityObjectToClipPos(vertex);
        o.uv = uv;
        return o;
    }

    // ============================================================
    // HEIGHT MASK
    // ============================================================
    float HeightMask(float heightmap, float2 uv, float4 params)
    {
        float minEnd = (params.x - params.z);
        float minWeight = saturate((minEnd - (heightmap - params.x)) / (minEnd - params.x));
        float maxEnd = params.y + params.w;
        float maxWeight = saturate((maxEnd - (heightmap - params.y)) / (maxEnd - params.y));
        return saturate(maxWeight * minWeight);
    }

    // ============================================================
    // SLOPE MASK
    // ============================================================
    float SlopeMask(sampler2D heightmap, float2 uv, float4 params, float texelSize)
    {
        float width = texelSize;
        uint mip = 0;

        float centerHeight = tex2D(heightmap, uv).r;
        float posX = tex2Dlod(heightmap, float4(uv.x + width, uv.y, 0, mip)).r - centerHeight;
        float negX = tex2Dlod(heightmap, float4(uv.x - width, uv.y, 0, mip)).r - centerHeight;
        float posY = tex2Dlod(heightmap, float4(uv.x, uv.y + width, 0, mip)).r - centerHeight;
        float negY = tex2Dlod(heightmap, float4(uv.x, uv.y - width, 0, mip)).r - centerHeight;

        float slope = sqrt((posX * posX) + (posY * posY) + (negX * negX) + (negY * negY)) * 90;

        float minEnd = params.x / 90 - params.z / 90;
        float minWeight = saturate((minEnd - (slope - params.x / 90)) / (minEnd - params.x / 90));
        float maxEnd = params.y / 90 + params.w / 90;
        float maxWeight = saturate((maxEnd - (slope - params.y / 90)) / (maxEnd - params.y / 90));

        return saturate(maxWeight * minWeight);
    }

    // ============================================================
    // CURVATURE MASK
    // ============================================================
    float4 RemapNormals(float4 normals)
    {
        normals.xyz = normals.xyz * 2.0 - 1.0;
        return normals;
    }

    float CurvatureFromNormal(sampler2D normals, sampler2D heightmap, float2 uv, float2 texelSize, uint mode)
    {
        uint mip = 0;
        float curvature = 0;
        
        if(mode == 1) //Hard
        {
            float3 normal = (tex2Dlod(normals, float4(uv.x, uv.y, 0, mip))).rgb;
            normal = normalize(normal);

            const float3 right = (tex2Dlod(normals, float4(uv.x + texelSize.x, uv.y, 0, mip))).xyz;
            const float3 left = (tex2Dlod(normals, float4(uv.x - texelSize.x, uv.y, 0, mip))).xyz;
            const float3 up = (tex2Dlod(normals, float4(uv.x, uv.y + texelSize.x, 0, mip))).xyz;
            const float3 down = (tex2Dlod(normals, float4(uv.x, uv.y - texelSize.x, 0, mip))).xyz;
        
            float3 xpos = normal + right;
            float3 xneg = normal - left;
            float3 ypos = normal + up;
            float3 yneg = normal - down;

            curvature = (cross(xneg, xpos).x - cross(yneg, ypos).y) * 4.0;
            curvature = 1 - (curvature * 0.5 + 0.5);
        }
        else //Soft
        {
            float right = RemapNormals(tex2Dlod(normals, float4(uv.x + texelSize.x, uv.y, 0, mip))).x;
            float left = RemapNormals(tex2Dlod(normals, float4(uv.x - texelSize.x, uv.y, 0, mip))).x;
            float x = (right - left) + 0.5;

            float up = RemapNormals(tex2Dlod(normals, float4(uv.x, uv.y + texelSize.x, 0, mip))).y;
            float down = RemapNormals(tex2Dlod(normals, float4(uv.x, uv.y - texelSize.x, 0, mip))).y;
            float y = (up - down) + 0.5;

            curvature = (y < 0.5) ? 2.0 * x * y : 1.0 - 2.0 * (1.0 - x) * (1.0 - y);
        }

        return curvature;
    }

    float CurvatureMask(sampler2D normalMap, sampler2D heightmap, float2 uv, float4 params, float texelSize, uint mode)
    {
        float convexity = CurvatureFromNormal(normalMap, heightmap, uv, texelSize, mode);
        float curvature = (convexity - (1.0 - convexity)) * 0.5 + 0.5;
                    
        float minEnd = (params.x - params.z);
        float minWeight = saturate((minEnd - (curvature - params.x)) / (minEnd - params.x));
        float maxEnd = params.y + params.w;
        float maxWeight = saturate((maxEnd - (curvature - params.y)) / (maxEnd - params.y));

        return saturate(maxWeight * minWeight);
    }

    // ============================================================
    // NOISE FUNCTIONS
    // ============================================================
    float2 GradientNoiseDir(float2 x)
    {
        const float2 k = float2(0.3183099, 0.3678794);
        x = x * k + k.yx;
        return -1.0 + 2.0 * frac(16.0 * k * frac(x.x * x.y * (x.x + x.y)));
    }

    float GradientNoise(float2 uv)
    {
        float2 p = uv;
        float2 i = floor(p);
        float2 f = frac(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return lerp(lerp(dot(GradientNoiseDir(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
            dot(GradientNoiseDir(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
            lerp(dot(GradientNoiseDir(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
                dot(GradientNoiseDir(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x), u.y);
    }

    float Unity_SimpleNoise_RandomValue(float2 uv)
    {
        return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    }

    float Unity_SimpleNoise_Interpolate(float a, float b, float t)
    {
        return (1.0 - t) * a + (t * b);
    }

    float Unity_SimpleNoise_ValueNoise(float2 uv)
    {
        float2 i = floor(uv);
        float2 f = frac(uv);
        f = f * f * (3.0 - 2.0 * f);

        float2 c0 = i + float2(0.0, 0.0);
        float2 c1 = i + float2(1.0, 0.0);
        float2 c2 = i + float2(0.0, 1.0);
        float2 c3 = i + float2(1.0, 1.0);
        float r0 = Unity_SimpleNoise_RandomValue(c0);
        float r1 = Unity_SimpleNoise_RandomValue(c1);
        float r2 = Unity_SimpleNoise_RandomValue(c2);
        float r3 = Unity_SimpleNoise_RandomValue(c3);

        float bottomOfGrid = Unity_SimpleNoise_Interpolate(r0, r1, f.x);
        float topOfGrid = Unity_SimpleNoise_Interpolate(r2, r3, f.x);
        float t = Unity_SimpleNoise_Interpolate(bottomOfGrid, topOfGrid, f.y);
        return t;
    }

    float SimplexNoise(float2 uv)
    {
        float t = 0.0;
        uv *= 2;

        float freq = pow(2.0, 0.0);
        float amp = pow(0.5, 3.0 - 0.0);
        t += Unity_SimpleNoise_ValueNoise(float2(uv.x / freq, uv.y / freq)) * amp;

        freq = pow(2.0, 1.0);
        amp = pow(0.5, 3.0 - 1.0);
        t += Unity_SimpleNoise_ValueNoise(float2(uv.x / freq, uv.y / freq)) * amp;

        freq = pow(2.0, 2.0);
        amp = pow(0.5, 3.0 - 2.0);
        t += Unity_SimpleNoise_ValueNoise(float2(uv.x / freq, uv.y / freq)) * amp;

        return t;
    }

    ENDHLSL

    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" }
        Blend [_SrcFactor][_DstFactor]
        BlendOp [_BlendOp]
        ColorMask RGBA
        AlphaToMask Off
        
        // ============================================================
        // PASS 0: HEIGHT
        // ============================================================
        Pass
        {
            Name "Height"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            fixed4 frag(Varyings i) : SV_Target
            {
                float heightmap = tex2D(_Heightmap, i.uv).r * _HeightmapScale;
                float mask = HeightMask(heightmap, i.uv, _MinMaxHeight);
                return lerp(BASE, mask, _Opacity);
            }
            ENDHLSL
        }

        // ============================================================
        // PASS 1: SLOPE
        // ============================================================
        Pass
        {
            Name "Slope"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            fixed4 frag(Varyings i) : SV_Target
            {
                float mask = SlopeMask(_Heightmap, i.uv, _MinMaxSlope, _Heightmap_TexelSize.x);
                return lerp(BASE, mask, _Opacity);
            }
            ENDHLSL
        }

        // ============================================================
        // PASS 2: CURVATURE
        // ============================================================
        Pass
        {
            Name "Curvature"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            fixed4 frag(Varyings i) : SV_Target
            {
                float mask = CurvatureMask(_NormalMap, _Heightmap, i.uv, _MinMaxCurvature, 
                    _NormalMap_TexelSize.x * _CurvatureRadius, _CurvatureSolver);
                return lerp(BASE, mask, _Opacity);
            }
            ENDHLSL
        }

        // ============================================================
        // PASS 3: TEXTURE MASK
        // ============================================================
        Pass
        {
            Name "TextureMask"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            fixed4 frag(Varyings i) : SV_Target
            {
                float2 boundsUV = (_TerrainPosScale.zw * i.uv) + _TerrainPosScale.xy;
                float2 uv = lerp(i.uv * _TilingParams.x, boundsUV, _TilingParams.y);
                float mask = tex2D(_MaskTexture, uv)[_Channel];
                return lerp(BASE, mask, _Opacity);
            }
            ENDHLSL
        }

        // ============================================================
        // PASS 4: NOISE
        // ============================================================
        Pass
        {
            Name "Noise"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            fixed4 frag(Varyings i) : SV_Target
            {
                float2 boundsUV = (_TerrainPosScale.zw * i.uv) + _TerrainPosScale.xy;
                float2 coords = (boundsUV.xy + _NoiseScaleOffset.zw) * _NoiseScaleOffset.xy * _TerrainBounds.zw;

                float mask = 0;
                if (_NoiseType == 1)
                    mask = GradientNoise(coords) * 0.5 + 0.5;
                if (_NoiseType == 0)
                    mask = SimplexNoise(coords);

                mask = smoothstep(_Levels.x, _Levels.y, mask);
                return lerp(BASE, mask, _Opacity);
            }
            ENDHLSL
        }

        // ============================================================
        // PASS 5: DIRECTION
        // ============================================================
        Pass
        {
            Name "Direction"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            fixed4 frag(Varyings i) : SV_Target
            {
                float3 normal = RemapNormals(tex2Dlod(_NormalMap, float4(i.uv.x, i.uv.y, 0, 0))).xyz;
                float aspect = dot(_Direction, -normal);
                float mask = smoothstep(_DirectionLevels.x, _DirectionLevels.y, aspect);
                return lerp(BASE, mask, _Opacity);
            }
            ENDHLSL
        }
    }
}