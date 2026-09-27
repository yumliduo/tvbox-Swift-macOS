/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <limits.h>
#include <math.h>
#include <QuartzCore/CAMetalLayer.h>
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>

#include "common.h"
#include "context.h"
#include "utils.h"

// The VO can sleep indefinitely while paused. Wake it on layer resize, but
// invalidate the pointer before teardown so an in-flight KVO callback cannot
// access a destroyed VO. The callback never touches the GPU or waits for it.
@interface TVBoxMPVLayerObserver : NSObject {
    CAMetalLayer *_layer;
    NSLock *_lock;
    struct vo *_vo;
}
- (instancetype)initWithLayer:(CAMetalLayer *)layer vo:(struct vo *)vo;
- (void)invalidate;
@end

@implementation TVBoxMPVLayerObserver
- (instancetype)initWithLayer:(CAMetalLayer *)layer vo:(struct vo *)vo {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        _layer = [layer retain];
        _vo = vo;
        [_layer addObserver:self forKeyPath:@"drawableSize" options:0 context:NULL];
    }
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                      change:(NSDictionary *)change context:(void *)context {
    [_lock lock];
    if (_vo) vo_wakeup(_vo);
    [_lock unlock];
}
- (void)invalidate {
    [_lock lock];
    _vo = NULL;
    [_lock unlock];
    if (_layer) {
        [_layer removeObserver:self forKeyPath:@"drawableSize"];
        [_layer release];
        _layer = nil;
    }
}
- (void)dealloc {
    [self invalidate];
    [_lock release];
    [super dealloc];
}
@end

struct priv {
    struct mpvk_ctx vk;
    CAMetalLayer *layer;
    TVBoxMPVLayerObserver *observer;
};

static void moltenvk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    [p->observer invalidate];
    [p->observer release];
    p->observer = nil;
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
}

static bool moltenvk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (ctx->vo->opts->WinID == -1) {
        MP_MSG(ctx, msgl, "WinID missing\n");
        goto fail;
    }

    if (!mpvk_init(vk, ctx, VK_EXT_METAL_SURFACE_EXTENSION_NAME))
        goto fail;

    p->layer = (__bridge CAMetalLayer *)(intptr_t)ctx->vo->opts->WinID;
    VkMetalSurfaceCreateInfoEXT info = {
         .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
         .pLayer = p->layer,
    };

    struct ra_ctx_params params = {0};

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMetalSurfaceEXT(inst, &info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating MoltenVK surface\n");
        goto fail;
    }

    if (!ra_vk_ctx_init(ctx, vk, params, VK_PRESENT_MODE_FIFO_KHR))
        goto fail;

    p->observer = [[TVBoxMPVLayerObserver alloc] initWithLayer:p->layer vo:ctx->vo];
    return true;
fail:
    moltenvk_uninit(ctx);
    return false;
}

static bool moltenvk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    CGSize s = p->layer.drawableSize;
    ra_vk_ctx_resize(ctx, s.width, s.height);
    return true;
}

static int moltenvk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    if (request == VOCTRL_CHECK_EVENTS) {
        struct priv *p = ctx->priv;
        CGSize size = p->layer.drawableSize;
        if (isfinite(size.width) && isfinite(size.height) &&
            size.width > 1 && size.height > 1 &&
            size.width < INT_MAX && size.height < INT_MAX) {
            int width = (int)llround(size.width);
            int height = (int)llround(size.height);
            if ((width != ctx->vo->dwidth || height != ctx->vo->dheight) &&
                ra_vk_ctx_resize(ctx, width, height)) {
                *events |= VO_EVENT_RESIZE | VO_EVENT_EXPOSE;
            }
        }
        return VO_TRUE;
    }
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_moltenvk = {
    .type           = "vulkan",
    .name           = "moltenvk",
    .reconfig       = moltenvk_reconfig,
    .control        = moltenvk_control,
    .init           = moltenvk_init,
    .uninit         = moltenvk_uninit,
};
