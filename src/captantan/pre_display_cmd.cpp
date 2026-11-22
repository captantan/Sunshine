/**
 * @file src/captantan/pre_display_cmd.cpp
 * @brief captantan fork: run `pre_display_cmd` before Sunshine sets up the display.
 *
 * See CAPTANTAN.md at the root of the repository.
 */
// header include
#include "pre_display_cmd.h"

// standard includes
#include <chrono>
#include <format>
#include <system_error>
#include <thread>

// lib includes
#include <boost/process/v1.hpp>
#ifdef _WIN32
  #include <boost/process/v1/windows.hpp>
#endif

// local includes
#include "../logging.h"

using namespace std::literals;

namespace captantan {
  std::string pre_display_cmd;

  namespace {
    /// Moonlight waits up to about two minutes for a launch reply; stay well inside that.
    constexpr auto timeout = 90s;
  }  // namespace

  std::string run_pre_display_cmd(const rtsp_stream::launch_session_t &session) {
    namespace bp = boost::process::v1;

    if (pre_display_cmd.empty()) {
      return {};
    }

    // Built here rather than in process.cpp, whose block of client variables changes in most releases.
    bp::environment env = boost::this_process::environment();
    env["SUNSHINE_CLIENT_NAME"] = session.client_name;
    env["SUNSHINE_CLIENT_WIDTH"] = std::to_string(session.width);
    env["SUNSHINE_CLIENT_HEIGHT"] = std::to_string(session.height);
    env["SUNSHINE_CLIENT_FPS"] = std::to_string(session.fps);
    env["SUNSHINE_CLIENT_HDR"] = session.enable_hdr ? "true" : "false";

    BOOST_LOG(info) << "pre_display_cmd: running ["sv << pre_display_cmd << "] for "sv
                    << session.width << 'x' << session.height << '@' << session.fps
                    << (session.enable_hdr ? " HDR"sv : ""sv);

    // The command runs with Sunshine's own rights: SYSTEM when Sunshine runs as the Windows
    // service, so it works before anyone has signed in. It has no window and no console I/O;
    // it should keep its own log.
    std::error_code ec;
    bp::child child(
      pre_display_cmd,
      env,
      bp::std_in < bp::null,
      bp::std_out > bp::null,
      bp::std_err > bp::null,
#ifdef _WIN32
      bp::windows::create_no_window,
#endif
      ec
    );
    if (ec) {
      BOOST_LOG(error) << "pre_display_cmd: could not start ["sv << pre_display_cmd << "]: "sv << ec.message();
      return "pre_display_cmd could not be started; see the Sunshine log";
    }

    // child::wait_for() is deprecated and unreliable, so poll, as process.cpp does.
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (child.running(ec) && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(100ms);
    }
    if (!ec && child.running(ec)) {
      child.terminate(ec);
      BOOST_LOG(error) << "pre_display_cmd: still running after "sv << timeout.count() << " s, stopped it"sv;
      return std::format("pre_display_cmd did not finish within {} s", timeout.count());
    }
    if (ec) {
      BOOST_LOG(error) << "pre_display_cmd: waiting for it failed: "sv << ec.message();
      return "pre_display_cmd failed; see the Sunshine log";
    }

    const int exit_code = child.exit_code();
    if (exit_code != 0) {
      BOOST_LOG(error) << "pre_display_cmd: exited with code "sv << exit_code << "; launch aborted"sv;
      return std::format("pre_display_cmd failed with exit code {}", exit_code);
    }

    BOOST_LOG(info) << "pre_display_cmd: done"sv;
    return {};
  }
}  // namespace captantan
