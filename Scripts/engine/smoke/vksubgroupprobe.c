/* vksubgroupprobe.c: do a multisampled fragment shader's writes survive when
 * one invocation of a subgroup writes for the others?
 *
 * Godot 4's Forward+ renderer marks the screen tiles each light reaches by
 * drawing the light's volume in a 4x pass with no attachments. Its fragment
 * shader has the first invocation of a subgroup do the atomicOr for all that
 * share its tile. On Apple GPUs a multisampled fragment function runs threads
 * whose buffer writes Metal discards, and nothing tells them from the others;
 * when one of them is first, the mark is lost and the tile is drawn without
 * the light: black squares on lit surfaces (godotengine/godot#104168). The
 * engine's MoltenVK gives each fragment invocation of a multisampled pipeline
 * a subgroup of its own (patches/moltenvk, patches/spirv-cross).
 *
 * This draws 64 discs twice, with no window: once with Godot's shader, once
 * with one that has every invocation write, and compares the marks. Stock
 * MoltenVK 1.4.2 loses marks in every run with 4 samples and none with 1.
 *
 * The shaders are vksubgroupprobe.{vert,pick.frag,all.frag}; smoke-test.sh
 * compiles them into vksubgroupprobe_spv.h.
 */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "vksubgroupprobe_spv.h"

#define WIDTH 288
#define HEIGHT 160
#define TILES_X (WIDTH / 8)
#define TILES_Y (HEIGHT / 8)
#define DISCS 64
#define WORDS (TILES_X * TILES_Y * (DISCS / 32))
#define DISC_VERTICES (24 * 3)

#define VK_FUNCTIONS(X) \
    X(CreateInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceQueueFamilyProperties) \
    X(GetPhysicalDeviceMemoryProperties) X(GetPhysicalDeviceProperties) X(CreateDevice) X(GetDeviceQueue) \
    X(CreateBuffer) X(GetBufferMemoryRequirements) X(AllocateMemory) X(BindBufferMemory) X(MapMemory) \
    X(CreateDescriptorSetLayout) X(CreateDescriptorPool) X(AllocateDescriptorSets) X(UpdateDescriptorSets) \
    X(CreateRenderPass) X(CreateFramebuffer) X(CreateShaderModule) X(CreatePipelineLayout) \
    X(CreateGraphicsPipelines) X(CreateCommandPool) X(AllocateCommandBuffers) X(BeginCommandBuffer) \
    X(CmdBeginRenderPass) X(CmdBindPipeline) X(CmdBindDescriptorSets) X(CmdDraw) X(CmdEndRenderPass) \
    X(EndCommandBuffer) X(QueueSubmit) X(QueueWaitIdle) X(ResetCommandBuffer)

#define X(name) static PFN_vk##name vk##name;
VK_FUNCTIONS(X)
#undef X

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { \
    printf("RESULT FAIL %s = %d\n", #call, (int)r_); return 1; } } while (0)

static VkDevice device;
static VkRenderPass render_pass;
static VkPipelineLayout layout;

static int make_pipeline(VkShaderModule vert, VkShaderModule frag, VkSampleCountFlagBits samples, VkPipeline *out)
{
    VkPipelineShaderStageCreateInfo stages[2] = {
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, vert, "main", NULL },
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, frag, "main", NULL },
    };
    VkPipelineVertexInputStateCreateInfo input = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo assembly = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        NULL, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, VK_FALSE };
    VkViewport viewport = { 0, 0, WIDTH, HEIGHT, 0, 1 };
    VkRect2D scissor = { { 0, 0 }, { WIDTH, HEIGHT } };
    VkPipelineViewportStateCreateInfo viewports = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        NULL, 0, 1, &viewport, 1, &scissor };
    VkPipelineRasterizationStateCreateInfo raster = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = VK_CULL_MODE_NONE;
    raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    raster.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo multisample = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    multisample.rasterizationSamples = samples;
    VkPipelineColorBlendStateCreateInfo blend = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    VkGraphicsPipelineCreateInfo info = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    info.stageCount = 2;
    info.pStages = stages;
    info.pVertexInputState = &input;
    info.pInputAssemblyState = &assembly;
    info.pViewportState = &viewports;
    info.pRasterizationState = &raster;
    info.pMultisampleState = &multisample;
    info.pColorBlendState = &blend;
    info.layout = layout;
    info.renderPass = render_pass;
    CHECK(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &info, NULL, out));
    return 0;
}

