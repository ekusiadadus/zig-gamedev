//--------------------------------------------------------------------------------------------------
// zgpu v0.2
//
// This library uses [mach-glfw bindings](https://github.com/hexops/mach-glfw) and
// build script from [mach-gpu-dawn](https://github.com/hexops/mach-gpu-dawn).
//
// `zgpu` is a cross-platform (Windows/Linux/macOS) graphics layer built on top of wgpu API (Dawn).
//--------------------------------------------------------------------------------------------------
const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const glfw = @import("glfw");
const c = @cImport({
    @cInclude("dawn/dawn_proc.h");
    @cInclude("dawn.h");
});
const objc = @cImport({
    @cInclude("objc/message.h");
});
const wgsl = @import("common_wgsl.zig");
pub const wgpu = @import("wgpu.zig");
pub const zgui = @import("zgui.zig");

pub const GraphicsContext = struct {
    pub const swapchain_format = wgpu.TextureFormat.bgra8_unorm;

    window: glfw.Window,
    stats: FrameStats = .{},

    instance: wgpu.Instance,
    device: wgpu.Device,
    queue: wgpu.Queue,
    surface: wgpu.Surface,
    swapchain: wgpu.SwapChain,
    swapchain_descriptor: wgpu.SwapChainDescriptor,

    buffer_pool: BufferPool,
    texture_pool: TexturePool,
    texture_view_pool: TextureViewPool,
    sampler_pool: SamplerPool,
    render_pipeline_pool: RenderPipelinePool,
    compute_pipeline_pool: ComputePipelinePool,
    bind_group_pool: BindGroupPool,
    bind_group_layout_pool: BindGroupLayoutPool,
    pipeline_layout_pool: PipelineLayoutPool,

    mipgens: std.AutoHashMap(wgpu.TextureFormat, MipgenResources),

    uniforms: struct {
        offset: u32 = 0,
        buffer: BufferHandle = .{},
        stage: struct {
            num: u32 = 0,
            current: u32 = 0,
            buffers: [uniforms_staging_pipeline_len]UniformsStagingBuffer =
                [_]UniformsStagingBuffer{.{}} ** uniforms_staging_pipeline_len,
        } = .{},
    } = .{},

    // TODO: Adjust pool sizes.
    const buffer_pool_size = 256;
    const texture_pool_size = 256;
    const texture_view_pool_size = 256;
    const sampler_pool_size = 16;
    const render_pipeline_pool_size = 128;
    const compute_pipeline_pool_size = 128;
    const bind_group_pool_size = 32;
    const bind_group_layout_pool_size = 32;
    const pipeline_layout_pool_size = 32;

    pub fn init(allocator: std.mem.Allocator, window: glfw.Window) !*GraphicsContext {
        const instance = createWgpuInstance();
        errdefer instance.release();

        const adapter = adapter: {
            const Response = struct {
                status: wgpu.RequestAdapterStatus = .unknown,
                adapter: wgpu.Adapter = undefined,
            };

            const callback = (struct {
                fn callback(
                    status: wgpu.RequestAdapterStatus,
                    adapter: wgpu.Adapter,
                    message: ?[*:0]const u8,
                    userdata: ?*anyopaque,
                ) callconv(.C) void {
                    _ = message;
                    const response = @ptrCast(*Response, @alignCast(@sizeOf(usize), userdata));
                    response.status = status;
                    response.adapter = adapter;
                }
            }).callback;

            var response = Response{};
            instance.requestAdapter(
                .{ .power_preference = .high_performance },
                callback,
                @ptrCast(*anyopaque, &response),
            );

            if (response.status != .success) {
                std.debug.print("Failed to request GPU adapter (status: {any}).\n", .{response.status});
                return error.NoGraphicsAdapter;
            }
            break :adapter response.adapter;
        };
        errdefer adapter.release();

        var properties: wgpu.AdapterProperties = undefined;
        adapter.getProperties(&properties);
        std.debug.print("[zgpu] High-performance device has been selected:\n", .{});
        std.debug.print("[zgpu]   Name: {s}\n", .{properties.name});
        std.debug.print("[zgpu]   Driver: {s}\n", .{properties.driver_description});
        std.debug.print("[zgpu]   Adapter type: {s}\n", .{@tagName(properties.adapter_type)});
        std.debug.print("[zgpu]   Backend type: {s}\n", .{@tagName(properties.backend_type)});

        const device = device: {
            const Response = struct {
                status: wgpu.RequestDeviceStatus = .unknown,
                device: wgpu.Device = undefined,
            };

            const callback = (struct {
                fn callback(
                    status: wgpu.RequestDeviceStatus,
                    device: wgpu.Device,
                    message: ?[*:0]const u8,
                    userdata: ?*anyopaque,
                ) callconv(.C) void {
                    _ = message;
                    const response = @ptrCast(*Response, @alignCast(@sizeOf(usize), userdata));
                    response.status = status;
                    response.device = device;
                }
            }).callback;

            var response = Response{};
            adapter.requestDevice(
                wgpu.DeviceDescriptor{},
                callback,
                @ptrCast(*anyopaque, &response),
            );

            if (response.status != .success) {
                std.debug.print("Failed to request GPU device (status: {any}).\n", .{response.status});
                return error.NoGraphicsDevice;
            }
            break :device response.device;
        };
        errdefer device.release();

        device.setUncapturedErrorCallback(printUnhandledError, null);

        const surface = createSurfaceForWindow(instance, window);
        errdefer surface.release();

        const framebuffer_size = try window.getFramebufferSize();

        const swapchain_descriptor = wgpu.SwapChainDescriptor{
            .label = "main window swap chain",
            .usage = .{ .render_attachment = true },
            .format = swapchain_format,
            .width = framebuffer_size.width,
            .height = framebuffer_size.height,
            .present_mode = .fifo,
            .implementation = 0,
        };
        const swapchain = device.createSwapChain(surface, swapchain_descriptor);
        errdefer swapchain.release();

        const gctx = try allocator.create(GraphicsContext);
        gctx.* = .{
            .instance = instance,
            .device = device,
            .queue = device.getQueue(),
            .window = window,
            .surface = surface,
            .swapchain = swapchain,
            .swapchain_descriptor = swapchain_descriptor,
            .buffer_pool = BufferPool.init(allocator, buffer_pool_size),
            .texture_pool = TexturePool.init(allocator, texture_pool_size),
            .texture_view_pool = TextureViewPool.init(allocator, texture_view_pool_size),
            .sampler_pool = SamplerPool.init(allocator, sampler_pool_size),
            .render_pipeline_pool = RenderPipelinePool.init(allocator, render_pipeline_pool_size),
            .compute_pipeline_pool = ComputePipelinePool.init(allocator, compute_pipeline_pool_size),
            .bind_group_pool = BindGroupPool.init(allocator, bind_group_pool_size),
            .bind_group_layout_pool = BindGroupLayoutPool.init(allocator, bind_group_layout_pool_size),
            .pipeline_layout_pool = PipelineLayoutPool.init(allocator, pipeline_layout_pool_size),
            .mipgens = std.AutoHashMap(wgpu.TextureFormat, MipgenResources).init(allocator),
        };

        uniformsInit(gctx);
        return gctx;
    }

    pub fn deinit(gctx: *GraphicsContext, allocator: std.mem.Allocator) void {
        // TODO: How to release `native_instance`?

        // Wait for the GPU to finish all encoded commands.
        while (gctx.stats.cpu_frame_number != gctx.stats.gpu_frame_number) {
            gctx.device.tick();
        }

        // Wait for all outstanding mapAsync() calls to complete.
        wait_loop: while (true) {
            gctx.device.tick();
            var i: u32 = 0;
            while (i < gctx.uniforms.stage.num) : (i += 1) {
                if (gctx.uniforms.stage.buffers[i].slice == null) {
                    continue :wait_loop;
                }
            }
            break;
        }

        gctx.mipgens.deinit();
        gctx.pipeline_layout_pool.deinit(allocator);
        gctx.bind_group_pool.deinit(allocator);
        gctx.bind_group_layout_pool.deinit(allocator);
        gctx.buffer_pool.deinit(allocator);
        gctx.texture_view_pool.deinit(allocator);
        gctx.texture_pool.deinit(allocator);
        gctx.sampler_pool.deinit(allocator);
        gctx.render_pipeline_pool.deinit(allocator);
        gctx.compute_pipeline_pool.deinit(allocator);
        gctx.surface.release();
        gctx.swapchain.release();
        gctx.queue.release();
        gctx.device.release();
        allocator.destroy(gctx);
    }

    //
    // Uniform buffer pool
    //
    pub fn uniformsAllocate(
        gctx: *GraphicsContext,
        comptime T: type,
        num_elements: u32,
    ) struct { slice: []T, offset: u32 } {
        assert(num_elements > 0);
        const size = num_elements * @sizeOf(T);

        const offset = gctx.uniforms.offset;
        const aligned_size = (size + (uniforms_alloc_alignment - 1)) & ~(uniforms_alloc_alignment - 1);
        if ((offset + aligned_size) >= uniforms_buffer_size) {
            // TODO: Better error handling; pool is full; flush it?
            return .{ .slice = @as([*]T, undefined)[0..0], .offset = 0 };
        }

        const current = gctx.uniforms.stage.current;
        const slice = (gctx.uniforms.stage.buffers[current].slice.?.ptr + offset)[0..size];

        gctx.uniforms.offset += aligned_size;
        return .{
            .slice = std.mem.bytesAsSlice(T, @alignCast(@alignOf(T), slice)),
            .offset = offset,
        };
    }

    const UniformsStagingBuffer = struct {
        slice: ?[]u8 = null,
        buffer: wgpu.Buffer = undefined,
    };
    const uniforms_buffer_size = 4 * 1024 * 1024;
    const uniforms_staging_pipeline_len = 8;
    const uniforms_alloc_alignment: u32 = 256;

    fn uniformsInit(gctx: *GraphicsContext) void {
        gctx.uniforms.buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = uniforms_buffer_size,
        });
        gctx.uniformsNextStagingBuffer();
    }

    fn uniformsMappedCallback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.C) void {
        const usb = @ptrCast(*UniformsStagingBuffer, @alignCast(@sizeOf(usize), userdata));
        assert(usb.slice == null);
        if (status == .success) {
            usb.slice = usb.buffer.getMappedRange(u8, 0, uniforms_buffer_size).?;
        } else {
            std.debug.print("[zgpu] Failed to map buffer (code: {d})\n", .{@enumToInt(status)});
        }
    }

    fn uniformsNextStagingBuffer(gctx: *GraphicsContext) void {
        if (gctx.stats.cpu_frame_number > 0) {
            // Map staging buffer which was used this frame.
            const current = gctx.uniforms.stage.current;
            assert(gctx.uniforms.stage.buffers[current].slice == null);
            gctx.uniforms.stage.buffers[current].buffer.mapAsync(
                .{ .write = true },
                0,
                uniforms_buffer_size,
                uniformsMappedCallback,
                @ptrCast(*anyopaque, &gctx.uniforms.stage.buffers[current]),
            );
        }

        gctx.uniforms.offset = 0;

        var i: u32 = 0;
        while (i < gctx.uniforms.stage.num) : (i += 1) {
            if (gctx.uniforms.stage.buffers[i].slice != null) {
                gctx.uniforms.stage.current = i;
                return;
            }
        }

        if (gctx.uniforms.stage.num >= uniforms_staging_pipeline_len) {
            // Wait until one of the buffers is mapped and ready to use.
            while (true) {
                gctx.device.tick();

                i = 0;
                while (i < gctx.uniforms.stage.num) : (i += 1) {
                    if (gctx.uniforms.stage.buffers[i].slice != null) {
                        gctx.uniforms.stage.current = i;
                        return;
                    }
                }
            }
        }

        assert(gctx.uniforms.stage.num < uniforms_staging_pipeline_len);
        const current = gctx.uniforms.stage.num;
        gctx.uniforms.stage.current = current;
        gctx.uniforms.stage.num += 1;

        // Create new staging buffer.
        const buffer_handle = gctx.createBuffer(.{
            .usage = .{ .copy_src = true, .map_write = true },
            .size = uniforms_buffer_size,
            .mapped_at_creation = true,
        });

        // Add new (mapped) staging buffer to the buffer list.
        gctx.uniforms.stage.buffers[current] = .{
            .slice = gctx.lookupResource(buffer_handle).?.getMappedRange(u8, 0, uniforms_buffer_size).?,
            .buffer = gctx.lookupResource(buffer_handle).?,
        };
    }

    //
    // Submit/Present
    //
    pub fn submit(gctx: *GraphicsContext, commands: []const wgpu.CommandBuffer) void {
        const stage_commands = stage_commands: {
            const stage_encoder = gctx.device.createCommandEncoder(null);
            defer stage_encoder.release();

            const current = gctx.uniforms.stage.current;
            assert(gctx.uniforms.stage.buffers[current].slice != null);

            gctx.uniforms.stage.buffers[current].slice = null;
            gctx.uniforms.stage.buffers[current].buffer.unmap();

            if (gctx.uniforms.offset > 0) {
                stage_encoder.copyBufferToBuffer(
                    gctx.uniforms.stage.buffers[current].buffer,
                    0,
                    gctx.lookupResource(gctx.uniforms.buffer).?,
                    0,
                    gctx.uniforms.offset,
                );
            }

            break :stage_commands stage_encoder.finish(null);
        };
        defer stage_commands.release();

        gctx.queue.onSubmittedWorkDone(0, gpuWorkDone, @ptrCast(*anyopaque, &gctx.stats.gpu_frame_number));

        // TODO: We support up to 32 command buffers for now. Make it more robust.
        var command_buffers = std.BoundedArray(wgpu.CommandBuffer, 32).init(0) catch unreachable;
        command_buffers.append(stage_commands) catch unreachable;
        command_buffers.appendSlice(commands) catch unreachable;
        gctx.queue.submit(command_buffers.slice());

        gctx.stats.tick();
        gctx.uniformsNextStagingBuffer();
    }

    fn gpuWorkDone(status: wgpu.QueueWorkDoneStatus, userdata: ?*anyopaque) callconv(.C) void {
        const gpu_frame_number = @ptrCast(*u64, @alignCast(@sizeOf(usize), userdata));
        gpu_frame_number.* += 1;
        if (status != .success) {
            std.debug.print("[zgpu] Failed to complete GPU work (code: {d})\n", .{@enumToInt(status)});
        }
    }

    pub fn present(gctx: *GraphicsContext) enum {
        normal_execution,
        swap_chain_resized,
    } {
        gctx.swapchain.present();

        const fb_size = gctx.window.getFramebufferSize() catch unreachable;
        if (gctx.swapchain_descriptor.width != fb_size.width or
            gctx.swapchain_descriptor.height != fb_size.height)
        {
            gctx.swapchain_descriptor.width = fb_size.width;
            gctx.swapchain_descriptor.height = fb_size.height;
            gctx.swapchain.release();

            gctx.swapchain = gctx.device.createSwapChain(gctx.surface, gctx.swapchain_descriptor);

            std.debug.print(
                "[zgpu] Window has been resized to: {d}x{d}\n",
                .{ gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height },
            );
            return .swap_chain_resized;
        }

        return .normal_execution;
    }

    //
    // Resources
    //
    pub fn createBuffer(gctx: *GraphicsContext, descriptor: wgpu.BufferDescriptor) BufferHandle {
        return gctx.buffer_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createBuffer(descriptor),
            .size = descriptor.size,
            .usage = descriptor.usage,
        });
    }

    pub fn createTexture(gctx: *GraphicsContext, descriptor: wgpu.TextureDescriptor) TextureHandle {
        return gctx.texture_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createTexture(descriptor),
            .usage = descriptor.usage,
            .dimension = descriptor.dimension,
            .size = descriptor.size,
            .format = descriptor.format,
            .mip_level_count = descriptor.mip_level_count,
            .sample_count = descriptor.sample_count,
        });
    }

    pub fn createTextureView(
        gctx: *GraphicsContext,
        texture_handle: TextureHandle,
        descriptor: wgpu.TextureViewDescriptor,
    ) TextureViewHandle {
        const texture = gctx.lookupResource(texture_handle).?;
        const info = gctx.lookupResourceInfo(texture_handle).?;
        var dim = descriptor.dimension;
        if (dim == .undef) {
            dim = switch (info.dimension) {
                .tdim_1d => .tvdim_1d,
                .tdim_2d => .tvdim_2d,
                .tdim_3d => .tvdim_3d,
            };
        }
        return gctx.texture_view_pool.addResource(gctx.*, .{
            .gpuobj = texture.createView(descriptor),
            .format = if (descriptor.format == .undef) info.format else descriptor.format,
            .dimension = dim,
            .base_mip_level = descriptor.base_mip_level,
            .mip_level_count = if (descriptor.mip_level_count == 0xffff_ffff)
                info.mip_level_count
            else
                descriptor.mip_level_count,
            .base_array_layer = descriptor.base_array_layer,
            .array_layer_count = if (descriptor.array_layer_count == 0xffff_ffff)
                info.size.depth_or_array_layers
            else
                descriptor.array_layer_count,
            .aspect = descriptor.aspect,
            .parent_texture_handle = texture_handle,
        });
    }

    pub fn createSampler(gctx: *GraphicsContext, descriptor: wgpu.SamplerDescriptor) SamplerHandle {
        return gctx.sampler_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createSampler(descriptor),
            .address_mode_u = descriptor.address_mode_u,
            .address_mode_v = descriptor.address_mode_v,
            .address_mode_w = descriptor.address_mode_w,
            .mag_filter = descriptor.mag_filter,
            .min_filter = descriptor.min_filter,
            .mipmap_filter = descriptor.mipmap_filter,
            .lod_min_clamp = descriptor.lod_min_clamp,
            .lod_max_clamp = descriptor.lod_max_clamp,
            .compare = descriptor.compare,
            .max_anisotropy = descriptor.max_anisotropy,
        });
    }

    pub fn createRenderPipeline(
        gctx: *GraphicsContext,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: wgpu.RenderPipelineDescriptor,
    ) RenderPipelineHandle {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;
        return gctx.render_pipeline_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createRenderPipeline(desc),
            .pipeline_layout_handle = pipeline_layout,
        });
    }

    const AsyncCreateOpRender = struct {
        gctx: *GraphicsContext,
        result: *RenderPipelineHandle,
        pipeline_layout: PipelineLayoutHandle,
        allocator: std.mem.Allocator,

        fn create(
            status: wgpu.CreatePipelineAsyncStatus,
            pipeline: wgpu.RenderPipeline,
            message: ?[*:0]const u8,
            userdata: ?*anyopaque,
        ) callconv(.C) void {
            const op = @ptrCast(*AsyncCreateOpRender, @alignCast(@sizeOf(usize), userdata));
            if (status == .success) {
                op.result.* = op.gctx.render_pipeline_pool.addResource(
                    op.gctx.*,
                    .{ .gpuobj = pipeline, .pipeline_layout_handle = op.pipeline_layout },
                );
            } else {
                std.debug.print(
                    "[zgpu] Failed to async create render pipeline (code: {s})\n{s}\n",
                    .{ @tagName(status), if (message) |msg| msg else "[zgpu] No error details from the driver" },
                );
            }
            op.allocator.destroy(op);
        }
    };

    pub fn createRenderPipelineAsync(
        gctx: *GraphicsContext,
        allocator: std.mem.Allocator,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: wgpu.RenderPipelineDescriptor,
        result: *RenderPipelineHandle,
    ) void {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;

        const op = allocator.create(AsyncCreateOpRender) catch unreachable;
        op.* = .{
            .gctx = gctx,
            .result = result,
            .pipeline_layout = pipeline_layout,
            .allocator = allocator,
        };
        gctx.device.createRenderPipelineAsync(desc, AsyncCreateOpRender.create, @ptrCast(*anyopaque, op));
    }

    pub fn createComputePipeline(
        gctx: *GraphicsContext,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: wgpu.ComputePipelineDescriptor,
    ) ComputePipelineHandle {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;
        return gctx.compute_pipeline_pool.addResource(gctx.*, .{
            .gpuobj = gctx.device.createComputePipeline(desc),
            .pipeline_layout_handle = pipeline_layout,
        });
    }

    const AsyncCreateOpCompute = struct {
        gctx: *GraphicsContext,
        result: *ComputePipelineHandle,
        pipeline_layout: PipelineLayoutHandle,
        allocator: std.mem.Allocator,

        fn create(
            status: wgpu.CreatePipelineAsyncStatus,
            pipeline: wgpu.ComputePipeline,
            message: ?[*:0]const u8,
            userdata: ?*anyopaque,
        ) callconv(.C) void {
            const op = @ptrCast(*AsyncCreateOpCompute, @alignCast(@sizeOf(usize), userdata));
            if (status == .success) {
                op.result.* = op.gctx.compute_pipeline_pool.addResource(
                    op.gctx.*,
                    .{ .gpuobj = pipeline, .pipeline_layout_handle = op.pipeline_layout },
                );
            } else {
                std.debug.print(
                    "[zgpu] Failed to async create compute pipeline (code: {s})\n{s}\n",
                    .{ @tagName(status), if (message) |msg| msg else "[zgpu] No error details from the driver" },
                );
            }
            op.allocator.destroy(op);
        }
    };

    pub fn createComputePipelineAsync(
        gctx: *GraphicsContext,
        allocator: std.mem.Allocator,
        pipeline_layout: PipelineLayoutHandle,
        descriptor: wgpu.ComputePipelineDescriptor,
        result: *ComputePipelineHandle,
    ) void {
        var desc = descriptor;
        desc.layout = gctx.lookupResource(pipeline_layout) orelse null;

        const op = allocator.create(AsyncCreateOpCompute) catch unreachable;
        op.* = .{
            .gctx = gctx,
            .result = result,
            .pipeline_layout = pipeline_layout,
            .allocator = allocator,
        };
        gctx.device.createComputePipelineAsync(desc, AsyncCreateOpCompute.create, @ptrCast(*anyopaque, op));
    }

    pub fn createBindGroup(
        gctx: *GraphicsContext,
        layout: BindGroupLayoutHandle,
        entries: []const BindGroupEntryInfo,
    ) BindGroupHandle {
        assert(entries.len > 0 and entries.len <= max_num_bindings_per_group);

        var bind_group_info = BindGroupInfo{ .num_entries = @intCast(u32, entries.len) };
        var gpu_bind_group_entries: [max_num_bindings_per_group]wgpu.BindGroupEntry = undefined;

        for (entries) |entry, i| {
            bind_group_info.entries[i] = entry;

            if (entries[i].buffer_handle) |handle| {
                gpu_bind_group_entries[i] = .{
                    .binding = entries[i].binding,
                    .buffer = gctx.lookupResource(handle).?,
                    .offset = entries[i].offset,
                    .size = entries[i].size,
                    .sampler = null,
                    .texture_view = null,
                };
            } else if (entries[i].sampler_handle) |handle| {
                gpu_bind_group_entries[i] = .{
                    .binding = entries[i].binding,
                    .buffer = null,
                    .offset = 0,
                    .size = 0,
                    .sampler = gctx.lookupResource(handle).?,
                    .texture_view = null,
                };
            } else if (entries[i].texture_view_handle) |handle| {
                gpu_bind_group_entries[i] = .{
                    .binding = entries[i].binding,
                    .buffer = null,
                    .offset = 0,
                    .size = 0,
                    .sampler = null,
                    .texture_view = gctx.lookupResource(handle).?,
                };
            } else unreachable;
        }
        bind_group_info.gpuobj = gctx.device.createBindGroup(.{
            .layout = gctx.lookupResource(layout).?,
            .entry_count = @intCast(u32, entries.len),
            .entries = &gpu_bind_group_entries,
        });
        return gctx.bind_group_pool.addResource(gctx.*, bind_group_info);
    }

    pub fn createBindGroupLayout(
        gctx: *GraphicsContext,
        entries: []const wgpu.BindGroupLayoutEntry,
    ) BindGroupLayoutHandle {
        assert(entries.len > 0 and entries.len <= max_num_bindings_per_group);

        var bind_group_layout_info = BindGroupLayoutInfo{
            .gpuobj = gctx.device.createBindGroupLayout(.{
                .entry_count = @intCast(u32, entries.len),
                .entries = entries.ptr,
            }),
            .num_entries = @intCast(u32, entries.len),
        };
        for (entries) |entry, i| {
            bind_group_layout_info.entries[i] = entry;
            bind_group_layout_info.entries[i].next_in_chain = null;
            bind_group_layout_info.entries[i].buffer.next_in_chain = null;
            bind_group_layout_info.entries[i].sampler.next_in_chain = null;
            bind_group_layout_info.entries[i].texture.next_in_chain = null;
            bind_group_layout_info.entries[i].storage_texture.next_in_chain = null;
        }
        return gctx.bind_group_layout_pool.addResource(gctx.*, bind_group_layout_info);
    }

    pub fn createBindGroupLayoutAuto(
        gctx: *GraphicsContext,
        pipeline: anytype,
        group_index: u32,
    ) BindGroupLayoutHandle {
        const bgl = gctx.lookupResource(pipeline).?.getBindGroupLayout(group_index);
        return gctx.bind_group_layout_pool.addResource(gctx.*, BindGroupLayoutInfo{ .gpuobj = bgl });
    }

    pub fn createPipelineLayout(
        gctx: *GraphicsContext,
        bind_group_layouts: []const BindGroupLayoutHandle,
    ) PipelineLayoutHandle {
        assert(bind_group_layouts.len > 0);

        var info: PipelineLayoutInfo = .{ .num_bind_group_layouts = @intCast(u32, bind_group_layouts.len) };
        var gpu_bind_group_layouts: [max_num_bind_groups_per_pipeline]wgpu.BindGroupLayout = undefined;

        for (bind_group_layouts) |bgl, i| {
            info.bind_group_layouts[i] = bgl;
            gpu_bind_group_layouts[i] = gctx.lookupResource(bgl).?;
        }

        info.gpuobj = gctx.device.createPipelineLayout(.{
            .bind_group_layout_count = info.num_bind_group_layouts,
            .bind_group_layouts = &gpu_bind_group_layouts,
        });

        return gctx.pipeline_layout_pool.addResource(gctx.*, info);
    }

    pub fn lookupResource(gctx: GraphicsContext, handle: anytype) ?handleToGpuResourceType(@TypeOf(handle)) {
        if (gctx.isResourceValid(handle)) {
            const T = @TypeOf(handle);
            return switch (T) {
                BufferHandle => gctx.buffer_pool.getGpuObj(handle).?,
                TextureHandle => gctx.texture_pool.getGpuObj(handle).?,
                TextureViewHandle => gctx.texture_view_pool.getGpuObj(handle).?,
                SamplerHandle => gctx.sampler_pool.getGpuObj(handle).?,
                RenderPipelineHandle => gctx.render_pipeline_pool.getGpuObj(handle).?,
                ComputePipelineHandle => gctx.compute_pipeline_pool.getGpuObj(handle).?,
                BindGroupHandle => gctx.bind_group_pool.getGpuObj(handle).?,
                BindGroupLayoutHandle => gctx.bind_group_layout_pool.getGpuObj(handle).?,
                PipelineLayoutHandle => gctx.pipeline_layout_pool.getGpuObj(handle).?,
                else => @compileError(
                    "[zgpu] GraphicsContext.lookupResource() not implemented for " ++ @typeName(T),
                ),
            };
        }
        return null;
    }

    pub fn lookupResourceInfo(gctx: GraphicsContext, handle: anytype) ?handleToResourceInfoType(@TypeOf(handle)) {
        if (gctx.isResourceValid(handle)) {
            const T = @TypeOf(handle);
            return switch (T) {
                BufferHandle => gctx.buffer_pool.getInfo(handle),
                TextureHandle => gctx.texture_pool.getInfo(handle),
                TextureViewHandle => gctx.texture_view_pool.getInfo(handle),
                SamplerHandle => gctx.sampler_pool.getInfo(handle),
                RenderPipelineHandle => gctx.render_pipeline_pool.getInfo(handle),
                ComputePipelineHandle => gctx.compute_pipeline_pool.getInfo(handle),
                BindGroupHandle => gctx.bind_group_pool.getInfo(handle),
                BindGroupLayoutHandle => gctx.bind_group_layout_pool.getInfo(handle),
                PipelineLayoutHandle => gctx.pipeline_layout_pool.getInfo(handle),
                else => @compileError(
                    "[zgpu] GraphicsContext.lookupResourceInfo() not implemented for " ++ @typeName(T),
                ),
            };
        }
        return null;
    }

    pub fn releaseResource(gctx: *GraphicsContext, handle: anytype) void {
        const T = @TypeOf(handle);
        switch (T) {
            BufferHandle => gctx.buffer_pool.destroyResource(handle, false),
            TextureHandle => gctx.texture_pool.destroyResource(handle, false),
            TextureViewHandle => gctx.texture_view_pool.destroyResource(handle, false),
            SamplerHandle => gctx.sampler_pool.destroyResource(handle, false),
            RenderPipelineHandle => gctx.render_pipeline_pool.destroyResource(handle, false),
            ComputePipelineHandle => gctx.compute_pipeline_pool.destroyResource(handle, false),
            BindGroupHandle => gctx.bind_group_pool.destroyResource(handle, false),
            BindGroupLayoutHandle => gctx.bind_group_layout_pool.destroyResource(handle, false),
            PipelineLayoutHandle => gctx.pipeline_layout_pool.destroyResource(handle, false),
            else => @compileError("[zgpu] GraphicsContext.releaseResource() not implemented for " ++ @typeName(T)),
        }
    }

    pub fn destroyResource(gctx: *GraphicsContext, handle: anytype) void {
        const T = @TypeOf(handle);
        switch (T) {
            BufferHandle => gctx.buffer_pool.destroyResource(handle, true),
            TextureHandle => gctx.texture_pool.destroyResource(handle, true),
            else => @compileError("[zgpu] GraphicsContext.destroyResource() not implemented for " ++ @typeName(T)),
        }
    }

    pub fn isResourceValid(gctx: GraphicsContext, handle: anytype) bool {
        const T = @TypeOf(handle);
        switch (T) {
            BufferHandle => return gctx.buffer_pool.isHandleValid(handle),
            TextureHandle => return gctx.texture_pool.isHandleValid(handle),
            TextureViewHandle => {
                if (gctx.texture_view_pool.isHandleValid(handle)) {
                    const texture = gctx.texture_view_pool.getInfoPtr(handle).parent_texture_handle;
                    return gctx.isResourceValid(texture);
                }
                return false;
            },
            SamplerHandle => return gctx.sampler_pool.isHandleValid(handle),
            RenderPipelineHandle => return gctx.render_pipeline_pool.isHandleValid(handle),
            ComputePipelineHandle => return gctx.compute_pipeline_pool.isHandleValid(handle),
            BindGroupHandle => {
                if (gctx.bind_group_pool.isHandleValid(handle)) {
                    const num_entries = gctx.bind_group_pool.getInfoPtr(handle).num_entries;
                    const entries = &gctx.bind_group_pool.getInfoPtr(handle).entries;
                    var i: u32 = 0;
                    while (i < num_entries) : (i += 1) {
                        if (entries[i].buffer_handle) |buffer| {
                            if (!gctx.isResourceValid(buffer))
                                return false;
                        } else if (entries[i].sampler_handle) |sampler| {
                            if (!gctx.isResourceValid(sampler))
                                return false;
                        } else if (entries[i].texture_view_handle) |texture_view| {
                            if (!gctx.isResourceValid(texture_view))
                                return false;
                        } else unreachable;
                    }
                    return true;
                }
                return false;
            },
            BindGroupLayoutHandle => return gctx.bind_group_layout_pool.isHandleValid(handle),
            PipelineLayoutHandle => return gctx.pipeline_layout_pool.isHandleValid(handle),
            else => @compileError("[zgpu] GraphicsContext.isResourceValid() not implemented for " ++ @typeName(T)),
        }
    }

    //
    // Mipmaps
    //
    const MipgenResources = struct {
        pipeline: ComputePipelineHandle = .{},
        scratch_texture: TextureHandle = .{},
        scratch_texture_views: [max_levels_per_dispatch]TextureViewHandle =
            [_]TextureViewHandle{.{}} ** max_levels_per_dispatch,
        bind_group_layout: BindGroupLayoutHandle = .{},

        const max_levels_per_dispatch = 4;
    };

    pub fn generateMipmaps(
        gctx: *GraphicsContext,
        arena: std.mem.Allocator,
        encoder: wgpu.CommandEncoder,
        texture: TextureHandle,
    ) void {
        const texture_info = gctx.lookupResourceInfo(texture) orelse return;
        if (texture_info.mip_level_count == 1) return;

        const max_size = 2048;

        assert(texture_info.usage.copy_dst == true);
        assert(texture_info.dimension == .tdim_2d);
        assert(texture_info.size.width <= max_size and texture_info.size.height <= max_size);
        assert(texture_info.size.width == texture_info.size.height);
        assert(math.isPowerOfTwo(texture_info.size.width));

        const format = texture_info.format;
        const entry = gctx.mipgens.getOrPut(format) catch unreachable;
        const mipgen = entry.value_ptr;

        if (!entry.found_existing) {
            mipgen.bind_group_layout = gctx.createBindGroupLayout(&.{
                bglBuffer(0, .{ .compute = true }, .uniform, true, 0),
                bglTexture(1, .{ .compute = true }, .unfilterable_float, .tvdim_2d, false),
                bglStorageTexture(2, .{ .compute = true }, .write_only, format, .tvdim_2d),
                bglStorageTexture(3, .{ .compute = true }, .write_only, format, .tvdim_2d),
                bglStorageTexture(4, .{ .compute = true }, .write_only, format, .tvdim_2d),
                bglStorageTexture(5, .{ .compute = true }, .write_only, format, .tvdim_2d),
            });

            const pipeline_layout = gctx.createPipelineLayout(&.{
                mipgen.bind_group_layout,
            });
            defer gctx.releaseResource(pipeline_layout);

            const wgsl_src = wgsl.csGenerateMipmaps(arena, formatToShaderFormat(format));
            const cs_module = util.createWgslShaderModule(gctx.device, wgsl_src, "zgpu_cs_generate_mipmaps");
            defer {
                arena.free(wgsl_src);
                cs_module.release();
            }

            mipgen.pipeline = gctx.createComputePipeline(pipeline_layout, .{
                .compute = .{
                    .module = cs_module,
                    .entry_point = "main",
                },
            });

            mipgen.scratch_texture = gctx.createTexture(.{
                .usage = .{ .copy_src = true, .storage_binding = true },
                .dimension = .tdim_2d,
                .size = .{ .width = max_size / 2, .height = max_size / 2, .depth_or_array_layers = 1 },
                .format = format,
                .mip_level_count = MipgenResources.max_levels_per_dispatch,
                .sample_count = 1,
            });

            for (mipgen.scratch_texture_views) |*view, i| {
                view.* = gctx.createTextureView(mipgen.scratch_texture, .{
                    .base_mip_level = @intCast(u32, i),
                    .mip_level_count = 1,
                    .base_array_layer = 0,
                    .array_layer_count = 1,
                });
            }
        }

        var array_layer: u32 = 0;
        while (array_layer < texture_info.size.depth_or_array_layers) : (array_layer += 1) {
            const texture_view = gctx.createTextureView(texture, .{
                .dimension = .tvdim_2d,
                .base_array_layer = array_layer,
                .array_layer_count = 1,
            });
            defer gctx.releaseResource(texture_view);

            const bind_group = gctx.createBindGroup(mipgen.bind_group_layout, &[_]BindGroupEntryInfo{
                .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 8 },
                .{ .binding = 1, .texture_view_handle = texture_view },
                .{ .binding = 2, .texture_view_handle = mipgen.scratch_texture_views[0] },
                .{ .binding = 3, .texture_view_handle = mipgen.scratch_texture_views[1] },
                .{ .binding = 4, .texture_view_handle = mipgen.scratch_texture_views[2] },
                .{ .binding = 5, .texture_view_handle = mipgen.scratch_texture_views[3] },
            });
            defer gctx.releaseResource(bind_group);

            const MipgenUniforms = extern struct {
                src_mip_level: i32,
                num_mip_levels: u32,
            };

            var total_num_mips: u32 = texture_info.mip_level_count - 1;
            var current_src_mip_level: u32 = 0;

            while (true) {
                const dispatch_num_mips = math.min(MipgenResources.max_levels_per_dispatch, total_num_mips);
                {
                    const pass = encoder.beginComputePass(null);
                    defer {
                        pass.end();
                        pass.release();
                    }

                    pass.setPipeline(gctx.lookupResource(mipgen.pipeline).?);

                    const mem = gctx.uniformsAllocate(MipgenUniforms, 1);
                    mem.slice[0] = .{
                        .src_mip_level = @intCast(i32, current_src_mip_level),
                        .num_mip_levels = dispatch_num_mips,
                    };
                    pass.setBindGroup(0, gctx.lookupResource(bind_group).?, &.{mem.offset});

                    pass.dispatchWorkgroups(
                        math.max(texture_info.size.width >> @intCast(u5, 3 + current_src_mip_level), 1),
                        math.max(texture_info.size.height >> @intCast(u5, 3 + current_src_mip_level), 1),
                        1,
                    );
                }

                var mip_index: u32 = 0;
                while (mip_index < dispatch_num_mips) : (mip_index += 1) {
                    const src_origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = 0 };
                    const dst_origin = wgpu.Origin3D{ .x = 0, .y = 0, .z = array_layer };
                    encoder.copyTextureToTexture(
                        .{
                            .texture = gctx.lookupResource(mipgen.scratch_texture).?,
                            .mip_level = mip_index,
                            .origin = src_origin,
                        },
                        .{
                            .texture = gctx.lookupResource(texture).?,
                            .mip_level = mip_index + current_src_mip_level + 1,
                            .origin = dst_origin,
                        },
                        .{
                            .width = texture_info.size.width >> @intCast(u5, mip_index + current_src_mip_level + 1),
                            .height = texture_info.size.height >> @intCast(u5, mip_index + current_src_mip_level + 1),
                        },
                    );
                }

                assert(total_num_mips >= dispatch_num_mips);
                total_num_mips -= dispatch_num_mips;
                if (total_num_mips == 0) {
                    break;
                }
                current_src_mip_level += dispatch_num_mips;
            }
        }
    }
};

