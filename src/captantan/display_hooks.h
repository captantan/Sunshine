/**
 * @file src/captantan/display_hooks.h
 * @brief captantan fork: commands that run around Sunshine's display setup.
 *
 * See CAPTANTAN.md at the root of the repository.
 */
#pragma once

// standard includes
#include <string>

// local includes
#include "../rtsp.h"

namespace captantan {
  /**
   * @brief Command line from the `pre_display_cmd` option in sunshine.conf. Empty means off.
   */
  extern std::string pre_display_cmd;

  /**
   * @brief Command line from the `post_display_cmd` option in sunshine.conf. Empty means off.
   */
  extern std::string post_display_cmd;

  /**
   * @brief Run `pre_display_cmd`, if it is set, and wait for it to finish.
   *
   * Called just before display_device::configure_display(), only when no stream is active.
   * The command gets SUNSHINE_CLIENT_WIDTH, _HEIGHT, _FPS, _HDR and _NAME.
   *
   * @param session The launch session of the connecting client.
   * @return An empty string on success, otherwise a message to send to the client.
   */
  std::string run_pre_display_cmd(const rtsp_stream::launch_session_t &session);

  /**
   * @brief Run `post_display_cmd`, if it is set, and wait for it to finish.
   *
   * Called by display_device's revert task after each attempt to restore the display settings
   * (after a stream, after a failed launch, and when Sunshine starts), but not when Sunshine stops.
   * The command gets SUNSHINE_DISPLAY_RESTORED=true or false. Its exit code is only logged.
   *
   * @param restored Whether the display settings were restored.
   */
  void run_post_display_cmd(bool restored);
}  // namespace captantan