int main(void)
{
    HMODULE lib = LoadLibraryA("vulkan-1.dll");
    if (!lib) { printf("RESULT FAIL no vulkan-1.dll\n"); return 1; }
    PFN_vkGetInstanceProcAddr get_instance_proc = (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress(lib, "vkGetInstanceProcAddr");
    vkCreateInstance = (PFN_vkCreateInstance)get_instance_proc(NULL, "vkCreateInstance");

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vksubgroupprobe", 1, NULL, 0, VK_API_VERSION_1_1 };
    VkInstanceCreateInfo instance_info = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app };
    VkInstance instance;
    CHECK(vkCreateInstance(&instance_info, NULL, &instance));
#define X(name) vk##name = (PFN_vk##name)get_instance_proc(instance, "vk" #name); \
    if (!vk##name) { printf("RESULT FAIL no vk" #name "\n"); return 1; }
    VK_FUNCTIONS(X)
#undef X

    uint32_t count = 1;
    VkPhysicalDevice gpu;
    VkResult found = vkEnumeratePhysicalDevices(instance, &count, &gpu);
    if ((found != VK_SUCCESS && found != VK_INCOMPLETE) || count == 0) { printf("RESULT FAIL no Vulkan device\n"); return 1; }
    VkPhysicalDeviceProperties gpu_properties;
    vkGetPhysicalDeviceProperties(gpu, &gpu_properties);
    printf("device: %s\n", gpu_properties.deviceName);

    VkQueueFamilyProperties families[16];
    uint32_t family_count = 16, family = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &family_count, families);
    while (family < family_count && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) family++;
    if (family == family_count) { printf("RESULT FAIL no graphics queue\n"); return 1; }

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &priority };
    VkPhysicalDeviceFeatures features = { 0 };
    features.fragmentStoresAndAtomics = VK_TRUE;
    VkDeviceCreateInfo device_info = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &queue_info };
    device_info.pEnabledFeatures = &features;
    CHECK(vkCreateDevice(gpu, &device_info, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);

    /* The marks: one bit per disc and tile, in memory the program reads. */
    VkBufferCreateInfo buffer_info = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, WORDS * sizeof(uint32_t),
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, VK_SHARING_MODE_EXCLUSIVE };
    VkBuffer buffer;
    CHECK(vkCreateBuffer(device, &buffer_info, NULL, &buffer));
    VkMemoryRequirements need;
    vkGetBufferMemoryRequirements(device, buffer, &need);
    VkPhysicalDeviceMemoryProperties memory;
    vkGetPhysicalDeviceMemoryProperties(gpu, &memory);
    const VkMemoryPropertyFlags host = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t type = 0;
    while (type < memory.memoryTypeCount &&
           !((need.memoryTypeBits & (1u << type)) && (memory.memoryTypes[type].propertyFlags & host) == host)) type++;
    if (type == memory.memoryTypeCount) { printf("RESULT FAIL no host-visible memory\n"); return 1; }
    VkMemoryAllocateInfo allocation = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, need.size, type };
    VkDeviceMemory buffer_memory;
    CHECK(vkAllocateMemory(device, &allocation, NULL, &buffer_memory));
    CHECK(vkBindBufferMemory(device, buffer, buffer_memory, 0));
    uint32_t *marks;
    CHECK(vkMapMemory(device, buffer_memory, 0, VK_WHOLE_SIZE, 0, (void **)&marks));

    VkDescriptorSetLayoutBinding binding = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL };
    VkDescriptorSetLayoutCreateInfo set_layout_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 1, &binding };
    VkDescriptorSetLayout set_layout;
    CHECK(vkCreateDescriptorSetLayout(device, &set_layout_info, NULL, &set_layout));
    VkDescriptorPoolSize pool_size = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
    VkDescriptorPoolCreateInfo pool_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &pool_size };
    VkDescriptorPool pool;
    CHECK(vkCreateDescriptorPool(device, &pool_info, NULL, &pool));
    VkDescriptorSetAllocateInfo set_info = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, pool, 1, &set_layout };
    VkDescriptorSet set;
    CHECK(vkAllocateDescriptorSets(device, &set_info, &set));
    VkDescriptorBufferInfo buffer_range = { buffer, 0, VK_WHOLE_SIZE };
    VkWriteDescriptorSet write = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 0, 0, 1,
        VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &buffer_range, NULL };
    vkUpdateDescriptorSets(device, 1, &write, 0, NULL);

    /* A pass with no attachments, as Godot's: the shader's writes are all it does. */
    VkSubpassDescription subpass = { 0, VK_PIPELINE_BIND_POINT_GRAPHICS };
    VkRenderPassCreateInfo pass_info = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, NULL, 0, 0, NULL, 1, &subpass };
    CHECK(vkCreateRenderPass(device, &pass_info, NULL, &render_pass));
    VkFramebufferCreateInfo framebuffer_info = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, NULL, 0, render_pass,
        0, NULL, WIDTH, HEIGHT, 1 };
    VkFramebuffer framebuffer;
    CHECK(vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer));
    VkPipelineLayoutCreateInfo layout_info = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &set_layout };
    CHECK(vkCreatePipelineLayout(device, &layout_info, NULL, &layout));

    VkShaderModule vert, pick, all;
    VkShaderModuleCreateInfo module_info = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sizeof(probe_vert), probe_vert };
    CHECK(vkCreateShaderModule(device, &module_info, NULL, &vert));
    module_info.codeSize = sizeof(probe_pick_frag); module_info.pCode = probe_pick_frag;
    CHECK(vkCreateShaderModule(device, &module_info, NULL, &pick));
    module_info.codeSize = sizeof(probe_all_frag); module_info.pCode = probe_all_frag;
    CHECK(vkCreateShaderModule(device, &module_info, NULL, &all));

    VkCommandPoolCreateInfo command_pool_info = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, family };
    VkCommandPool command_pool;
    CHECK(vkCreateCommandPool(device, &command_pool_info, NULL, &command_pool));
    VkCommandBufferAllocateInfo command_info = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, command_pool,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    VkCommandBuffer commands;
    CHECK(vkAllocateCommandBuffers(device, &command_info, &commands));

    static uint32_t reference[WORDS];
    int failed = 0;
    const VkSampleCountFlagBits sample_counts[2] = { VK_SAMPLE_COUNT_4_BIT, VK_SAMPLE_COUNT_1_BIT };
    for (int s = 0; s < 2; s++) {
        VkPipeline pipelines[2];
        if (make_pipeline(vert, all, sample_counts[s], &pipelines[0])) return 1;
        if (make_pipeline(vert, pick, sample_counts[s], &pipelines[1])) return 1;
        unsigned marked = 0, lost = 0, extra = 0, runs_with_loss = 0;
        /* Which thread comes first varies from run to run, so several runs. */
        for (int run = 0; run < 20; run++) {
            unsigned lost_before = lost;
            for (int p = 0; p < 2; p++) {
                memset(marks, 0, WORDS * sizeof(uint32_t));
                CHECK(vkResetCommandBuffer(commands, 0));
                VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
                CHECK(vkBeginCommandBuffer(commands, &begin));
                VkRenderPassBeginInfo pass_begin = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, NULL, render_pass, framebuffer,
                    { { 0, 0 }, { WIDTH, HEIGHT } }, 0, NULL };
                vkCmdBeginRenderPass(commands, &pass_begin, VK_SUBPASS_CONTENTS_INLINE);
                vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelines[p]);
                vkCmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &set, 0, NULL);
                /* One draw per disc, as Godot draws one light at a time. */
                for (uint32_t disc = 0; disc < DISCS; disc++) vkCmdDraw(commands, DISC_VERTICES, 1, 0, disc);
                vkCmdEndRenderPass(commands);
                CHECK(vkEndCommandBuffer(commands));
                VkSubmitInfo submit = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &commands };
                CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
                CHECK(vkQueueWaitIdle(queue));
                if (p == 0) { memcpy(reference, marks, sizeof(reference)); continue; }
                for (int w = 0; w < WORDS; w++) {
                    marked += (unsigned)__builtin_popcount(reference[w]);
                    lost += (unsigned)__builtin_popcount(reference[w] & ~marks[w]);
                    extra += (unsigned)__builtin_popcount(marks[w] & ~reference[w]);
                }
            }
            if (lost != lost_before) runs_with_loss++;
        }
        printf("%d sample%s: %u marks, %u lost in %u of 20 runs, %u extra\n", s == 0 ? 4 : 1, s == 0 ? "s" : "",
               marked, lost, runs_with_loss, extra);
        if (marked == 0 || lost != 0 || extra != 0) failed = 1;
    }
    printf(failed ? "RESULT FAIL\n" : "RESULT PASS\n");
    return failed;
}
