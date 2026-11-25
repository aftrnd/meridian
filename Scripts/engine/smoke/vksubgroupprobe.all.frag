#version 450

// The reference: every invocation writes its own mark. (vksubgroupprobe.c)
layout(location = 0) flat in uint disc;

layout(set = 0, binding = 0, std430) buffer Marks {
	uint data[];
}
marks;

void main() {
	uvec2 tile = uvec2(gl_FragCoord.xy) >> 3;
	uint offset = (tile.x + 36u * tile.y) * 2u;

	if (!gl_HelperInvocation) {
		atomicOr(marks.data[offset + (disc >> 5)], 1u << (disc & 31u));
	}
}