pub fn createWgpuInstance() wgpu.Instance {
    c.dawnProcSetProcs(c.dawnNativeGetProcs());
    const native_instance = c.dawnNativeCreateInstance();
    c.dawnNativeDiscoverDefaultAdapters(native_instance);

    const instance = @ptrCast(
        wgpu.Instance,
        @alignCast(@sizeOf(usize), c.dawnNativeGetWgpuInstance(native_instance).?),
    );
    return instance;
}

pub const bglBuffer = wgpu.BindGroupLayoutEntry.buffer;
pub const bglTexture = wgpu.BindGroupLayoutEntry.texture;
pub const bglSampler = wgpu.BindGroupLayoutEntry.sampler;
pub const bglStorageTexture = wgpu.BindGroupLayoutEntry.storageTexture;

pub const util = struct {
    /// You may disable async shader compilation for debugging purposes.
    const enable_async_shader_compilation = true;

    /// Helper function for creating render pipelines.
    /// Supports: one vertex buffer, one non-blending render target,
    /// one vertex shader module and one fragment shader module.
    pub fn createRenderPipelineSimple(
        allocator: std.mem.Allocator,
        gctx: *GraphicsContext,
        bgls: []const BindGroupLayoutHandle,
        wgsl_vs: [:0]const u8,
        wgsl_fs: [:0]const u8,
        vertex_stride: ?u64,
        vertex_attribs: ?[]const wgpu.VertexAttribute,
        primitive_state: wgpu.PrimitiveState,
        rt_format: wgpu.TextureFormat,
        depth_state: ?wgpu.DepthStencilState,
        out_pipe: *RenderPipelineHandle,
    ) void {
        const pl = gctx.createPipelineLayout(bgls);
        defer gctx.releaseResource(pl);

        const vs_mod = createWgslShaderModule(gctx.device, wgsl_vs, null);
        defer vs_mod.release();

        const fs_mod = createWgslShaderModule(gctx.device, wgsl_fs, null);
        defer fs_mod.release();

        const color_targets = [_]wgpu.ColorTargetState{.{ .format = rt_format }};

        const vertex_buffers = if (vertex_stride) |vs| [_]wgpu.VertexBufferLayout{.{
            .array_stride = vs,
            .attribute_count = @intCast(u32, vertex_attribs.?.len),
            .attributes = vertex_attribs.?.ptr,
        }} else null;

        const pipe_desc = wgpu.RenderPipelineDescriptor{
            .vertex = wgpu.VertexState{
                .module = vs_mod,
                .entry_point = "main",
                .buffer_count = if (vertex_buffers) |vbs| vbs.len else 0,
                .buffers = if (vertex_buffers) |vbs| &vbs else null,
            },
            .fragment = &wgpu.FragmentState{
                .module = fs_mod,
                .entry_point = "main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
            .depth_stencil = if (depth_state) |ds| &ds else null,
            .primitive = primitive_state,
        };

        if (enable_async_shader_compilation) {
            gctx.createRenderPipelineAsync(allocator, pl, pipe_desc, out_pipe);
        } else {
            out_pipe.* = gctx.createRenderPipeline(pl, pipe_desc);
        }
    }

    /// Helper function for creating render passes.
    /// Supports: One color attachment and optional depth attachment.
    pub fn beginRenderPassSimple(
        encoder: wgpu.CommandEncoder,
        load_op: wgpu.LoadOp,
        color_texv: wgpu.TextureView,
        clear_color: ?wgpu.Color,
        depth_texv: ?wgpu.TextureView,
        clear_depth: ?f32,
    ) wgpu.RenderPassEncoder {
        if (depth_texv == null) {
            assert(clear_depth == null);
        }
        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = color_texv,
            .load_op = load_op,
            .store_op = .store,
            .clear_value = if (clear_color) |cc| cc else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }};
        if (depth_texv) |dtexv| {
            const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                .view = dtexv,
                .depth_load_op = load_op,
                .depth_store_op = .store,
                .depth_clear_value = if (clear_depth) |cd| cd else 0.0,
            };
            return encoder.beginRenderPass(.{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
                .depth_stencil_attachment = &depth_attachment,
            });
        }
        return encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        });
    }

    pub fn endRelease(pass: anytype) void {
        pass.end();
        pass.release();
    }

    pub fn createWgslShaderModule(
        device: wgpu.Device,
        source: [*:0]const u8,
        label: ?[*:0]const u8,
    ) wgpu.ShaderModule {
        const wgsl_desc = wgpu.ShaderModuleWgslDescriptor{
            .chain = .{
                .next = null,
                .struct_type = .shader_module_wgsl_descriptor,
            },
            .source = source,
        };
        const desc = wgpu.ShaderModuleDescriptor{
            .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &wgsl_desc),
            .label = if (label) |l| l else null,
        };
        return device.createShaderModule(desc);
    }
};

