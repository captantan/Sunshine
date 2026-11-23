/**
 * @file src/captantan/display_hooks.cpp
 * @brief captantan fork: run `pre_display_cmd` and `post_display_cmd` around Sunshine's display setup.
 *
 * See CAPTANTAN.md at the root of the repository.
 */
// header include
#include "display_hooks.h"

// standard includes
#include <chrono>
#include <exception>
#include <format>
#include <string_view>
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
  std::string post_display_cmd;

  namespace {
    namespace bp = boost::process::v1;

    /// Moonlight waits up to about two minutes for a launch reply; stay well inside that.
    constexpr auto pre_timeout = 90s;
    /// post_display_cmd runs inside Sunshine's display task, which the next launch waits for.
    constexpr auto post_timeout = 30s;

    /**
     * @brief Run a command with no window and no console I/O, and wait for it.
     *
     * The command runs with Sunshine's own rights: SYSTEM when Sunshine runs as the Windows
     * service, so it works before anyone has signed in. It should keep its own log.
     *
     * @return An empty string on success, otherwise a message for the client.
     */
    std::string run_and_wait(std::string_view name, const std::string &cmd, bp::environment &env, std::chrono::seconds timeout) {
      std::error_code ec;
      bp::child child(
        cmd,
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
        BOOST_LOG(error) << name << ": could not start ["sv << cmd << "]: "sv << ec.message();
        return std::format("{} could not be started; see the Sunshine log", name);
      }

      // child::wait_for() is deprecated and unreliable, so poll, as process.cpp does.
      const auto deadline = std::chrono::steady_clock::now() + timeout;
      while (child.running(ec) && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(100ms);
      }
      if (!ec && child.running(ec)) {
        child.terminate(ec);
        BOOST_LOG(error) << name << ": still running after "sv << timeout.count() << " s, stopped it"sv;
        return std::format("{} did not finish within {} s", name, timeout.count());
      }
      if (ec) {
        BOOST_LOG(error) << name << ": waiting for it failed: "sv << ec.message();
        return std::format("{} failed; see the Sunshine log", name);
      }

      const int exit_code = child.exit_code();
      if (exit_code != 0) {
        BOOST_LOG(error) << name << ": exited with code "sv << exit_code;
        return std::format("{} failed with exit code {}", name, exit_code);
      }

      BOOST_LOG(info) << name << ": done"sv;
      return {};
    }
  }  // namespace

  std::string run_pre_display_cmd(const rtsp_stream::launch_session_t &session) {
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

    auto err = run_and_wait("pre_display_cmd"sv, pre_display_cmd, env, pre_timeout);
    if (!err.empty()) {
      BOOST_LOG(error) << "pre_display_cmd: launch aborted"sv;
    }
    return err;
  }

  void run_post_display_cmd(bool restored) {
    if (post_display_cmd.empty()) {
      return;
    }

    // This runs on display_device's task thread: never let an exception escape into it.
    try {
      bp::environment env = boost::this_process::environment();
      env["SUNSHINE_DISPLAY_RESTORED"] = restored ? "true" : "false";

      BOOST_LOG(info) << "post_display_cmd: running ["sv << post_display_cmd << "] after "sv
                      << (restored ? "the display settings were restored"sv : "restoring the display settings failed"sv);

      run_and_wait("post_display_cmd"sv, post_display_cmd, env, post_timeout);
    } catch (const std::exception &e) {
      BOOST_LOG(error) << "post_display_cmd: "sv << e.what();
    }
  }
}  // namespace captantan
