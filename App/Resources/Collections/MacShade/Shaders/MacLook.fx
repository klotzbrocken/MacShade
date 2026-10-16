// MacLook: sharp textures, bloom, better colours and a vignette in ONE effect, made for the MacShade OpenGL/Metal bridge, where every full-resolution
// pass costs noticeable frame time. The bloom runs at 1/4 resolution (threshold + downsample, 5-tap blur horizontal and vertical); the final pass does
// sharpen + bloom + vibrance + vignette in a single full-resolution pass.
#include "ReShade.fxh"

uniform float SharpStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_label = "Sharpening"; ui_category = "Sharpening"; > = 1.0;
uniform float SharpClamp < ui_type = "slider"; ui_min = 0.0; ui_max = 0.2; ui_label = "Sharpening limit"; ui_tooltip = "Limits halos around hard edges."; ui_category = "Sharpening"; > = 0.04;

uniform float BloomIntensity < ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_label = "Bloom intensity"; ui_category = "Bloom"; > = 0.8;
uniform float BloomThreshold < ui_type = "slider"; ui_min = 0.0; ui_max = 0.95; ui_label = "Bloom threshold"; ui_tooltip = "Only pixels brighter than this glow."; ui_category = "Bloom"; > = 0.55;
uniform float BloomSaturation < ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Bloom saturation"; ui_category = "Bloom"; > = 1.2;

uniform float Vibrance < ui_type = "slider"; ui_min = -1.0; ui_max = 1.0; ui_label = "Vibrance"; ui_tooltip = "Raises the saturation of dull colours more than of strong ones."; ui_category = "Colour"; > = 0.25;

uniform float VignetteAmount < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Vignette"; ui_category = "Vignette"; > = 0.4;
uniform float VignetteStart < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Vignette start"; ui_tooltip = "Distance from the centre where the darkening begins."; ui_category = "Vignette"; > = 0.45;

texture MacLookTexA { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA8; };
texture MacLookTexB { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA8; };
sampler MacLookA { Texture = MacLookTexA; AddressU = CLAMP; AddressV = CLAMP; };
sampler MacLookB { Texture = MacLookTexB; AddressU = CLAMP; AddressV = CLAMP; };

static const float3 luma = float3(0.299, 0.587, 0.114);

float4 PS_Down(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	const float2 px = ReShade::PixelSize * 1.5;
	float3 c = tex2D(ReShade::BackBuffer, uv + float2(-px.x, -px.y)).rgb + tex2D(ReShade::BackBuffer, uv + float2(px.x, -px.y)).rgb
	         + tex2D(ReShade::BackBuffer, uv + float2(-px.x,  px.y)).rgb + tex2D(ReShade::BackBuffer, uv + float2(px.x,  px.y)).rgb;
	c *= 0.25;
	c *= saturate((max(c.r, max(c.g, c.b)) - BloomThreshold) / max(1.0 - BloomThreshold, 0.001));
	return float4(c, 1.0);
}

float3 blur(sampler s, float2 uv, float2 dir)
{
	const float2 step = dir * ReShade::PixelSize * 6.0;   // quarter-resolution texels, 1.5 apart
	return tex2D(s, uv).rgb * 0.2270 + (tex2D(s, uv + step).rgb + tex2D(s, uv - step).rgb) * 0.3162 + (tex2D(s, uv + step * 2.0).rgb + tex2D(s, uv - step * 2.0).rgb) * 0.0703;
}
float4 PS_BlurH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(blur(MacLookA, uv, float2(1, 0)), 1.0); }
float4 PS_BlurV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(blur(MacLookB, uv, float2(0, 1)), 1.0); }

float4 PS_Final(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	const float2 px = ReShade::PixelSize;
	float3 c = tex2D(ReShade::BackBuffer, uv).rgb;

	// sharpen: difference to the 4 direct neighbours, applied as a (limited) change of brightness
	const float3 around = (tex2D(ReShade::BackBuffer, uv + float2(px.x, 0)).rgb + tex2D(ReShade::BackBuffer, uv - float2(px.x, 0)).rgb
	                     + tex2D(ReShade::BackBuffer, uv + float2(0, px.y)).rgb + tex2D(ReShade::BackBuffer, uv - float2(0, px.y)).rgb) * 0.25;
	c += clamp(dot(c - around, luma) * SharpStrength, -SharpClamp, SharpClamp);

	// bloom (screen-like, never clips harshly)
	float3 glow = tex2D(MacLookA, uv).rgb;
	glow = lerp(dot(glow, luma).xxx, glow, BloomSaturation);
	c += glow * BloomIntensity * (1.0 - saturate(c));

	// vibrance: the duller the colour, the more it is boosted
	const float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
	c = lerp(dot(c, luma).xxx, c, 1.0 + Vibrance * (1.0 - sat));

	// vignette
	const float2 d = (uv - 0.5) * float2(BUFFER_WIDTH * BUFFER_RCP_HEIGHT, 1.0);
	c *= 1.0 - VignetteAmount * smoothstep(VignetteStart, 1.05, length(d));

	return float4(saturate(c), 1.0);
}

technique MacLook < ui_tooltip = "Sharpening, bloom, vibrance and vignette in one effect (cheap on the macOS bridge)."; >
{
	pass Down  { VertexShader = PostProcessVS; PixelShader = PS_Down;  RenderTarget = MacLookTexA; }
	pass BlurH { VertexShader = PostProcessVS; PixelShader = PS_BlurH; RenderTarget = MacLookTexB; }
	pass BlurV { VertexShader = PostProcessVS; PixelShader = PS_BlurV; RenderTarget = MacLookTexA; }
	pass Final { VertexShader = PostProcessVS; PixelShader = PS_Final; }
}