pub const BufferInfo = struct {
    gpuobj: ?wgpu.Buffer = null,
    size: usize = 0,
    usage: wgpu.BufferUsage = .{},
};

pub const TextureInfo = struct {
    gpuobj: ?wgpu.Texture = null,
    usage: wgpu.TextureUsage = .{},
    dimension: wgpu.TextureDimension = .tdim_1d,
    size: wgpu.Extent3D = .{ .width = 0 },
    format: wgpu.TextureFormat = .undef,
    mip_level_count: u32 = 0,
    sample_count: u32 = 0,
};

pub const TextureViewInfo = struct {
    gpuobj: ?wgpu.TextureView = null,
    format: wgpu.TextureFormat = .undef,
    dimension: wgpu.TextureViewDimension = .undef,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0,
    aspect: wgpu.TextureAspect = .all,
    parent_texture_handle: TextureHandle = .{},
};

pub const SamplerInfo = struct {
    gpuobj: ?wgpu.Sampler = null,
    address_mode_u: wgpu.AddressMode = .repeat,
    address_mode_v: wgpu.AddressMode = .repeat,
    address_mode_w: wgpu.AddressMode = .repeat,
    mag_filter: wgpu.FilterMode = .nearest,
    min_filter: wgpu.FilterMode = .nearest,
    mipmap_filter: wgpu.FilterMode = .nearest,
    lod_min_clamp: f32 = 0.0,
    lod_max_clamp: f32 = 0.0,
    compare: wgpu.CompareFunction = .undef,
    max_anisotropy: u16 = 0,
};

