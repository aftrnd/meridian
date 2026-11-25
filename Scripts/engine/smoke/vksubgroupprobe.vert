#version 450

// One disc per instance, a fan of 24 triangles, its centre and radius from
// the instance index. (vksubgroupprobe.c)
layout(location = 0) flat out uint disc;

void main() {
	uint triangle = uint(gl_VertexIndex) / 3u;
	uint corner = uint(gl_VertexIndex) % 3u;
	disc = uint(gl_InstanceIndex);
	vec2 position = fract(vec2(0.754877666, 0.569840291) * float(disc + 1u)) * 1.6 - 0.8;
	if (corner != 0u) {
		float radius = 0.08 + 0.35 * fract(0.3819660113 * float(disc + 1u));
		float angle = 6.283185307 * float(triangle + corner - 1u) / 24.0;
		position += radius * vec2(cos(angle), sin(angle));
	}
	gl_Position = vec4(position, 0.5, 1.0);
}
