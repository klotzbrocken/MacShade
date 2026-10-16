/*
 * Copyright (C) 2024 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause
 */

#pragma once

#include "reshade_api_device.hpp"

namespace reshade
{
	void create_effect_runtime(api::swapchain *swapchain, api::command_queue *graphics_queue, bool vr = false);
	void destroy_effect_runtime(api::swapchain *swapchain);

	void init_effect_runtime(api::swapchain *swapchain);
	void reset_effect_runtime(api::swapchain *swapchain);
	void present_effect_runtime(api::swapchain *swapchain);
	bool is_effect_runtime_idle(api::swapchain *swapchain, bool *fps_only);
	bool is_effect_runtime_using_depth(api::swapchain *swapchain);
	void bind_effect_runtime_depth(api::swapchain *swapchain, api::resource_view srv);
}