pub const RenderPipelineInfo = struct {
    gpuobj: ?wgpu.RenderPipeline = null,
    pipeline_layout_handle: PipelineLayoutHandle = .{},
};

pub const ComputePipelineInfo = struct {
    gpuobj: ?wgpu.ComputePipeline = null,
    pipeline_layout_handle: PipelineLayoutHandle = .{},
};

pub const BindGroupEntryInfo = struct {
    binding: u32 = 0,
    buffer_handle: ?BufferHandle = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler_handle: ?SamplerHandle = null,
    texture_view_handle: ?TextureViewHandle = null,
};

const max_num_bindings_per_group = 10;

pub const BindGroupInfo = struct {
    gpuobj: ?wgpu.BindGroup = null,
    num_entries: u32 = 0,
    entries: [max_num_bindings_per_group]BindGroupEntryInfo =
        [_]BindGroupEntryInfo{.{}} ** max_num_bindings_per_group,
};

pub const BindGroupLayoutInfo = struct {
    gpuobj: ?wgpu.BindGroupLayout = null,
    num_entries: u32 = 0,
    entries: [max_num_bindings_per_group]wgpu.BindGroupLayoutEntry =
        [_]wgpu.BindGroupLayoutEntry{.{ .binding = 0, .visibility = .{} }} ** max_num_bindings_per_group,
};

