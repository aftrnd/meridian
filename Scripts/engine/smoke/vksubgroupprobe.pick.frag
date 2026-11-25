#version 450
#extension GL_KHR_shader_subgroup_ballot : enable

// Godot 4's way (cluster_render.glsl): of the invocations of a subgroup that
// share a tile, the first writes the mark for all. (vksubgroupprobe.c)
layout(location = 0) flat in uint disc;

layout(set = 0, binding = 0, std430) buffer Marks {
	uint data[];
}
marks;

void main() {
	uvec2 tile = uvec2(gl_FragCoord.xy) >> 3;
	uint offset = (tile.x + 36u * tile.y) * 2u;

	if (!gl_HelperInvocation) {
		uvec4 mask;
		while (true) {
			// The tile of the first active invocation; those that break go
			// inactive and no longer count.
			uint first = subgroupBroadcastFirst(offset);
			mask = subgroupBallot(first == offset);
			if (first == offset) {
				break;
			}
		}
		if (subgroupBallotExclusiveBitCount(mask) == 0u) {
			atomicOr(marks.data[offset + (disc >> 5)], 1u << (disc & 31u));
		}
	}
}
