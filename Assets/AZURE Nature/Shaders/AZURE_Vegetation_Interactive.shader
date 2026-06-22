// Modified from Raygeas/AZURE Vegetation
// Added: Interactive grass bending based on player/interactor positions
Shader "Raygeas/AZURE Vegetation Interactive"
{
    Properties
    {
        [Header(Rendering)][Space(5)]
        [Enum(UnityEngine.Rendering.BlendMode)] _SrcBlend("Src Blend", Float) = 1
        [Enum(UnityEngine.Rendering.BlendMode)] _DstBlend("Dst Blend", Float) = 0
        [Enum(Off, 0, On, 1)] _AlphaToMask("Alpha To Mask (MSAA)", Float) = 1
        [Enum(Off, 0, On, 1)] _ZWrite("ZWrite", Float) = 1
        
        [HideInInspector] _EmissionColor("Emission Color", Color) = (1,1,1,1)
        [Header(Maps)][Space(7)]_Texture00("Texture", 2D) = "white" {}
        _SmoothnessTexture1("Smoothness", 2D) = "white" {}
        _SnowMask("Snow Mask", 2D) = "white" {}
        [Header(Settings)][Space(5)]_Color1("Main Color", Color) = (1,1,1,0)
        _AlphaCutoff("Alpha Cutoff", Range( 0 , 1)) = 0.35
        _Smoothness("Smoothness", Range( 0 , 1)) = 0
        [Header(Second Color Settings)][Space(5)][Toggle(_COLOR2ENABLE_ON)] _Color2Enable("Enable", Float) = 0
        _Color2("Second Color", Color) = (0,0,0,0)
        [KeywordEnum(Vertex_Position_Based,UV_Based)] _Color2OverlayType("Overlay Method", Float) = 0
        _Color2Level("Level", Float) = 0
        _Color2Fade("Fade", Range( -1 , 1)) = 0.5
        [Header(Show Settings)][Space(5)][Toggle(_SNOW_ON)] _SNOW("Enable", Float) = 0
        [KeywordEnum(World_Normal_Based,UV_Based)] _SnowOverlayType("Overlay Method", Float) = 0
        _SnowAmount("Amount", Range( 0 , 1)) = 0.5
        [Header(Wind Settings)][Space(5)][Toggle(_WIND_ON)] _WIND("Enable", Float) = 1
        _WindForce("Force", Range( 0 , 1)) = 0.3
        _WindWavesScale("Waves Scale", Range( 0 , 1)) = 0.25
        _WindSpeed("Speed", Range( 0 , 1)) = 0.5
        [Toggle(_FIXTHEBASEOFFOLIAGE_ON)] _Fixthebaseoffoliage("Anchor the foliage base", Float) = 0

        [Header(Interactive Grass)][Space(5)]
        [Toggle(_INTERACTIVE_ON)] _Interactive("Enable Interaction", Float) = 1
        _InteractionRadius("Interaction Radius", Range(0.1, 5.0)) = 1.0
        _InteractionStrength("Interaction Strength", Range(0, 5)) = 2.0
        _InteractionFalloff("Falloff Sharpness", Range(0.1, 5.0)) = 2.0
        _RecoverySpeed("Recovery Speed", Range(0, 1)) = 0.3

        [Header(Translucency)][Space(5)][Toggle(_TRANCLUSENCYENABLE_ON)] _TranclusencyEnable("Enable", Float) = 1
        _TranslucencyInt("Translucency Int", Range( 0 , 100)) = 1
        [HideInInspector] _texcoord( "", 2D ) = "white" {}

        [HideInInspector][ToggleOff] _SpecularHighlights("Specular Highlights", Float) = 1
        [HideInInspector][ToggleOff] _EnvironmentReflections("Environment Reflections", Float) = 1
        [HideInInspector][ToggleOff] _ReceiveShadows("Receive Shadows", Float) = 1.0

        [HideInInspector] _QueueOffset("_QueueOffset", Float) = 0
        [HideInInspector] _QueueControl("_QueueControl", Float) = -1

        [HideInInspector][NoScaleOffset] unity_Lightmaps("unity_Lightmaps", 2DArray) = "" {}
        [HideInInspector][NoScaleOffset] unity_LightmapsInd("unity_LightmapsInd", 2DArray) = "" {}
        [HideInInspector][NoScaleOffset] unity_ShadowMasks("unity_ShadowMasks", 2DArray) = "" {}
    }

    SubShader
    {
        LOD 0

        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="TransparentCutout" "Queue"="AlphaTest" "UniversalMaterialType"="Lit" }

        Cull Off
        ZWrite On
        ZTest LEqual
        Offset 0 , 0
        AlphaToMask Off

        HLSLINCLUDE
        #pragma target 4.5
        #pragma prefer_hlslcc gles

        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Filtering.hlsl"

        // ─────────────────────────────────────────────
        //  INTERACTIVE GRASS GLOBALS
        //  Set from C# via Shader.SetGlobalXxx each frame
        // ─────────────────────────────────────────────
        // Maximum simultaneous interactors (keep in sync with GrassInteractor.cs)
        #define MAX_INTERACTORS 8

        // Global arrays set by GrassInteractionManager.cs each frame
        float4 _InteractorPositions[MAX_INTERACTORS]; // xyz = world pos, w = unused
        int    _InteractorCount;                       // how many are active this frame

        // NOTE: _InteractionRadius / _InteractionStrength / _InteractionFalloff are
        // declared inside CBUFFER_START(UnityPerMaterial) in each pass — NOT here —
        // to avoid Metal "redefinition" errors.  We receive them as explicit params.

        // ─────────────────────────────────────────────
        //  Compute the XZ displacement caused by all
        //  active interactors for a given world position.
        //  vertexHeight : 0 at grass base, 1 at tip (UV.y)
        //  radius / strength / falloff come from the per-pass CBUFFER
        // ─────────────────────────────────────────────
        float3 ComputeInteractionDisplacement(float3 worldPos, float vertexHeight,
                                      float radius, float strength, float falloff)
        {
            float3 totalDisp = float3(0, 0, 0);

            for (int i = 0; i < MAX_INTERACTORS; i++) // note: loop all, not just _InteractorCount
            {
                float3 interactorPos = _InteractorPositions[i].xyz;
                float  bendStrength  = _InteractorPositions[i].w; // recovery factor

                float2 delta = worldPos.xz - interactorPos.xz;
                float  dist  = length(delta);

                if (dist < radius && dist > 0.001)
                {
                    float normDist     = dist / radius;
                    float influence    = pow(1.0 - normDist, falloff);
                    float2 pushDir     = delta / dist;
                    float heightFactor = vertexHeight * vertexHeight;

                    totalDisp.xz += pushDir * influence * strength * heightFactor * bendStrength;
                    totalDisp.y  -= influence * strength * 0.15 * heightFactor * bendStrength;
                }
            }

            return totalDisp;
        }

        // ─── Simplex noise (unchanged from original) ───────────────────────
        float3 mod3D289( float3 x ) { return x - floor( x / 289.0 ) * 289.0; }
        float4 mod3D289( float4 x ) { return x - floor( x / 289.0 ) * 289.0; }
        float4 permute( float4 x ) { return mod3D289( ( x * 34.0 + 1.0 ) * x ); }
        float4 taylorInvSqrt( float4 r ) { return 1.79284291400159 - r * 0.85373472095314; }
        float snoise( float3 v )
        {
            const float2 C = float2( 1.0 / 6.0, 1.0 / 3.0 );
            float3 i = floor( v + dot( v, C.yyy ) );
            float3 x0 = v - i + dot( i, C.xxx );
            float3 g = step( x0.yzx, x0.xyz );
            float3 l = 1.0 - g;
            float3 i1 = min( g.xyz, l.zxy );
            float3 i2 = max( g.xyz, l.zxy );
            float3 x1 = x0 - i1 + C.xxx;
            float3 x2 = x0 - i2 + C.yyy;
            float3 x3 = x0 - 0.5;
            i = mod3D289( i );
            float4 p = permute( permute( permute( i.z + float4( 0.0, i1.z, i2.z, 1.0 ) )
                              + i.y + float4( 0.0, i1.y, i2.y, 1.0 ) )
                              + i.x + float4( 0.0, i1.x, i2.x, 1.0 ) );
            float4 j  = p - 49.0 * floor( p / 49.0 );
            float4 x_ = floor( j / 7.0 );
            float4 y_ = floor( j - 7.0 * x_ );
            float4 x  = ( x_ * 2.0 + 0.5 ) / 7.0 - 1.0;
            float4 y  = ( y_ * 2.0 + 0.5 ) / 7.0 - 1.0;
            float4 h  = 1.0 - abs( x ) - abs( y );
            float4 b0 = float4( x.xy, y.xy );
            float4 b1 = float4( x.zw, y.zw );
            float4 s0 = floor( b0 ) * 2.0 + 1.0;
            float4 s1 = floor( b1 ) * 2.0 + 1.0;
            float4 sh = -step( h, 0.0 );
            float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
            float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
            float3 g0 = float3( a0.xy, h.x );
            float3 g1 = float3( a0.zw, h.y );
            float3 g2 = float3( a1.xy, h.z );
            float3 g3 = float3( a1.zw, h.w );
            float4 norm = taylorInvSqrt( float4( dot(g0,g0), dot(g1,g1), dot(g2,g2), dot(g3,g3) ) );
            g0 *= norm.x; g1 *= norm.y; g2 *= norm.z; g3 *= norm.w;
            float4 m  = max( 0.6 - float4( dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3) ), 0.0 );
            m = m * m; m = m * m;
            float4 px = float4( dot(x0,g0), dot(x1,g1), dot(x2,g2), dot(x3,g3) );
            return 42.0 * dot( m, px );
        }
        ENDHLSL

        // ════════════════════════════════════════════
        //  FORWARD PASS
        // ════════════════════════════════════════════
        Pass
        {
            Name "Forward"
            Tags { "LightMode"="UniversalForward" }

            Blend [_SrcBlend] [_DstBlend]
            ZWrite [_ZWrite]
            AlphaToMask [_AlphaToMask]
            Offset 0 , 0
            ColorMask RGBA
            AlphaToMask On

            HLSLPROGRAM

            #define _NORMAL_DROPOFF_TS 1
            #pragma shader_feature_local _RECEIVE_SHADOWS_OFF
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION
            #pragma multi_compile_instancing
            #pragma instancing_options renderinglayer
            #pragma multi_compile _ LOD_FADE_CROSSFADE
            #pragma multi_compile_fog
            #define ASE_FOG 1
            #define _ALPHATEST_ON 1
            #define ASE_SRP_VERSION 140007

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ EVALUATE_SH_MIXED EVALUATE_SH_VERTEX
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _DBUFFER_MRT1 _DBUFFER_MRT2 _DBUFFER_MRT3
            #pragma multi_compile _ _LIGHT_LAYERS
            #pragma multi_compile_fragment _ _LIGHT_COOKIES
            #pragma multi_compile _ _FORWARD_PLUS
            #pragma multi_compile _ LIGHTMAP_SHADOW_MIXING
            #pragma multi_compile _ SHADOWS_SHADOWMASK
            #pragma multi_compile _ DIRLIGHTMAP_COMBINED
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile _ DYNAMICLIGHTMAP_ON
            #pragma multi_compile_fragment _ DEBUG_DISPLAY

            #pragma vertex vert
            #pragma fragment frag

            #define SHADERPASS SHADERPASS_FORWARD

            #if ASE_SRP_VERSION >=140007
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DOTS.hlsl"
            #endif
            #if ASE_SRP_VERSION >=140007
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/RenderingLayers.hlsl"
            #endif

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Texture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Input.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/TextureStack.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/ShaderGraphFunctions.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DBuffer.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Editor/ShaderGraph/Includes/ShaderPass.hlsl"

            #if defined(LOD_FADE_CROSSFADE)
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LODCrossFade.hlsl"
            #endif

            #define ASE_NEEDS_FRAG_POSITION
            #define ASE_NEEDS_FRAG_WORLD_NORMAL
            #define ASE_NEEDS_FRAG_WORLD_VIEW_DIR
            #define ASE_NEEDS_FRAG_WORLD_POSITION
            #define ASE_NEEDS_FRAG_SHADOWCOORDS

            #pragma shader_feature_local _WIND_ON
            #pragma shader_feature_local _FIXTHEBASEOFFOLIAGE_ON
            #pragma shader_feature_local _SNOW_ON
            #pragma shader_feature_local _COLOR2ENABLE_ON
            #pragma shader_feature_local _COLOR2OVERLAYTYPE_VERTEX_POSITION_BASED _COLOR2OVERLAYTYPE_UV_BASED
            #pragma shader_feature_local _SNOWOVERLAYTYPE_WORLD_NORMAL_BASED _SNOWOVERLAYTYPE_UV_BASED
            #pragma shader_feature_local _TRANCLUSENCYENABLE_ON
            #pragma shader_feature_local _INTERACTIVE_ON   // NEW

            #if defined(ASE_EARLY_Z_DEPTH_OPTIMIZE) && (SHADER_TARGET >= 45)
                #define ASE_SV_DEPTH SV_DepthLessEqual
                #define ASE_SV_POSITION_QUALIFIERS linear noperspective centroid
            #else
                #define ASE_SV_DEPTH SV_Depth
                #define ASE_SV_POSITION_QUALIFIERS
            #endif

            struct VertexInput
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float4 texcoord   : TEXCOORD0;
                float4 texcoord1  : TEXCOORD1;
                float4 texcoord2  : TEXCOORD2;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct VertexOutput
            {
                ASE_SV_POSITION_QUALIFIERS float4 positionCS : SV_POSITION;
                float4 clipPosV              : TEXCOORD0;
                float4 lightmapUVOrVertexSH  : TEXCOORD1;
                half4  fogFactorAndVertexLight: TEXCOORD2;
                float4 tSpace0               : TEXCOORD3;
                float4 tSpace1               : TEXCOORD4;
                float4 tSpace2               : TEXCOORD5;
                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
                float4 shadowCoord           : TEXCOORD6;
                #endif
                #if defined(DYNAMICLIGHTMAP_ON)
                float2 dynamicLightmapUV     : TEXCOORD7;
                #endif
                float4 ase_texcoord8         : TEXCOORD8;
                float4 ase_texcoord9         : TEXCOORD9;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            CBUFFER_START(UnityPerMaterial)
            float4 _Color1;
            float4 _Texture00_ST;
            float4 _Color2;
            float4 _SnowMask_ST;
            float4 _SmoothnessTexture1_ST;
            float _WindSpeed;
            float _WindWavesScale;
            float _WindForce;
            float _Color2Level;
            float _Color2Fade;
            float _SnowAmount;
            float _TranslucencyInt;
            float _Smoothness;
            float _AlphaCutoff;
            float _InteractionRadius;
            float _InteractionStrength;
            float _InteractionFalloff;
            float _RecoverySpeed;
            CBUFFER_END

            sampler2D _Texture00;
            sampler2D _SnowMask;
            sampler2D _SmoothnessTexture1;

            VertexOutput VertexFunction( VertexInput v )
            {
                VertexOutput o = (VertexOutput)0;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                float3 ase_worldPos = TransformObjectToWorld( v.positionOS.xyz );

                // ── Wind (original logic) ──────────────────────────────────
                float mulTime34          = _TimeParameters.x * (_WindSpeed * 5);
                float simplePerlin3D35   = snoise( (ase_worldPos + mulTime34) * _WindWavesScale );
                float temp_output_231_0  = simplePerlin3D35 * 0.01;
                float2 texCoord357       = v.texcoord.xy;

                #ifdef _FIXTHEBASEOFFOLIAGE_ON
                float staticSwitch376 = temp_output_231_0 * pow(texCoord357.y, 2.0);
                #else
                float staticSwitch376 = temp_output_231_0;
                #endif

                #ifdef _WIND_ON
                float staticSwitch341 = staticSwitch376 * (_WindForce * 30);
                #else
                float staticSwitch341 = 0.0;
                #endif

                float Wind191 = staticSwitch341;

                // ── Interaction displacement (NEW) ─────────────────────────
                float3 interactionDisp = float3(0, 0, 0);
                #ifdef _INTERACTIVE_ON
                // UV.y = 0 at blade base, 1 at tip
                float vertexHeight = v.texcoord.y;

                #ifdef _FIXTHEBASEOFFOLIAGE_ON
                // When base is anchored, also anchor interaction at root
                vertexHeight = vertexHeight * vertexHeight;
                #endif

                interactionDisp = ComputeInteractionDisplacement(ase_worldPos, vertexHeight,
                                      _InteractionRadius, _InteractionStrength, _InteractionFalloff);
                #endif

                // ── Combine wind + interaction ─────────────────────────────
                float3 totalDisplacement = float3(Wind191, 0, Wind191) + interactionDisp;

                o.ase_texcoord8.xy = v.texcoord.xy;
                o.ase_texcoord9    = v.positionOS;
                o.ase_texcoord8.zw = 0;

                v.positionOS.xyz += totalDisplacement;
                v.normalOS  = v.normalOS;
                v.tangentOS = v.tangentOS;

                VertexPositionInputs vertexInput = GetVertexPositionInputs( v.positionOS.xyz );
                VertexNormalInputs   normalInput  = GetVertexNormalInputs( v.normalOS, v.tangentOS );

                o.tSpace0 = float4( normalInput.normalWS,   vertexInput.positionWS.x );
                o.tSpace1 = float4( normalInput.tangentWS,  vertexInput.positionWS.y );
                o.tSpace2 = float4( normalInput.bitangentWS,vertexInput.positionWS.z );

                #if defined(LIGHTMAP_ON)
                OUTPUT_LIGHTMAP_UV( v.texcoord1, unity_LightmapST, o.lightmapUVOrVertexSH.xy );
                #endif
                #if !defined(LIGHTMAP_ON)
                OUTPUT_SH( normalInput.normalWS.xyz, o.lightmapUVOrVertexSH.xyz );
                #endif
                #if defined(DYNAMICLIGHTMAP_ON)
                o.dynamicLightmapUV.xy = v.texcoord2.xy * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
                #endif

                half3 vertexLight  = VertexLighting( vertexInput.positionWS, normalInput.normalWS );
                #ifdef ASE_FOG
                half fogFactor = ComputeFogFactor( vertexInput.positionCS.z );
                #else
                half fogFactor = 0;
                #endif
                o.fogFactorAndVertexLight = half4(fogFactor, vertexLight);

                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
                o.shadowCoord = GetShadowCoord( vertexInput );
                #endif

                o.positionCS = vertexInput.positionCS;
                o.clipPosV   = vertexInput.positionCS;
                return o;
            }

            VertexOutput vert( VertexInput v ) { return VertexFunction(v); }

            half4 frag( VertexOutput IN
                #ifdef ASE_DEPTH_WRITE_ON
                , out float outputDepth : ASE_SV_DEPTH
                #endif
                #ifdef _WRITE_RENDERING_LAYERS
                , out float4 outRenderingLayers : SV_Target1
                #endif
                ) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(IN);

                #if defined(LOD_FADE_CROSSFADE)
                LODFadeCrossFade( IN.positionCS );
                #endif

                float3 WorldNormal      = normalize( IN.tSpace0.xyz );
                float3 WorldTangent     = IN.tSpace1.xyz;
                float3 WorldBiTangent   = IN.tSpace2.xyz;
                float3 WorldPosition    = float3(IN.tSpace0.w, IN.tSpace1.w, IN.tSpace2.w);
                float3 WorldViewDirection = SafeNormalize(_WorldSpaceCameraPos.xyz - WorldPosition);

                float4 ShadowCoords = float4(0,0,0,0);
                float4 ClipPos   = IN.clipPosV;
                float4 ScreenPos = ComputeScreenPos( IN.clipPosV );
                float2 NormalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(IN.positionCS);

                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
                ShadowCoords = IN.shadowCoord;
                #elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
                ShadowCoords = TransformWorldToShadowCoord( WorldPosition );
                #endif

                // ── Albedo ─────────────────────────────────────────────────
                float2 uv_Texture00   = IN.ase_texcoord8.xy * _Texture00_ST.xy + _Texture00_ST.zw;
                float4 tex2DNode1     = tex2D( _Texture00, uv_Texture00 );
                float4 temp_output_10 = _Color1 * tex2DNode1;
                float2 texCoord361    = IN.ase_texcoord8.xy;

                #if defined(_COLOR2OVERLAYTYPE_VERTEX_POSITION_BASED)
                float staticSwitch360 = IN.ase_texcoord9.xyz.y;
                #elif defined(_COLOR2OVERLAYTYPE_UV_BASED)
                float staticSwitch360 = texCoord361.y;
                #else
                float staticSwitch360 = IN.ase_texcoord9.xyz.y;
                #endif

                float SecondColorMask335 = saturate( ((staticSwitch360 + _Color2Level) * (_Color2Fade * 2)) );
                float4 lerpResult332     = lerp( temp_output_10, _Color2 * tex2D(_Texture00, uv_Texture00), SecondColorMask335 );

                #ifdef _COLOR2ENABLE_ON
                float4 staticSwitch340 = lerpResult332;
                #else
                float4 staticSwitch340 = temp_output_10;
                #endif

                float4 color288 = IsGammaSpace() ? float4(0.8962264,0.8962264,0.8962264,0)
                                                 : float4(0.7799658,0.7799658,0.7799658,0);
                float2 texCoord352 = IN.ase_texcoord8.xy;

                #if defined(_SNOWOVERLAYTYPE_WORLD_NORMAL_BASED)
                float staticSwitch390 = WorldNormal.y;
                #elif defined(_SNOWOVERLAYTYPE_UV_BASED)
                float staticSwitch390 = texCoord352.y;
                #else
                float staticSwitch390 = WorldNormal.y;
                #endif

                float2 uv_SnowMask    = IN.ase_texcoord8.xy * _SnowMask_ST.xy + _SnowMask_ST.zw;
                float SnowMask314     = saturate( (staticSwitch390 * (_SnowAmount * 5)) * tex2D(_SnowMask, uv_SnowMask).r );
                float4 lerpResult295  = lerp( staticSwitch340, color288 * tex2D(_Texture00, uv_Texture00), SnowMask314 );

                #ifdef _SNOW_ON
                float4 staticSwitch342 = lerpResult295;
                #else
                float4 staticSwitch342 = staticSwitch340;
                #endif

                float4 Albedo259 = staticSwitch342;

                // ── Translucency ───────────────────────────────────────────
                float dotResult538     = dot( SafeNormalize(_MainLightPosition.xyz), WorldViewDirection );
                float TranslucencyMask = (-dotResult538 * 1.0 + -0.2);
                float3 normalizedWorldNormal = normalize(WorldNormal);
                float dotResult498     = dot( SafeNormalize(_MainLightPosition.xyz), normalizedWorldNormal );
                float ase_lightAtten   = 0;
                Light ase_mainLight    = GetMainLight( ShadowCoords );
                ase_lightAtten = ase_mainLight.distanceAttenuation * ase_mainLight.shadowAttenuation;
                float ase_lightIntensity = max(max(_MainLightColor.r,_MainLightColor.g),_MainLightColor.b);
                float4 ase_lightColor  = float4(_MainLightColor.rgb / ase_lightIntensity, ase_lightIntensity);

                #ifdef _TRANCLUSENCYENABLE_ON
                float4 staticSwitch576 = saturate( (TranslucencyMask * ((((dotResult498*1.0+1.0)*ase_lightAtten)*ase_lightColor*Albedo259)*0.25)) * _TranslucencyInt );
                #else
                float4 staticSwitch576 = float4(0,0,0,0);
                #endif

                float4 Translucency488 = staticSwitch576;

                float2 uv_Smoothness = IN.ase_texcoord8.xy * _SmoothnessTexture1_ST.xy + _SmoothnessTexture1_ST.zw;
                float4 Smoothness482 = saturate( tex2D(_SmoothnessTexture1, uv_Smoothness) * _Smoothness );
                float  OpacityMask   = tex2DNode1.a;

                float3 BaseColor = (Albedo259 + Translucency488).rgb;
                float  Alpha     = OpacityMask;
                float  AlphaClipThreshold = _AlphaCutoff;

                #ifdef _ALPHATEST_ON
                clip(Alpha - AlphaClipThreshold);
                #endif

                InputData inputData = (InputData)0;
                inputData.positionWS            = WorldPosition;
                inputData.viewDirectionWS       = WorldViewDirection;
                inputData.normalWS              = NormalizeNormalPerPixel(WorldNormal);
                inputData.normalizedScreenSpaceUV = NormalizedScreenSpaceUV;

                #if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
                inputData.shadowCoord = ShadowCoords;
                #elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
                inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
                #else
                inputData.shadowCoord = float4(0,0,0,0);
                #endif

                #ifdef ASE_FOG
                inputData.fogCoord = IN.fogFactorAndVertexLight.x;
                #endif
                inputData.vertexLighting = IN.fogFactorAndVertexLight.yzw;

                float3 SH = IN.lightmapUVOrVertexSH.xyz;
                #if defined(DYNAMICLIGHTMAP_ON)
                inputData.bakedGI = SAMPLE_GI(IN.lightmapUVOrVertexSH.xy, IN.dynamicLightmapUV.xy, SH, inputData.normalWS);
                #else
                inputData.bakedGI = SAMPLE_GI(IN.lightmapUVOrVertexSH.xy, SH, inputData.normalWS);
                #endif
                inputData.shadowMask = SAMPLE_SHADOWMASK(IN.lightmapUVOrVertexSH.xy);

                SurfaceData surfaceData;
                surfaceData.albedo              = BaseColor;
                surfaceData.metallic            = 0;
                surfaceData.specular            = half3(0.5, 0.5, 0.5);
                surfaceData.smoothness          = saturate(Smoothness482.r);
                surfaceData.occlusion           = 1;
                surfaceData.emission            = half3(0, 0, 0);
                surfaceData.alpha               = 1.0;   // opaque — alpha clip already ran above
                surfaceData.normalTS            = float3(0, 0, 1);
                surfaceData.clearCoatMask       = 0;
                surfaceData.clearCoatSmoothness = 1;

                #ifdef _DBUFFER
                ApplyDecalToSurfaceData(IN.positionCS, surfaceData, inputData);
                #endif

                half4 color = UniversalFragmentPBR( inputData, surfaceData );

                #ifdef ASE_FOG
                color.rgb = MixFog(color.rgb, IN.fogFactorAndVertexLight.x);
                #endif

                #ifdef _WRITE_RENDERING_LAYERS
                uint renderingLayers = GetMeshRenderingLayer();
                outRenderingLayers = float4( EncodeMeshRenderingLayer(renderingLayers), 0, 0, 0 );
                #endif

                return color;
            }

            ENDHLSL
        }

        // ════════════════════════════════════════════
        //  SHADOW CASTER PASS  (interaction applied here too
        //  so shadows deform correctly)
        // ════════════════════════════════════════════
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode"="ShadowCaster" }

            ZWrite On
            ZTest LEqual
            AlphaToMask On
            ColorMask 0

            HLSLPROGRAM

            #define _NORMAL_DROPOFF_TS 1
            #pragma multi_compile_instancing
            #pragma multi_compile _ LOD_FADE_CROSSFADE
            #define _ALPHATEST_ON 1
            #define ASE_SRP_VERSION 140007

            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            #pragma vertex vert
            #pragma fragment frag

            #define SHADERPASS SHADERPASS_SHADOWCASTER

            #if ASE_SRP_VERSION >=140007
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DOTS.hlsl"
            #endif

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Texture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Input.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/TextureStack.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/ShaderGraphFunctions.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Editor/ShaderGraph/Includes/ShaderPass.hlsl"

            #if defined(LOD_FADE_CROSSFADE)
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LODCrossFade.hlsl"
            #endif

            #pragma shader_feature_local _WIND_ON
            #pragma shader_feature_local _FIXTHEBASEOFFOLIAGE_ON
            #pragma shader_feature_local _INTERACTIVE_ON

            struct VertexInput
            {
                float4 positionOS    : POSITION;
                float3 normalOS      : NORMAL;
                float4 ase_texcoord  : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct VertexOutput
            {
                float4 positionCS    : SV_POSITION;
                float4 clipPosV      : TEXCOORD0;
                float4 ase_texcoord3 : TEXCOORD3;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            CBUFFER_START(UnityPerMaterial)
            float4 _Color1;
            float4 _Texture00_ST;
            float4 _Color2;
            float4 _SnowMask_ST;
            float4 _SmoothnessTexture1_ST;
            float _WindSpeed;
            float _WindWavesScale;
            float _WindForce;
            float _Color2Level;
            float _Color2Fade;
            float _SnowAmount;
            float _TranslucencyInt;
            float _Smoothness;
            float _AlphaCutoff;
            float _InteractionRadius;
            float _InteractionStrength;
            float _InteractionFalloff;
            float _RecoverySpeed;
            CBUFFER_END

            sampler2D _Texture00;

            float3 _LightDirection;
            float3 _LightPosition;

            VertexOutput VertexFunction( VertexInput v )
            {
                VertexOutput o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                float3 ase_worldPos = TransformObjectToWorld( v.positionOS.xyz );

                float mulTime34        = _TimeParameters.x * (_WindSpeed * 5);
                float simplePerlin3D35 = snoise( (ase_worldPos + mulTime34) * _WindWavesScale );
                float temp_output_231  = simplePerlin3D35 * 0.01;
                float2 texCoord357     = v.ase_texcoord.xy;

                #ifdef _FIXTHEBASEOFFOLIAGE_ON
                float staticSwitch376 = temp_output_231 * pow(texCoord357.y, 2.0);
                #else
                float staticSwitch376 = temp_output_231;
                #endif

                #ifdef _WIND_ON
                float staticSwitch341 = staticSwitch376 * (_WindForce * 30);
                #else
                float staticSwitch341 = 0.0;
                #endif

                float3 interactionDisp = float3(0,0,0);
                #ifdef _INTERACTIVE_ON
                float vertexHeight = v.ase_texcoord.y;
                #ifdef _FIXTHEBASEOFFOLIAGE_ON
                vertexHeight = vertexHeight * vertexHeight;
                #endif
                interactionDisp = ComputeInteractionDisplacement(ase_worldPos, vertexHeight, _InteractionRadius, _InteractionStrength, _InteractionFalloff);
                #endif

                float3 totalDisplacement = float3(staticSwitch341,0,staticSwitch341) + interactionDisp;

                o.ase_texcoord3.xy = v.ase_texcoord.xy;
                o.ase_texcoord3.zw = 0;

                v.positionOS.xyz += totalDisplacement;
                v.normalOS = v.normalOS;

                float3 positionWS = TransformObjectToWorld( v.positionOS.xyz );
                float3 normalWS   = TransformObjectToWorldDir(v.normalOS);

                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                float3 lightDirectionWS = normalize(_LightPosition - positionWS);
                #else
                float3 lightDirectionWS = _LightDirection;
                #endif

                float4 positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirectionWS));

                #if UNITY_REVERSED_Z
                positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif

                o.positionCS = positionCS;
                o.clipPosV   = positionCS;
                return o;
            }

            VertexOutput vert( VertexInput v ) { return VertexFunction(v); }

            half4 frag( VertexOutput IN ) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(IN);

                float2 uv_Texture00 = IN.ase_texcoord3.xy * _Texture00_ST.xy + _Texture00_ST.zw;
                float4 tex2DNode1   = tex2D( _Texture00, uv_Texture00 );
                float  Alpha        = tex2DNode1.a;

                #ifdef _ALPHATEST_ON
                clip(Alpha - _AlphaCutoff);
                #endif
                #if defined(LOD_FADE_CROSSFADE)
                LODFadeCrossFade( IN.positionCS );
                #endif

                return 0;
            }

            ENDHLSL
        }

        // ════════════════════════════════════════════
        //  DEPTH ONLY
        // ════════════════════════════════════════════
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode"="DepthOnly" }

            ZWrite On
            ColorMask 0
            AlphaToMask On

            HLSLPROGRAM

            #define _NORMAL_DROPOFF_TS 1
            #pragma multi_compile_instancing
            #pragma multi_compile _ LOD_FADE_CROSSFADE
            #define _ALPHATEST_ON 1
            #define ASE_SRP_VERSION 140007

            #pragma vertex vert
            #pragma fragment frag

            #define SHADERPASS SHADERPASS_DEPTHONLY

            #if ASE_SRP_VERSION >=140007
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DOTS.hlsl"
            #endif

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Texture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Input.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/TextureStack.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/ShaderGraphFunctions.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Editor/ShaderGraph/Includes/ShaderPass.hlsl"

            #if defined(LOD_FADE_CROSSFADE)
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/LODCrossFade.hlsl"
            #endif

            #pragma shader_feature_local _WIND_ON
            #pragma shader_feature_local _FIXTHEBASEOFFOLIAGE_ON
            #pragma shader_feature_local _INTERACTIVE_ON

            struct VertexInput
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float4 ase_texcoord : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct VertexOutput
            {
                float4 positionCS   : SV_POSITION;
                float4 clipPosV     : TEXCOORD0;
                float4 ase_texcoord3: TEXCOORD3;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            CBUFFER_START(UnityPerMaterial)
            float4 _Color1;
            float4 _Texture00_ST;
            float4 _Color2;
            float4 _SnowMask_ST;
            float4 _SmoothnessTexture1_ST;
            float _WindSpeed;
            float _WindWavesScale;
            float _WindForce;
            float _Color2Level;
            float _Color2Fade;
            float _SnowAmount;
            float _TranslucencyInt;
            float _Smoothness;
            float _AlphaCutoff;
            float _InteractionRadius;
            float _InteractionStrength;
            float _InteractionFalloff;
            float _RecoverySpeed;
            CBUFFER_END

            sampler2D _Texture00;

            VertexOutput VertexFunction( VertexInput v )
            {
                VertexOutput o = (VertexOutput)0;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                float3 ase_worldPos = TransformObjectToWorld( v.positionOS.xyz );

                float mulTime34        = _TimeParameters.x * (_WindSpeed * 5);
                float simplePerlin3D35 = snoise( (ase_worldPos + mulTime34) * _WindWavesScale );
                float temp_output_231  = simplePerlin3D35 * 0.01;
                float2 texCoord357     = v.ase_texcoord.xy;

                #ifdef _FIXTHEBASEOFFOLIAGE_ON
                float staticSwitch376 = temp_output_231 * pow(texCoord357.y, 2.0);
                #else
                float staticSwitch376 = temp_output_231;
                #endif

                #ifdef _WIND_ON
                float staticSwitch341 = staticSwitch376 * (_WindForce * 30);
                #else
                float staticSwitch341 = 0.0;
                #endif

                float3 interactionDisp = float3(0,0,0);
                #ifdef _INTERACTIVE_ON
                float vertexHeight = v.ase_texcoord.y;
                #ifdef _FIXTHEBASEOFFOLIAGE_ON
                vertexHeight = vertexHeight * vertexHeight;
                #endif
                interactionDisp = ComputeInteractionDisplacement(ase_worldPos, vertexHeight, _InteractionRadius, _InteractionStrength, _InteractionFalloff);
                #endif

                float3 totalDisplacement = float3(staticSwitch341,0,staticSwitch341) + interactionDisp;

                o.ase_texcoord3.xy = v.ase_texcoord.xy;
                o.ase_texcoord3.zw = 0;

                v.positionOS.xyz += totalDisplacement;

                VertexPositionInputs vertexInput = GetVertexPositionInputs( v.positionOS.xyz );
                o.positionCS = vertexInput.positionCS;
                o.clipPosV   = vertexInput.positionCS;
                return o;
            }

            VertexOutput vert( VertexInput v ) { return VertexFunction(v); }

            half4 frag( VertexOutput IN ) : SV_TARGET
            {
                UNITY_SETUP_INSTANCE_ID(IN);

                float2 uv_Texture00 = IN.ase_texcoord3.xy * _Texture00_ST.xy + _Texture00_ST.zw;
                float4 tex2DNode1   = tex2D( _Texture00, uv_Texture00 );

                #ifdef _ALPHATEST_ON
                clip(tex2DNode1.a - _AlphaCutoff);
                #endif

                #if defined(LOD_FADE_CROSSFADE)
                LODFadeCrossFade( IN.positionCS );
                #endif

                return 0;
            }

            ENDHLSL
        }
    }

    CustomEditor "UnityEditor.ShaderGraphLitGUI"
    FallBack "Hidden/Shader Graph/FallbackError"
    Fallback Off
}