const max_num_bind_groups_per_pipeline = 4;

pub const PipelineLayoutInfo = struct {
    gpuobj: ?wgpu.PipelineLayout = null,
    num_bind_group_layouts: u32 = 0,
    bind_group_layouts: [max_num_bind_groups_per_pipeline]BindGroupLayoutHandle =
        [_]BindGroupLayoutHandle{.{}} ** max_num_bind_groups_per_pipeline,
};

pub const BufferHandle = BufferPool.Handle;
pub const TextureHandle = TexturePool.Handle;
pub const TextureViewHandle = TextureViewPool.Handle;
pub const SamplerHandle = SamplerPool.Handle;
pub const RenderPipelineHandle = RenderPipelinePool.Handle;
pub const ComputePipelineHandle = ComputePipelinePool.Handle;
pub const BindGroupHandle = BindGroupPool.Handle;
pub const BindGroupLayoutHandle = BindGroupLayoutPool.Handle;
pub const PipelineLayoutHandle = PipelineLayoutPool.Handle;

const BufferPool = ResourcePool(BufferInfo, wgpu.Buffer);
const TexturePool = ResourcePool(TextureInfo, wgpu.Texture);
const TextureViewPool = ResourcePool(TextureViewInfo, wgpu.TextureView);
const SamplerPool = ResourcePool(SamplerInfo, wgpu.Sampler);
const RenderPipelinePool = ResourcePool(RenderPipelineInfo, wgpu.RenderPipeline);
const ComputePipelinePool = ResourcePool(ComputePipelineInfo, wgpu.ComputePipeline);
const BindGroupPool = ResourcePool(BindGroupInfo, wgpu.BindGroup);
const BindGroupLayoutPool = ResourcePool(BindGroupLayoutInfo, wgpu.BindGroupLayout);
const PipelineLayoutPool = ResourcePool(PipelineLayoutInfo, wgpu.PipelineLayout);

