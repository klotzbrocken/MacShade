/*
 * Copyright (C) 2014 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause
 */

#pragma once

namespace reshade::vulkan
{
	class device_impl;

	class swapchain_impl : public api::api_object_impl<VkSwapchainKHR, api::swapchain>
	{
	public:
		swapchain_impl(device_impl *device, VkSwapchainKHR swapchain, const VkSwapchainCreateInfoKHR &create_info, HWND hwnd);

		api::device *get_device() final;

		void *get_hwnd() const final;

		api::resource get_back_buffer(uint32_t index) final;

		uint32_t get_back_buffer_count() const final;
		uint32_t get_current_back_buffer_index() const final;

		bool check_color_space_support(api::color_space color_space) const final;

		api::color_space get_color_space() const final;

	protected:
		device_impl *const _device;

		VkSwapchainCreateInfoKHR _create_info = { VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
		HWND _hwnd = nullptr;
		uint32_t _swap_index = 0;
#ifdef __APPLE__
	public:
		/// MacShade: when set, this image is reported as the one and only back buffer (used to process frames of OpenGL/Metal games)
		VkImage _override_image = VK_NULL_HANDLE;
#endif
	};

	template <>
	struct object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> : public swapchain_impl
	{
		using Handle = VkSwapchainKHR;

		object_data(device_impl *device, VkSwapchainKHR swapchain, const VkSwapchainCreateInfoKHR &create_info, HWND hwnd) :
			swapchain_impl(device, swapchain, create_info, hwnd) {}

		using swapchain_impl::_create_info;
		using swapchain_impl::_hwnd;
		using swapchain_impl::_swap_index;
#ifdef __APPLE__
		using swapchain_impl::_override_image;
#endif

#if VK_EXT_full_screen_exclusive
		HMONITOR hmonitor = nullptr;
#endif
	};
}
