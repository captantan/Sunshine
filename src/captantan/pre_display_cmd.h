/**
 * @file src/captantan/pre_display_cmd.h
 * @brief captantan fork: a command that runs before Sunshine sets up the display.
 *
 * See CAPTANTAN.md at the root of the repository.
 */
#pragma once

// standard includes
#include <string>

// local includes
#include "src/rtsp.h"

namespace captantan {
  /**
   * @brief Command line from the `pre_display_cmd` option in sunshine.conf. Empty means off.
   */
  extern std::string pre_display_cmd;

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
}  // namespace captantan