fn ResourcePool(comptime Info: type, comptime Resource: type) type {
    const zpool = @import("zpool");
    const Pool = zpool.Pool(16, 16, Resource, struct { info: Info });

    return struct {
        const Self = @This();

        pub const Handle = Pool.Handle;

        pool: Pool,

        fn init(allocator: std.mem.Allocator, capacity: u32) Self {
            const pool = Pool.initCapacity(allocator, capacity) catch unreachable;
            return .{ .pool = pool };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            self.pool.deinit();
        }

        fn addResource(self: *Self, gctx: GraphicsContext, info: Info) Handle {
            assert(info.gpuobj != null);

            if (self.pool.addIfNotFull(.{ .info = info })) |handle| {
                return handle;
            }

            // If pool is free, attempt to remove a resource that is now invalid
            // because of dependent resources which have become invalid.
            // For example, texture view becomes invalid when parent texture
            // is destroyed.
            //
            // TODO: We could instead store a linked list in Info to track
            // dependencies.  The parent resource could "point" to the first
            // dependent resource, and each dependent resource could "point" to
            // the parent and the prev/next dependent resources of the same
            // type (perhaps using handles instead of pointers).
            // When a parent resource is destroyed, we could traverse that list
            // to destroy dependent resources, and when a dependent resource
            // is destroyed, we can remove it from the doubly-linked list.
            //
            // pub const TextureInfo = struct {
            //     ...
            //     // note generic name:
            //     first_dependent_handle: TextureViewHandle = .{}
            // };
            //
            // pub const TextureViewInfo = struct {
            //     ...
            //     // note generic names:
            //     parent_handle: TextureHandle = .{},
            //     prev_dependent_handle: TextureViewHandle,
            //     next_dependent_handle: TextureViewHandle,
            // };
            if (self.removeResourceIfInvalid(gctx)) {
                if (self.pool.addIfNotFull(.{ .info = info })) |handle| {
                    return handle;
                }
            }

            // TODO: For now we just assert if pool is full - make it more roboust.
            assert(false);
            return Handle.nil;
        }

        fn removeResourceIfInvalid(self: *Self, gctx: GraphicsContext) bool {
            var live_handles = self.pool.liveHandles();
            while (live_handles.next()) |live_handle| {
                if (!gctx.isResourceValid(live_handle)) {
                    self.destroyResource(live_handle, true);
                    return true;
                }
            }
            return false;
        }

        fn destroyResource(self: *Self, handle: Handle, comptime call_destroy: bool) void {
            if (!self.isHandleValid(handle))
                return;

            const resource_info = self.pool.getColumnPtrAssumeLive(handle, .info);
            const gpuobj = resource_info.gpuobj.?;

            if (call_destroy and (Handle == BufferHandle or Handle == TextureHandle)) {
                gpuobj.destroy();
            }
            gpuobj.release();
            resource_info.* = .{};

            self.pool.removeAssumeLive(handle);
        }

        fn isHandleValid(self: Self, handle: Handle) bool {
            return self.pool.isLiveHandle(handle);
        }

        fn getInfoPtr(self: Self, handle: Handle) *Info {
            return self.pool.getColumnPtrAssumeLive(handle, .info);
        }

        fn getInfo(self: Self, handle: Handle) Info {
            return self.pool.getColumnAssumeLive(handle, .info);
        }

        fn getGpuObj(self: Self, handle: Handle) ?Resource {
            if (self.pool.getColumnPtrIfLive(handle, .info)) |info| {
                return info.gpuobj;
            }
            return null;
        }
    };
}

pub fn checkSystem(comptime content_dir: []const u8) !void {
    const local = struct {
        fn impl() error{ GraphicsApiUnavailable, InvalidDataFiles }!void {
            // TODO: On Windows we should check if DirectX 12 is supported (Windows 10+).
            // On Linux we require Vulkan support.
            if (@import("builtin").target.os.tag == .linux) {
                if (!glfw.vulkanSupported()) {
                    return error.GraphicsApiUnavailable;
                }
                _ = glfw.getRequiredInstanceExtensions() catch return error.GraphicsApiUnavailable;
            }
            // Change directory to where an executable is located.
            {
                var exe_path_buffer: [1024]u8 = undefined;
                const exe_path = std.fs.selfExeDirPath(exe_path_buffer[0..]) catch "./";
                std.os.chdir(exe_path) catch {};
            }
            // Make sure font file is a valid data file and not just a Git LFS pointer.
            {
                const file = std.fs.cwd().openFile(
                    content_dir ++ "Roboto-Medium.ttf",
                    .{},
                ) catch return error.InvalidDataFiles;
                defer file.close();

                const size = @intCast(usize, file.getEndPos() catch return error.InvalidDataFiles);
                if (size <= 1024) {
                    return error.InvalidDataFiles;
                }
            }
        }

        fn errorCallbackGlfw(error_code: glfw.Error, description: [:0]const u8) void {
            std.debug.print("glfw: {}: {s}\n", .{ error_code, description });
        }
    };

    glfw.setErrorCallback(local.errorCallbackGlfw);

    local.impl() catch |err| switch (err) {
        error.GraphicsApiUnavailable => {
            std.debug.print(
                \\
                \\GRAPHICS ERROR
                \\
                \\This program requires:
                \\
                \\  * DirectX 12 graphics driver on Windows
                \\  * Vulkan graphics driver on Linux (OpenGL is NOT supported)
                \\  * Metal graphics driver on macOS
                \\
                \\Please install latest supported driver and try again.
                \\
                \\
            , .{});
            return err;
        },
        error.InvalidDataFiles => {
            std.debug.print(
                \\
                \\DATA ERROR
                \\
                \\Invalid data files or missing content folder.
                \\Please install Git LFS (Large File Support) and run (in the repo):
                \\
                \\git lfs install
                \\git lfs pull
                \\
                \\For more info please see: https://git-lfs.github.com/
                \\
                \\
            , .{});
            return err;
        },
        else => unreachable,
    };
}

