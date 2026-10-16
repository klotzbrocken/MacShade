// DepthRaw: shows the raw depth buffer (ReShade::DepthBuffer) as grey values - a check that the game's depth reaches ReShade.
// Bright = far, dark = near, for a depth buffer that is not reversed (OpenGL default). Use DisplayDepth for the linearised view.
#include "ReShade.fxh"

uniform float Contrast < ui_type = "slider"; ui_min = 1.0; ui_max = 100.0; ui_label = "Contrast"; ui_tooltip = "Stretches the values near 1.0 (most of the range of a perspective depth buffer is there)."; > = 3.0;

float4 PS_DepthRaw(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	const float d = tex2D(ReShade::DepthBuffer, uv).x;
	return float4(saturate(1.0 - (1.0 - d) * Contrast).xxx, 1.0);
}

technique DepthRaw < ui_tooltip = "Raw depth buffer as grey values."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_DepthRaw; }
}
