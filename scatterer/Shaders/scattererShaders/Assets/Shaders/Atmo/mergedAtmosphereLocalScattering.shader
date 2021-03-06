﻿Shader "Scatterer/MergedAtmosphericLocalScatter" {
	SubShader {
		Tags {"Queue" = "Transparent-498" "IgnoreProjector" = "True" "RenderType" = "Transparent"}

		//merged scattering+extinction pass
		Pass {
			Tags {"Queue" = "Transparent-498" "IgnoreProjector" = "True" "RenderType" = "Transparent"}

			//Cull Front
			Cull Back
			ZTest LEqual
			ZWrite Off

			//Blend OneMinusDstColor One //soft additive
			Blend SrcAlpha OneMinusSrcAlpha //traditional alpha-blending

			Offset 0.0, -0.07

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma target 3.0
			#include "UnityCG.cginc"
			#include "../CommonAtmosphere.cginc"

			#pragma multi_compile GODRAYS_OFF GODRAYS_ON
			//			#pragma multi_compile ECLIPSES_OFF ECLIPSES_ON
			#pragma multi_compile PLANETSHINE_OFF PLANETSHINE_ON
			#pragma multi_compile CUSTOM_OCEAN_OFF CUSTOM_OCEAN_ON
			#pragma multi_compile DITHERING_OFF DITHERING_ON

			uniform float _global_alpha;
			uniform float _global_depth;
			uniform float3 _planetPos; //planet origin, in world space
			uniform float3 _camForward; //camera's viewing direction, in world space
			uniform float _ScatteringExposure;

			uniform float _PlanetOpacity; //to smooth transition from/to scaledSpace


			uniform float _Post_Extinction_Tint;
			uniform float extinctionThickness;

			uniform sampler2D _customDepthTexture;
			#if defined (GODRAYS_ON)
			uniform sampler2D _godrayDepthTexture;
			#endif
			uniform float _openglThreshold;
			uniform float4x4 _Globals_CameraToWorld;
			uniform float4x4 scattererFrustumCorners;

			uniform sampler2D ScattererScreenCopy;

			//            //eclipse uniforms
			//#if defined (ECLIPSES_ON)			
			//			uniform float4 sunPosAndRadius; //xyz sun pos w radius
			//			uniform float4x4 lightOccluders1; //array of light occluders
			//											 //for each float4 xyz pos w radius
			//			uniform float4x4 lightOccluders2;
			//#endif

			#if defined (PLANETSHINE_ON)
			uniform float4x4 planetShineSources;
			uniform float4x4 planetShineRGB;
			#endif

			struct v2f
			{
				float4 worldPos : TEXCOORD0;
				float3 _camPos  : TEXCOORD1;
				float4 	screenPos : TEXCOORD2;
			};

			v2f vert(appdata_base v, out float4 outpos: SV_POSITION)
			{
				v2f o;

				float4 worldPos = mul(unity_ObjectToWorld,v.vertex);
				worldPos.xyz/=worldPos.w; //needed?

				//display scattering at ocean level when we are fading out local shading
				//at the same time ocean stops rendering it's own scattering
				#if defined (CUSTOM_OCEAN_ON)
				worldPos.xyz = (_PlanetOpacity < 1.0) && (length(worldPos.xyz-_planetPos) < Rg) ? _planetPos+Rg* normalize(worldPos.xyz-_planetPos)  : worldPos.xyz;
				#endif

				o.worldPos = float4(worldPos.xyz,1.0);
				o.worldPos.xyz*=worldPos.w;
				outpos = mul (UNITY_MATRIX_VP,o.worldPos);

				o._camPos = _WorldSpaceCameraPos - _planetPos;

				o.screenPos = ComputeScreenPos(outpos);

				return o;
			}

			half4 frag(v2f i, UNITY_VPOS_TYPE screenPos : VPOS) : SV_Target
			{
				float3 worldPos = i.worldPos.xyz/i.worldPos.w - _planetPos; //worldPos relative to planet origin

				half returnPixel = ((  (length(i._camPos)-Rg) < 1000 )  && (length(worldPos) < (Rg-50))) ? 0.0: 1.0;  //enable in case of ocean and close enough to water surface, works well for kerbin

				float3 groundPos = normalize (worldPos) * Rg*1.0008;
				float Rt2 = Rg + (Rt - Rg) * _experimentalAtmoScale;


				worldPos = (length(worldPos) < Rt2) ? lerp(groundPos,worldPos,_PlanetOpacity) : worldPos; //fades to flatScaledSpace planet shading to ease the transition to scaledSpace
				//this wasn't applied in extinction shader, not sure if it will be an issue


				worldPos= (length(worldPos) < (Rg + _openglThreshold)) ? (Rg + _openglThreshold) * normalize(worldPos) : worldPos ; //artifacts fix

				//get background shit here

				float2 backGroundUV = i.screenPos.xy / i.screenPos.w;
				//float3 backGrnd = tex2D(ScattererScreenCopy, backGroundUV );
				float3 backGrnd = tex2Dlod(ScattererScreenCopy, float4(backGroundUV,0.0,0.0) );

				///////////////////////////////////////////////

				float3 extinction = getExtinction(i._camPos, worldPos, 1.0, 1.0, 1.0); //same function as in inscattering2 or different?
				float average=(extinction.r+extinction.g+extinction.b)/3;

				//lerped manually because of an issue with opengl or whatever
				extinction = _Post_Extinction_Tint * extinction + (1-_Post_Extinction_Tint) * float3(average,average,average);


				extinction= max(float3(0.0,0.0,0.0), (float3(1.0,1.0,1.0)*(1-extinctionThickness) + extinctionThickness*extinction) );
				extinction = (returnPixel == 1.0) ? extinction : float3(1.0,1.0,1.0);

				//composite backGround by extinction
				backGrnd*=extinction;

				/////////////////////////////////////////////

				float minDistance = length(worldPos-i._camPos);
				float3 inscatter=0.0;
				extinction=1.0;

				//TODO: put planetshine stuff in callable function
				#if defined (PLANETSHINE_ON)
				for (int j=0; j<4;++j)
				{
				if (planetShineRGB[j].w == 0) break;

				float intensity=1;  
				if (planetShineSources[j].w != 1.0f)
				{
				intensity = 0.57f*max((0.75-dot(normalize(planetShineSources[j].xyz - worldPos),SUN_DIR)),0); //if source is not a sun compute intensity of light from angle to light source
				//totally made up formula by eyeballing it
				}

				inscatter+=InScattering2(i._camPos, worldPos, normalize(planetShineSources[j].xyz),extinction)  //lot of potential extinction recomputations here
				*planetShineRGB[j].xyz*planetShineRGB[j].w*intensity;
				}
				#endif


				inscatter+= InScattering2(i._camPos, worldPos,SUN_DIR,extinction);
				inscatter*= (minDistance <= _global_depth) ? (1 - exp(-1 * (4 * minDistance / _global_depth))) : 1.0 ; //somehow the shader compiler for OpenGL behaves differently around braces

				//#if defined (ECLIPSES_ON)				
				// 				float eclipseShadow = 1;
				// 							
				//            	for (int i=0; i<4; ++i)
				//    			{
				//        			if (lightOccluders1[i].w <= 0)	break;
				//					eclipseShadow*=getEclipseShadow(worldPos, sunPosAndRadius.xyz,lightOccluders1[i].xyz,
				//								   lightOccluders1[i].w, sunPosAndRadius.w)	;
				//				}
				//						
				//				for (int j=0; j<4; ++j)
				//    			{
				//        			if (lightOccluders2[j].w <= 0)	break;
				//					eclipseShadow*=getEclipseShadow(worldPos, sunPosAndRadius.xyz,lightOccluders2[j].xyz,
				//								   lightOccluders2[j].w, sunPosAndRadius.w)	;
				//				}
				//
				//				inscatter*=eclipseShadow;
				//#endif
				inscatter = hdr(inscatter,_ScatteringExposure) *_global_alpha;

				//composite background with inscatter, soft-blend it
				backGrnd+= (1.0 - backGrnd) * dither(inscatter,screenPos)*returnPixel;

				return float4(backGrnd,1.0);
			}
			ENDCG
		}
	}

}