const FrameStats = struct {
    time: f64 = 0.0,
    delta_time: f32 = 0.0,
    fps_counter: u32 = 0,
    fps: f64 = 0.0,
    average_cpu_time: f64 = 0.0,
    previous_time: f64 = 0.0,
    fps_refresh_time: f64 = 0.0,
    cpu_frame_number: u64 = 0,
    gpu_frame_number: u64 = 0,

    fn tick(stats: *FrameStats) void {
        stats.time = glfw.getTime();
        stats.delta_time = @floatCast(f32, stats.time - stats.previous_time);
        stats.previous_time = stats.time;

        if ((stats.time - stats.fps_refresh_time) >= 1.0) {
            const t = stats.time - stats.fps_refresh_time;
            const fps = @intToFloat(f64, stats.fps_counter) / t;
            const ms = (1.0 / fps) * 1000.0;

            stats.fps = fps;
            stats.average_cpu_time = ms;
            stats.fps_refresh_time = stats.time;
            stats.fps_counter = 0;
        }
        stats.fps_counter += 1;
        stats.cpu_frame_number += 1;
    }
};

pub const gui = struct {
    pub var want_capture_mouse: bool = false;
    pub var want_capture_keyboard: bool = false;

    /// This call will install GLFW callbacks to handle GUI interactions.
    /// Those callbacks will chain-call user's previously installed callbacks, if any.
    /// This means that custom user's callbacks need to be installed *before* calling zgpu.gui.init().
    pub fn init(
        window: glfw.Window,
        device: wgpu.Device,
        comptime content_dir: []const u8,
        comptime font_name: []const u8,
        font_size: f32,
    ) void {
        zgui.init();

        if (!ImGui_ImplGlfw_InitForOther(window.handle, true)) {
            unreachable;
        }

        if (font_name.len > 1) {
            _ = zgui.io.addFontFromFile(content_dir ++ font_name ++ "\x00", font_size);
        }

        if (!ImGui_ImplWGPU_Init(
            device,
            1, // Number of `frames in flight`. One is enough because Dawn creates staging buffers internally.
            @enumToInt(GraphicsContext.swapchain_format),
        )) {
            unreachable;
        }

        zgui.io.setIniFilename(content_dir ++ "imgui.ini");
    }

    pub fn deinit() void {
        ImGui_ImplWGPU_Shutdown();
        ImGui_ImplGlfw_Shutdown();
        zgui.deinit();
    }

    pub fn newFrame(fb_width: u32, fb_height: u32) void {
        // (when reading from the io.WantCaptureMouse, io.WantCaptureKeyboard flags to dispatch your inputs, it is
        //  generally easier and more correct to use their state BEFORE calling NewFrame(). See FAQ for details!)
        want_capture_mouse = zgui.io.getWantCaptureMouse();
        want_capture_keyboard = zgui.io.getWantCaptureKeyboard();

        ImGui_ImplWGPU_NewFrame();
        ImGui_ImplGlfw_NewFrame();

        zgui.io.setDisplaySize(@intToFloat(f32, fb_width), @intToFloat(f32, fb_height));
        zgui.io.setDisplayFramebufferScale(1.0, 1.0);

        zgui.newFrame();
    }

    pub fn draw(pass: wgpu.RenderPassEncoder) void {
        zgui.render();
        ImGui_ImplWGPU_RenderDrawData(zgui.getDrawData(), pass);
    }

    extern fn ImGui_ImplGlfw_InitForOther(window: *const anyopaque, install_callbacks: bool) bool;
    extern fn ImGui_ImplGlfw_NewFrame() void;
    extern fn ImGui_ImplGlfw_Shutdown() void;
    extern fn ImGui_ImplWGPU_Init(device: *const anyopaque, num_frames_in_flight: u32, rt_format: u32) bool;
    extern fn ImGui_ImplWGPU_NewFrame() void;
    extern fn ImGui_ImplWGPU_RenderDrawData(draw_data: *const anyopaque, pass_encoder: *const anyopaque) void;
    extern fn ImGui_ImplWGPU_Shutdown() void;
};

pub const stbi = struct {
    pub fn Image(comptime ChannelType: type) type {
        return struct {
            const Self = @This();

            data: []ChannelType,
            width: u32,
            height: u32,
            bytes_per_row: u32,
            channels_in_memory: u32,
            channels_in_file: u32,

            pub fn init(
                filename: [*:0]const u8,
                desired_channels: u32,
            ) !Self {
                var x: c_int = undefined;
                var y: c_int = undefined;
                var ch: c_int = undefined;
                var data = switch (ChannelType) {
                    u8 => stbi_load(filename, &x, &y, &ch, @intCast(c_int, desired_channels)),
                    f16 => @ptrCast(?[*]f16, stbi_loadf(filename, &x, &y, &ch, @intCast(c_int, desired_channels))),
                    f32 => stbi_loadf(filename, &x, &y, &ch, @intCast(c_int, desired_channels)),
                    else => @compileError("[zgpu] stbi.Image: ChannelType can be u8, f16 or f32."),
                };
                if (data == null)
                    return error.StbiLoadFailed;

                const channels_in_memory = if (desired_channels == 0) @intCast(u32, ch) else desired_channels;
                const width = @intCast(u32, x);
                const height = @intCast(u32, y);

                if (ChannelType == f16) {
                    var data_f32 = @ptrCast([*]f32, data.?);
                    const num = width * height * channels_in_memory;
                    var i: u32 = 0;
                    while (i < num) : (i += 1) {
                        data.?[i] = @floatCast(f16, data_f32[i]);
                    }
                }

                return Self{
                    .data = data.?[0 .. width * height * channels_in_memory],
                    .width = width,
                    .height = height,
                    .bytes_per_row = width * channels_in_memory * @sizeOf(ChannelType),
                    .channels_in_memory = channels_in_memory,
                    .channels_in_file = @intCast(u32, ch),
                };
            }

            pub fn deinit(image: *Self) void {
                stbi_image_free(image.data.ptr);
                image.* = undefined;
            }
        };
    }

    pub const hdrToLdrScale = stbi_hdr_to_ldr_scale;
    pub const hdrToLdrGamma = stbi_hdr_to_ldr_gamma;
    pub const ldrToHdrScale = stbi_ldr_to_hdr_scale;
    pub const ldrToHdrGamma = stbi_ldr_to_hdr_gamma;

    pub fn isHdr(filename: [*:0]const u8) bool {
        return stbi_is_hdr(filename) == 1;
    }

    pub fn setFlipVerticallyOnLoad(should_flip: bool) void {
        stbi_set_flip_vertically_on_load(if (should_flip) 1 else 0);
    }

    extern fn stbi_load(
        filename: [*:0]const u8,
        x: *c_int,
        y: *c_int,
        channels_in_file: *c_int,
        desired_channels: c_int,
    ) ?[*]u8;

    extern fn stbi_loadf(
        filename: [*:0]const u8,
        x: *c_int,
        y: *c_int,
        channels_in_file: *c_int,
        desired_channels: c_int,
    ) ?[*]f32;

    extern fn stbi_image_free(image_data: ?*anyopaque) void;

    extern fn stbi_hdr_to_ldr_scale(scale: f32) void;
    extern fn stbi_hdr_to_ldr_gamma(gamma: f32) void;
    extern fn stbi_ldr_to_hdr_scale(scale: f32) void;
    extern fn stbi_ldr_to_hdr_gamma(gamma: f32) void;

    extern fn stbi_is_hdr(filename: [*:0]const u8) c_int;
    extern fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void;
};

const SurfaceDescriptorTag = enum {
    metal_layer,
    windows_hwnd,
    windows_core_window,
    windows_swap_chain_panel,
    xlib,
    canvas_html_selector,
};

const SurfaceDescriptor = union(SurfaceDescriptorTag) {
    metal_layer: struct {
        label: ?[*:0]const u8 = null,
        layer: *anyopaque,
    },
    windows_hwnd: struct {
        label: ?[*:0]const u8 = null,
        hinstance: *anyopaque,
        hwnd: *anyopaque,
    },
    windows_core_window: struct {
        label: ?[*:0]const u8 = null,
        core_window: *anyopaque,
    },
    windows_swap_chain_panel: struct {
        label: ?[*:0]const u8 = null,
        swap_chain_panel: *anyopaque,
    },
    xlib: struct {
        label: ?[*:0]const u8 = null,
        display: *anyopaque,
        window: u32,
    },
    canvas_html_selector: struct {
        label: ?[*:0]const u8 = null,
        selector: [*:0]const u8,
    },
};

fn detectGLFWOptions() glfw.BackendOptions {
    const target = @import("builtin").target;
    if (target.isDarwin()) return .{ .cocoa = true };
    return switch (target.os.tag) {
        .windows => .{ .win32 = true },
        .linux => .{ .x11 = true },
        else => .{},
    };
}

pub fn createSurfaceForWindow(
    instance: wgpu.Instance,
    window: glfw.Window,
) wgpu.Surface {
    comptime var glfw_options = detectGLFWOptions();
    const glfw_native = glfw.Native(glfw_options);
    const descriptor = if (glfw_options.win32) SurfaceDescriptor{
        .windows_hwnd = .{
            .label = "basic surface",
            .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
            .hwnd = glfw_native.getWin32Window(window),
        },
    } else if (glfw_options.x11) SurfaceDescriptor{
        .xlib = .{
            .label = "basic surface",
            .display = glfw_native.getX11Display(),
            .window = glfw_native.getX11Window(window),
        },
    } else if (glfw_options.cocoa) blk: {
        const ns_window = glfw_native.getCocoaWindow(window);
        const ns_view = msgSend(ns_window, "contentView", .{}, *anyopaque); // [nsWindow contentView]

        // Create a CAMetalLayer that covers the whole window that will be passed to CreateSurface.
        msgSend(ns_view, "setWantsLayer:", .{true}, void); // [view setWantsLayer:YES]
        const layer = msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque); // [CAMetalLayer layer]
        if (layer == null) @panic("failed to create Metal layer");
        msgSend(ns_view, "setLayer:", .{layer.?}, void); // [view setLayer:layer]

        // Use retina if the window was created with retina support.
        const scale_factor = msgSend(ns_window, "backingScaleFactor", .{}, f64); // [ns_window backingScaleFactor]
        msgSend(layer.?, "setContentsScale:", .{scale_factor}, void); // [layer setContentsScale:scale_factor]

        break :blk SurfaceDescriptor{
            .metal_layer = .{
                .label = "basic surface",
                .layer = layer.?,
            },
        };
    } else if (glfw_options.wayland) {
        // bugs.chromium.org/p/dawn/issues/detail?id=1246&q=surface&can=2
        @panic("Dawn does not yet have Wayland support");
    } else unreachable;

    return createSurface(instance, descriptor);
}

fn createSurface(instance: wgpu.Instance, descriptor: SurfaceDescriptor) wgpu.Surface {
    return switch (descriptor) {
        .metal_layer => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromMetalLayer = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_metal_layer;
            desc.layer = src.layer;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .windows_hwnd => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromWindowsHWND = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_windows_hwnd;
            desc.hinstance = src.hinstance;
            desc.hwnd = src.hwnd;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .windows_core_window => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromWindowsCoreWindow = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_windows_core_window;
            desc.core_window = src.core_window;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .windows_swap_chain_panel => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromWindowsSwapChainPanel = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_windows_swap_chain_panel;
            desc.swap_chain_panel = src.swap_chain_panel;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .xlib => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromXlibWindow = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_xlib_window;
            desc.display = src.display;
            desc.window = src.window;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .canvas_html_selector => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromCanvasHTMLSelector = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_canvas_html_selector;
            desc.selector = src.selector;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(*const wgpu.ChainedStruct, &desc),
                .label = if (src.label) |l| l else null,
            });
        },
    };
}

// Borrowed from https://github.com/hazeycode/zig-objcrt
fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const args_meta = @typeInfo(@TypeOf(args)).Struct.fields;

    const FnType = if (@import("builtin").zig_backend == .stage1) switch (args_meta.len) {
        0 => fn (@TypeOf(obj), objc.SEL) callconv(.C) ReturnType,
        1 => fn (@TypeOf(obj), objc.SEL, args_meta[0].field_type) callconv(.C) ReturnType,
        2 => fn (@TypeOf(obj), objc.SEL, args_meta[0].field_type, args_meta[1].field_type) callconv(.C) ReturnType,
        3 => fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].field_type,
            args_meta[1].field_type,
            args_meta[2].field_type,
        ) callconv(.C) ReturnType,
        4 => fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].field_type,
            args_meta[1].field_type,
            args_meta[2].field_type,
            args_meta[3].field_type,
        ) callconv(.C) ReturnType,
        else => @compileError("[zgpu] Unsupported number of args"),
    } else switch (args_meta.len) {
        0 => *const fn (@TypeOf(obj), objc.SEL) callconv(.C) ReturnType,
        1 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].field_type) callconv(.C) ReturnType,
        2 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].field_type, args_meta[1].field_type) callconv(.C) ReturnType,
        3 => *const fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].field_type,
            args_meta[1].field_type,
            args_meta[2].field_type,
        ) callconv(.C) ReturnType,
        4 => *const fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].field_type,
            args_meta[1].field_type,
            args_meta[2].field_type,
            args_meta[3].field_type,
        ) callconv(.C) ReturnType,
        else => @compileError("[zgpu] Unsupported number of args"),
    };

    // NOTE: `func` is a var because making it const causes a compile error which I believe is a compiler bug.
    var func = @ptrCast(
        FnType,
        if (@import("builtin").zig_backend == .stage1) objc.objc_msgSend else &objc.objc_msgSend,
    );
    const sel = objc.sel_getUid(sel_name.ptr);

    return @call(.{}, func, .{ obj, sel } ++ args);
}

fn printUnhandledError(err_type: wgpu.ErrorType, message: [*:0]const u8, userdata: ?*anyopaque) callconv(.C) void {
    _ = userdata;
    switch (err_type) {
        .validation => std.debug.print("[zgpu] Validation error: {s}\n", .{message}),
        .out_of_memory => std.debug.print("[zgpu] Out of memory: {s}\n", .{message}),
        .device_lost => std.debug.print("[zgpu] Device lost: {s}\n", .{message}),
        .unknown => std.debug.print("[zgpu] Unknown error: {s}\n", .{message}),
        else => unreachable,
    }
    // TODO: Do something better.
    std.process.exit(1);
}

fn handleToGpuResourceType(comptime T: type) type {
    return switch (T) {
        BufferHandle => wgpu.Buffer,
        TextureHandle => wgpu.Texture,
        TextureViewHandle => wgpu.TextureView,
        SamplerHandle => wgpu.Sampler,
        RenderPipelineHandle => wgpu.RenderPipeline,
        ComputePipelineHandle => wgpu.ComputePipeline,
        BindGroupHandle => wgpu.BindGroup,
        BindGroupLayoutHandle => wgpu.BindGroupLayout,
        PipelineLayoutHandle => wgpu.PipelineLayout,
        else => @compileError("[zgpu] handleToGpuResourceType() not implemented for " ++ @typeName(T)),
    };
}

fn handleToResourceInfoType(comptime T: type) type {
    return switch (T) {
        BufferHandle => BufferInfo,
        TextureHandle => TextureInfo,
        TextureViewHandle => TextureViewInfo,
        SamplerHandle => SamplerInfo,
        RenderPipelineHandle => RenderPipelineInfo,
        ComputePipelineHandle => ComputePipelineInfo,
        BindGroupHandle => BindGroupInfo,
        BindGroupLayoutHandle => BindGroupLayoutInfo,
        PipelineLayoutHandle => PipelineLayoutInfo,
        else => @compileError("[zgpu] handleToResourceInfoType() not implemented for " ++ @typeName(T)),
    };
}

fn formatToShaderFormat(format: wgpu.TextureFormat) []const u8 {
    // TODO: Add missing formats.
    return switch (format) {
        .rgba8_unorm => "rgba8unorm",
        .rgba8_snorm => "rgba8snorm",
        .rgba16_float => "rgba16float",
        .rgba32_float => "rgba32float",
        else => unreachable,
    };
}

const expect = std.testing.expect;

test "zgpu.wgpu.init" {
    const instance = createWgpuInstance();
    instance.reference();
    instance.release();

    const adapter = adapter: {
        const Response = struct {
            status: wgpu.RequestAdapterStatus = .unknown,
            adapter: wgpu.Adapter = undefined,
        };

        const callback = (struct {
            fn callback(
                status: wgpu.RequestAdapterStatus,
                adapter: wgpu.Adapter,
                message: ?[*:0]const u8,
                userdata: ?*anyopaque,
            ) callconv(.C) void {
                _ = message;

                var response = @ptrCast(*Response, @alignCast(@sizeOf(usize), userdata));
                response.status = status;
                response.adapter = adapter;

                if (status != .success) {
                    std.debug.print("Failed to request GPU adapter (status: {any}).\n", .{status});
                }
            }
        }).callback;

        var response = Response{};
        instance.requestAdapter(
            .{ .power_preference = .high_performance },
            callback,
            @ptrCast(*anyopaque, &response),
        );
        try expect(response.status == .success);

        const adapter = response.adapter;

        var features: [32]wgpu.FeatureName = undefined;
        const num_adapter_features = std.math.min(adapter.enumerateFeatures(null), features.len);
        _ = adapter.enumerateFeatures(&features);
        _ = num_adapter_features;

        var properties: wgpu.AdapterProperties = undefined;
        adapter.getProperties(&properties);

        break :adapter adapter;
    };
    defer adapter.release();

    const device = device: {
        const Response = struct {
            status: wgpu.RequestDeviceStatus = .unknown,
            device: wgpu.Device = undefined,
        };

        const callback = (struct {
            fn callback(
                status: wgpu.RequestDeviceStatus,
                device: wgpu.Device,
                message: ?[*:0]const u8,
                userdata: ?*anyopaque,
            ) callconv(.C) void {
                _ = message;

                var response = @ptrCast(*Response, @alignCast(@sizeOf(usize), userdata));
                response.status = status;
                response.device = device;

                if (status != .success) {
                    std.debug.print("Failed to request GPU device (status: {any}).\n", .{status});
                }
            }
        }).callback;

        var response = Response{};
        adapter.requestDevice(
            wgpu.DeviceDescriptor{},
            callback,
            @ptrCast(*anyopaque, &response),
        );
        try expect(response.status == .success);
        break :device response.device;
    };
    defer device.release();
}
